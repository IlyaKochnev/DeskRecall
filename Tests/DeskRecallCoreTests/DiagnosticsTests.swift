import Foundation
import DeskRecallCore
import DeskRecallPlatform

@MainActor extension CoreTests {
    func testJournalPersistsAcrossInstancesWithoutRawWindowMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DiagnosticsLog(directory: directory)
        let rect = Rect(x: 0, y: 0, width: 1000, height: 800)
        let topology = Topology(displays: [DisplaySnapshot(id: "PRIVATE-DISPLAY-ID", name: "PRIVATE-NAME", builtIn: true,
                                                        frame: rect, visibleFrame: rect)])
        let start = Date().addingTimeInterval(-1)
        log.record(DiagnosticEntry(event: .applicationStarted, topology: topology))
        log.record(DiagnosticEntry(event: .heartbeat, topology: topology))
        log.flush()
        expectFalse(log.hasWriteFailure)
        let reopened = DiagnosticsLog(directory: directory)
        let history = await reopened.history(since: start)
        expectEqual(history.entries.count, 2)
        expectEqual(history.entries[0].sessionID, history.entries[1].sessionID)
        expectEqual(history.unreadableLines, 0)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let text = try String(contentsOf: file, encoding: .utf8)
            expectFalse(text.contains("PRIVATE-DISPLAY-ID")); expectFalse(text.contains("PRIVATE-NAME"))
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            expectEqual(permissions?.intValue, 0o600)
        }
    }
    func testJournalRotatesAndRepairsAnInterruptedLine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let limits = DiagnosticsLog.Limits(fileBytes: 1200, files: 3, retentionDays: 14)
        let log = DiagnosticsLog(directory: directory, limits: limits)
        for _ in 0..<30 { log.record(DiagnosticEntry(event: .heartbeat)) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        expectTrue(files.count <= 3)
        for file in files {
            let count = try Data(contentsOf: file).count
            expectTrue(count <= 1200)
        }
        // An interrupted last line must not swallow the next good event after a restart.
        let repairDirectory = directory.appendingPathComponent("repair")
        try FileManager.default.createDirectory(at: repairDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        let file = repairDirectory.appendingPathComponent("events-\(formatter.string(from: Date()))-000001.jsonl")
        try Data("{broken".utf8).write(to: file)
        let repaired = DiagnosticsLog(directory: repairDirectory)
        repaired.record(DiagnosticEntry(event: .applicationStarted)); repaired.flush()
        let history = await repaired.history(since: Date().addingTimeInterval(-10))
        expectEqual(history.entries.count, 1); expectEqual(history.unreadableLines, 1)
    }
    func testSummaryDoesNotCountNoProfileOrCancellationAsSuccess() {
        let a = UUID(); let b = UUID(); let c = UUID(); let d = UUID(); let incomplete = UUID()
        var full = DiagnosticCounts(); full.requested = 4; full.verified = 4
        var partial = DiagnosticCounts(); partial.requested = 3; partial.verified = 1; partial.constrained = 1; partial.skipped = 1
        let finish = DiagnosticEntry(event: .operationFinished, operationID: a, operation: .restore,
                                     counts: full, durationMS: 100, outcome: .success)
        let records = [
            DiagnosticEntry(event: .operationStarted, operationID: a, operation: .restore),
            DiagnosticEntry(event: .operationStarted, operationID: incomplete, operation: .restore),
            finish, finish, // A duplicate final event must not inflate the totals.
            DiagnosticEntry(event: .operationFinished, operationID: b, operation: .restore,
                            counts: partial, durationMS: 200, outcome: .partial),
            DiagnosticEntry(event: .operationFinished, operationID: c, operation: .restore, outcome: .noProfile),
            DiagnosticEntry(event: .operationFinished, operationID: d, operation: .restore, outcome: .cancelled)
        ]
        let summary = DiagnosticsSummary(entries: records)
        expectEqual(summary.restored, 1); expectEqual(summary.partial, 1)
        expectEqual(summary.noProfile, 1); expectEqual(summary.cancelled, 1)
        expectEqual(summary.completedRestores, 2); expectEqual(summary.durationMS, 300)
        expectEqual(summary.requestedWindows, 7); expectEqual(summary.verifiedWindows, 5)
        expectEqual(summary.incompleteOperations, 1)
    }
    func testJournalRetentionAndWriteFailuresAreVisible() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expired = directory.appendingPathComponent("events-2000-01-01-000001.jsonl")
        try Data("old".utf8).write(to: expired)
        let log = DiagnosticsLog(directory: directory)
        log.record(DiagnosticEntry(event: .heartbeat)); log.flush()
        expectFalse(FileManager.default.fileExists(atPath: expired.path))
        let notDirectory = directory.appendingPathComponent("file")
        try Data("file".utf8).write(to: notDirectory)
        let failing = DiagnosticsLog(directory: notDirectory)
        failing.record(DiagnosticEntry(event: .heartbeat)); failing.flush()
        expectTrue(failing.hasWriteFailure)
        let disabledDirectory = directory.appendingPathComponent("disabled")
        let disabled = DiagnosticsLog(directory: disabledDirectory, enabled: false)
        disabled.record(DiagnosticEntry(event: .applicationStarted)); disabled.flush()
        expectFalse(FileManager.default.fileExists(atPath: disabledDirectory.path))
    }
}
