import Foundation
import CryptoKit
import OSLog
import DeskRecallCore

public enum DiagnosticEvent: String, Codable, Sendable {
    case applicationStarted, applicationStopped, heartbeat, permissionChanged, screensChanged
    case sessionPaused, sessionResumed, automaticChanged, restoreScheduled, topologyStable
    case stabilizationTimeout, automaticDeferred, operationStarted, scanCompleted, profileMissing
    case desktopsPrepared, windowMatched
    case profileSelected, profileSaved, saveRejected, windowResult, operationFinished, inventoryChecked
}
public enum DiagnosticTrigger: String, Codable, Sendable {
    case startup, screens, wake, session, permission, setting, manual, sleep, lock
}
public enum DiagnosticOperation: String, Codable, Sendable { case save, restore, audit }
public enum DiagnosticOutcome: String, Codable, Sendable {
    case success, partial, failed, cancelled, noProfile, rejected, constrained, unmatched
}
public enum DiagnosticReason: String, Codable, Sendable {
    case permissionDenied, sessionUnavailable, unsupportedTopology, busy, unstableDisplays
    case legacyIdentityFallback
    case emptyScan, incompleteScan, replacementDeclined, contextChanged
    case unknownProfileSchema, corruptProfile, ioFailure, axFailure, windowUnavailable, windowChanged, windowReadOnly, spaceRestoreFailed, missingDesktop, nativeBackendUnavailable
}
public struct DiagnosticCounts: Codable, Sendable {
    public var requested = 0
    public var scanned = 0
    public var matched = 0
    public var verified = 0
    public var constrained = 0
    public var skipped = 0
    public var excluded = 0
    public var scanIssues = 0
    public var coverage: WindowCoverage?
    public init() {}
}
public struct DiagnosticEntry: Codable, Sendable {
    public var schemaVersion = 1
    public var timestamp: Date
    public var sessionID: UUID
    public var appVersion: String
    public var event: DiagnosticEvent
    public var operationID: UUID?
    public var operation: DiagnosticOperation?
    public var trigger: DiagnosticTrigger?
    public var configurationID: String?
    public var displayCount: Int?
    public var trusted: Bool?
    public var automatic: Bool?
    public var busy: Bool?
    public var counts: DiagnosticCounts?
    public var durationMS: Int?
    public var outcome: DiagnosticOutcome?
    public var reason: DiagnosticReason?
    public var appID: String?
    public var windowID: String?
    public var profileID: UUID?
    public var profileSavedAt: Date?
    public var actual: Rect?
    public var target: Rect?
    public var errorCode: Int?
    public init(event: DiagnosticEvent, timestamp: Date = Date(), sessionID: UUID = UUID(),
                appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", operationID: UUID? = nil,
                operation: DiagnosticOperation? = nil, trigger: DiagnosticTrigger? = nil,
                topology: Topology? = nil, trusted: Bool? = nil, automatic: Bool? = nil,
                busy: Bool? = nil, counts: DiagnosticCounts? = nil, durationMS: Int? = nil,
                outcome: DiagnosticOutcome? = nil, reason: DiagnosticReason? = nil,
                appID: String? = nil, windowToken: UUID? = nil, profile: Profile? = nil, target: Rect? = nil, actual: Rect? = nil, errorCode: Int? = nil) {
        self.timestamp = timestamp; self.sessionID = sessionID; self.appVersion = appVersion; self.event = event
        self.operationID = operationID; self.operation = operation; self.trigger = trigger
        configurationID = topology.map { Self.fingerprint($0.key) }; displayCount = topology?.displays.count
        self.trusted = trusted; self.automatic = automatic; self.busy = busy; self.counts = counts
        self.durationMS = durationMS; self.outcome = outcome; self.reason = reason
        self.appID = appID; windowID = windowToken.map { Self.fingerprint($0.uuidString) }
        profileID = profile?.id; profileSavedAt = profile?.savedAt
        self.target = target; self.actual = actual; self.errorCode = errorCode
    }
    private static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public struct DiagnosticHistory: Sendable {
    public var entries: [DiagnosticEntry]
    public var unreadableLines: Int
}

/// All file state is owned exclusively by queue. Failures are separately protected by errorLock.
public final class DiagnosticsLog: @unchecked Sendable {
    public struct Limits: Sendable {
        public var fileBytes: Int
        public var files: Int
        public var retentionDays: Int
        public init(fileBytes: Int = 1_048_576, files: Int = 32, retentionDays: Int = 14) {
            self.fileBytes = max(256, fileBytes); self.files = max(1, files); self.retentionDays = max(1, retentionDays)
        }
    }
    public let directory: URL
    public let sessionID = UUID()
    private let queue = DispatchQueue(label: "local.deskrecall.diagnostics", qos: .utility)
    private let errorLock = NSLock()
    private var failed = false
    private let enabled: Bool
    private let limits: Limits
    private var handle: FileHandle?
    private var activeDay = ""
    private var activeSize = 0
    private let fallback = Logger(subsystem: "local.deskrecall.app", category: "diagnostics")
    public init(directory: URL? = nil, limits: Limits = Limits(), enabled: Bool = true) {
        self.directory = directory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DeskRecall", isDirectory: true)
        self.limits = limits; self.enabled = enabled
    }
    public var hasWriteFailure: Bool {
        errorLock.lock(); defer { errorLock.unlock() }; return failed
    }
    public func record(_ entry: DiagnosticEntry) {
        guard enabled else { return }
        var value = entry; value.sessionID = sessionID
        let immutable = value
        queue.async { [self] in
            do { try append(immutable); setFailure(false) }
            catch { setFailure(true); fallback.error("Cannot write diagnostics journal.") }
        }
    }
    public func flush() {
        guard enabled else { return }
        queue.sync {
            do { try handle?.synchronize() }
            catch { setFailure(true) }
        }
    }
    public func history(since: Date) async -> DiagnosticHistory {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var records: [DiagnosticEntry] = []; var unreadable = 0
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                do {
                    try handle?.synchronize()
                    for file in try files() {
                        // Bound memory even if somebody placed a foreign oversized file in this directory.
                        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= limits.fileBytes + 16_384 else {
                            unreadable += 1; continue
                        }
                        let data = try Data(contentsOf: file)
                        for line in data.split(separator: 10) {
                            if let record = try? decoder.decode(DiagnosticEntry.self, from: Data(line)), record.schemaVersion == 1 {
                                if record.timestamp >= since { records.append(record) }
                            } else { unreadable += 1 }
                        }
                    }
                } catch { unreadable += 1 }
                continuation.resume(returning: DiagnosticHistory(entries: records.sorted { $0.timestamp < $1.timestamp }, unreadableLines: unreadable))
            }
        }
    }
    private func setFailure(_ value: Bool) {
        errorLock.lock(); failed = value; errorLock.unlock()
    }
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func append(_ record: DiagnosticEntry) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record); data.append(10)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: record.timestamp)
        if handle == nil || activeDay != day || activeSize + data.count > limits.fileBytes {
            try handle?.close(); handle = nil
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let today = try files().filter { $0.lastPathComponent.hasPrefix("events-\(day)-") }
            var index = today.last.flatMap { Int($0.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "") } ?? 0
            if let last = today.last,
               let size = (try FileManager.default.attributesOfItem(atPath: last.path)[.size] as? NSNumber)?.intValue,
               size + data.count <= limits.fileBytes { activeSize = size }
            else { index += 1; activeSize = 0 }
            let file = directory.appendingPathComponent(String(format: "events-%@-%06d.jsonl", day, index))
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            handle = try FileHandle(forUpdating: file)
            try handle?.seekToEnd()
            if activeSize > 0 {
                try handle?.seek(toOffset: UInt64(activeSize - 1))
                let last = try handle?.read(upToCount: 1)
                try handle?.seekToEnd()
                if last?.first != 10 { try handle?.write(contentsOf: Data([10])); activeSize += 1 }
            }
            activeDay = day
            try prune(now: record.timestamp, keeping: file, formatter: formatter)
        }
        try handle?.write(contentsOf: data); activeSize += data.count
        // Persist each completed write; events still queued can be lost on abrupt exit.
        try handle?.synchronize()
    }
    private func prune(now: Date, keeping active: URL, formatter: DateFormatter) throws {
        let oldestDay = formatter.string(from: now.addingTimeInterval(-Double(limits.retentionDays - 1) * 86400))
        let all = try files()
        let expired = all.filter { String($0.lastPathComponent.dropFirst(7).prefix(10)) < oldestDay && $0 != active }
        for file in expired { try FileManager.default.removeItem(at: file) }
        let remaining = try files()
        for file in remaining.prefix(max(0, remaining.count - limits.files)) where file != active {
            try FileManager.default.removeItem(at: file)
        }
    }
}

public struct DiagnosticsSummary: Sendable {
    public var restored = 0
    public var partial = 0
    public var failed = 0
    public var cancelled = 0
    public var noProfile = 0
    public var saved = 0
    public var requestedWindows = 0
    public var verifiedWindows = 0
    public var constrainedWindows = 0
    public var skippedWindows = 0
    public var permissionDeferrals = 0
    public var heartbeatCount = 0
    public var incompleteOperations = 0
    public var durationMS = 0
    public var completedRestores = 0
    public init(entries: [DiagnosticEntry]) {
        var started = Set<UUID>(); var finished = Set<UUID>()
        for entry in entries {
            if entry.event == .heartbeat { heartbeatCount += 1 }
            if entry.event == .automaticDeferred && entry.reason == .permissionDenied { permissionDeferrals += 1 }
            if entry.event == .operationStarted, let id = entry.operationID { started.insert(id) }
            guard entry.event == .operationFinished, let id = entry.operationID, finished.insert(id).inserted else { continue }
            if entry.operation == .save { if entry.outcome == .success || entry.outcome == .partial { saved += 1 }; continue }
            guard entry.operation == .restore else { continue }
            switch entry.outcome {
            case .success: restored += 1
            case .partial: partial += 1
            case .failed: failed += 1
            case .cancelled: cancelled += 1
            case .noProfile: noProfile += 1
            default: continue
            }
            if [.success, .partial, .failed].contains(entry.outcome) {
                completedRestores += 1; durationMS += entry.durationMS ?? 0
                requestedWindows += entry.counts?.requested ?? 0
                verifiedWindows += entry.counts?.verified ?? 0
                constrainedWindows += entry.counts?.constrained ?? 0
                skippedWindows += entry.counts?.skipped ?? 0
            }
        }
        incompleteOperations = started.subtracting(finished).count
    }
}
