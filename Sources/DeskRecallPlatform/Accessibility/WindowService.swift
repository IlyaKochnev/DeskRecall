import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import DeskRecallCore

public enum WindowServiceError: Error, LocalizedError {
    case permission
    case unavailable
    case changed
    case readOnly
    case noAccessibilityElement
    case ax(Int32)
    public var errorDescription: String? {
        switch self {
        case .permission: return "Нужен доступ «Универсальный доступ»."
        case .unavailable: return "Окно больше недоступно."
        case .changed: return "Состояние окна изменилось; оно пропущено."
        case .noAccessibilityElement: return "Окно есть в WindowServer, но приложение не предоставляет для него объект управления Accessibility."
        case .readOnly: return "Окно сохранено, но его текущий режим не допускает изменение геометрии."
        case .ax(let code): return "Приложение отклонило изменение окна (\(code))."
        }
    }
}

public enum PermissionService {
    public static var isTrusted: Bool { AXIsProcessTrusted() }
    public static func request() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

public enum ApplyResult: Sendable {
    case restored(actual: Rect)
    case constrained(actual: Rect)
}

public actor WindowService {
    private struct LiveWindow {
        let token: UUID
        let app: RunningApp
        let element: AXUIElement?
    }
    private var live: [UUID: LiveWindow] = [:]
    private let windowNumber = AXWindowNumberReader()
    private var resolvedRemote: [UUID: AXUIElement] = [:]
    public init() {}

    public func scan(apps: [RunningApp], topology: Topology) throws -> WindowScan {
        let inventory = try SystemWindowReader.capture(apps: apps)
        var next: [UUID: LiveWindow] = [:]
        var accessible: [WindowSnapshot] = []
        var result = WindowScan(windows: [])
        if PermissionService.isTrusted {
            for app in apps {
                try Task.checkCancellation()
                let element = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(element, 0.5)
                _ = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                var raw: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw) == .success,
                      let roots = raw as? [AXUIElement] else { continue }
                var pending = roots; var seen: [AXUIElement] = []
                while let window = pending.popLast() {
                    try Task.checkCancellation()
                    guard !seen.contains(where: { CFEqual($0, window) }) else { continue }
                    seen.append(window); AXUIElementSetMessagingTimeout(window, 0.5)
                    if let children: [AXUIElement] = attribute(window, kAXChildrenAttribute) {
                        pending.append(contentsOf: children.filter { (attribute($0, kAXRoleAttribute) as String?) == kAXSheetRole })
                    }
                    let role: String? = attribute(window, kAXRoleAttribute)
                    guard role == kAXWindowRole || role == kAXSheetRole else { result.excluded += 1; continue }
                    guard let frame = frame(window), frame.isValid,
                          let display = Geometry.display(for: frame, in: topology.displays) else { continue }
                    let number = windowNumber.id(for: window)
                    let system = inventory.windows.first { $0.identity.pid == app.pid && $0.identity.windowID == number }
                    let previous = live.values.first {
                        guard $0.app.pid == app.pid, $0.app.launchTime == app.launchTime, let old = $0.element else { return false }
                        return CFEqual(old, window)
                    }
                    let token = system?.identity.runtimeToken ?? previous?.token ?? UUID()
                    let state = WindowState(minimized: attribute(window, kAXMinimizedAttribute) ?? false,
                        fullscreen: attribute(window, "AXFullScreen") ?? false,
                        canMove: isSettable(window, kAXPositionAttribute), canResize: isSettable(window, kAXSizeAttribute),
                        onScreen: system?.onScreen ?? false)
                    var snapshot = WindowSnapshot(runtimeToken: token, appID: app.bundleID,
                        role: role!, subrole: attribute(window, kAXSubroleAttribute) ?? "",
                        identifierHash: hash(attribute(window, kAXIdentifierAttribute)),
                        documentHash: hash(attribute(window, kAXDocumentAttribute)), titleHash: hash(attribute(window, kAXTitleAttribute)),
                        displayID: display.id, frame: frame, state: state)
                    snapshot.systemIdentity = system?.identity; snapshot.captureSource = .accessibility
                    next[token] = LiveWindow(token: token, app: app, element: window)
                    resolvedRemote[token] = window
                    accessible.append(snapshot)
                }
            }
        }
        result.windows = WindowSnapshotAssembler.assemble(system: inventory.windows, accessibility: accessible, topology: topology)
        // Normalize live handles to stable system tokens, also for unique geometry fallback mappings.
        let rawLive = next
        next = [:]
        for snapshot in result.windows {
            let exact = accessible.first { $0.systemIdentity != nil && $0.systemIdentity == snapshot.systemIdentity }
            let matches = accessible.filter { $0.appID == snapshot.appID && $0.frame.isClose(to: snapshot.frame, tolerance: 2) }
            let ax = snapshot.captureSource == .system ? nil : (exact ?? (matches.count == 1 ? matches.first : nil))
            if let ax, let handle = rawLive[ax.runtimeToken] {
                next[snapshot.runtimeToken] = LiveWindow(token: snapshot.runtimeToken, app: handle.app, element: handle.element)
            } else if let identity = snapshot.systemIdentity, let app = apps.first(where: { $0.pid == identity.pid }) {
                let cached = live[snapshot.runtimeToken]?.element ?? resolvedRemote[snapshot.runtimeToken]
                let validCached = cached.flatMap { windowNumber.id(for: $0) == identity.windowID ? $0 : nil }
                next[snapshot.runtimeToken] = LiveWindow(token: snapshot.runtimeToken, app: app, element: validCached)
            }
            if let state = snapshot.state { result.coverage.include(state) }
        }
        result.coverage.applications = apps.count
        result.coverage.discovered = result.windows.count
        result.coverage.systemWindowCount = inventory.windows.count
        result.coverage.systemOnly = result.windows.filter { $0.captureSource == .system }.count
        result.coverage.spacesRead = inventory.spaceReadAvailable
        result.coverage.desktopCount = inventory.spaces.count
        result.spaces = inventory.spaces
        if !inventory.spaceReadAvailable {
            result.issues.append(ScanIssue(appID: "WindowServer", reason: "Привязку к рабочим столам прочитать не удалось; полнота охвата не подтверждена."))
        }
        live = next
        return result
    }

    /// Enrich inactive-Space windows without moving them or saving raw titles/documents.
    public func scanForPersistence(apps: [RunningApp], topology: Topology) async throws -> WindowScan {
        var result = try scan(apps: apps, topology: topology)
        guard PermissionService.isTrusted else { return result }
        let began = ContinuousClock.now
        var failedPIDs = Set<Int32>()
        for index in result.windows.indices {
            try Task.checkCancellation()
            guard began.duration(to:.now) < .seconds(20), let identity = result.windows[index].systemIdentity,
                  !failedPIDs.contains(identity.pid) else { continue }
            let candidate = live[identity.runtimeToken]?.element ?? resolvedRemote[identity.runtimeToken]
            let element: AXUIElement?
            if let candidate { element = candidate }
            else { element = try await resolveRemoteWindow(identity) }
            guard let element, windowNumber.id(for:element) == identity.windowID else { failedPIDs.insert(identity.pid); continue }
            result.windows[index].identifierHash = hash(attribute(element,kAXIdentifierAttribute))
            result.windows[index].documentHash = hash(attribute(element,kAXDocumentAttribute))
            result.windows[index].titleHash = hash(attribute(element,kAXTitleAttribute))
            result.windows[index].subrole = attribute(element,kAXSubroleAttribute) ?? result.windows[index].subrole
            result.windows[index].captureSource = .combined
            var state=result.windows[index].state ?? WindowState()
            state.canMove=isSettable(element,kAXPositionAttribute); state.canResize=isSettable(element,kAXSizeAttribute)
            result.windows[index].state=state
        }
        return result
    }

    public func reacquireVisibleWindow(token: UUID) {
        guard PermissionService.isTrusted, let liveWindow = live[token],
              let rect = serverFrame(token:token,app:liveWindow.app) else { return }
        let app = AXUIElementCreateApplication(liveWindow.app.pid)
        var candidates: [AXUIElement] = []
        if let focused: AXUIElement = attribute(app,kAXFocusedWindowAttribute) { candidates.append(focused) }
        if let main: AXUIElement = attribute(app,kAXMainWindowAttribute) { candidates.append(main) }
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(rect.x+rect.width/2),Float(rect.y+rect.height/2),&hit) == .success, let hit {
            candidates.append(hit)
            if let window: AXUIElement = attribute(hit,kAXWindowAttribute) { candidates.append(window) }
        }
        for element in candidates {
            guard let id = windowNumber.id(for:element), inventoryIdentity(token:token,app:liveWindow.app,windowID:id) else { continue }
            resolvedRemote[token]=element
            live[token]=LiveWindow(token:token,app:liveWindow.app,element:element)
            return
        }
    }

    public func apply(token: UUID, target: Rect, topology: Topology) async throws -> ApplyResult {
        try Task.checkCancellation()
        guard PermissionService.isTrusted else { throw WindowServiceError.permission }
        guard target.isValid, let window = live[token] else { throw WindowServiceError.unavailable }
        var element = window.element ?? resolvedRemote[token]
        if element == nil {
            let apps = await RunningApp.capture()
            let inventory = try SystemWindowReader.capture(apps: apps)
            guard let record = inventory.windows.first(where: { $0.identity.runtimeToken == token }) else {
                throw WindowServiceError.unavailable
            }
            if record.frame.isClose(to: target) { return .restored(actual: record.frame) }
            element = try await resolveRemoteWindow(record.identity)
        }
        guard let element else { throw WindowServiceError.noAccessibilityElement }
        let appElement = AXUIElementCreateApplication(window.app.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        // Verify the same process is alive, and the AX window still belongs to it.
        guard let app = NSRunningApplication(processIdentifier: window.app.pid), !app.isTerminated,
              app.bundleIdentifier == window.app.bundleID,
              (app.launchDate?.timeIntervalSince1970 ?? 0) == window.app.launchTime,
              live[token]?.token == token,
              let actualNumber = windowNumber.id(for: element),
              inventoryIdentity(token: token, app: window.app, windowID: actualNumber),
              frame(element) != nil else { throw WindowServiceError.unavailable }
        let fullscreen: Bool? = attribute(element, "AXFullScreen")
        let minimized: Bool? = attribute(element, kAXMinimizedAttribute)
        if let actual = serverFrame(token:token,app:window.app), actual.isClose(to:target) { return .restored(actual:actual) }
        guard fullscreen != true else { throw WindowServiceError.readOnly }
        let enhanced: Bool? = attribute(appElement, "AXEnhancedUserInterface")
        if enhanced == true { _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced == true { _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        let canMove = isSettable(element, kAXPositionAttribute)
        let canResize = isSettable(element, kAXSizeAttribute)
        guard canMove || canResize else { throw WindowServiceError.readOnly }
        // Do not activate apps, unminimize windows, or switch Spaces as a side effect.
        _ = minimized
        for _ in 0..<2 {
            try await validate(topology: topology)
            try Task.checkCancellation()
            guard PermissionService.isTrusted else { throw WindowServiceError.permission }
            var size = CGSize(width: target.width, height: target.height)
            var point = CGPoint(x: target.x, y: target.y)
            guard let sizeValue = AXValueCreate(.cgSize, &size), let pointValue = AXValueCreate(.cgPoint, &point) else {
                throw WindowServiceError.unavailable
            }
            if canResize { try set(element, kAXSizeAttribute, sizeValue) }
            try await validate(topology: topology)
            if canMove { try set(element, kAXPositionAttribute, pointValue) }
            if canResize { try set(element, kAXSizeAttribute, sizeValue) }
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(100))
                try await validate(topology: topology)
                if let actual = serverFrame(token: token, app: window.app), actual.isClose(to: target) {
                    return .restored(actual: actual)
                }
            }
        }
        guard let actual = serverFrame(token: token, app: window.app) ?? frame(element) else { throw WindowServiceError.unavailable }
        return .constrained(actual: actual)
    }

    private func serverFrame(token: UUID, app: RunningApp) -> Rect? {
        try? SystemWindowReader.capture(apps: [app]).windows.first { $0.identity.runtimeToken == token }?.frame
    }
    private func inventoryIdentity(token: UUID, app: RunningApp, windowID: UInt32) -> Bool {
        guard let inventory = try? SystemWindowReader.capture(apps: [app]) else { return false }
        return inventory.windows.contains { $0.identity.windowID == windowID && $0.identity.runtimeToken == token }
    }

    private func resolveRemoteWindow(_ identity: SystemWindowIdentity) async throws -> AXUIElement? {
        guard PermissionService.isTrusted else { throw WindowServiceError.permission }
        guard let create = windowNumber.createRemote else { return nil }
        let token = identity.runtimeToken
        if let cached = resolvedRemote[token], windowNumber.id(for: cached) == identity.windowID { return cached }
        let began = ContinuousClock.now
        // Only roles and IDs are inspected; no contents or titles are read during this lookup.
        for elementID in UInt64(0)..<UInt64(0x8000) {
            if elementID % 8 == 0 {
                try Task.checkCancellation()
                guard PermissionService.isTrusted else { throw WindowServiceError.permission }
                if began.duration(to: .now) > .seconds(8) { break }
                await Task.yield()
            }
            var bytes = [UInt8](repeating: 0, count: 20)
            var pid = identity.pid; var magic: UInt32 = 0x636f636f; var number = elementID
            withUnsafeBytes(of: &pid) { bytes.replaceSubrange(0..<4, with: $0) }
            withUnsafeBytes(of: &magic) { bytes.replaceSubrange(8..<12, with: $0) }
            withUnsafeBytes(of: &number) { bytes.replaceSubrange(12..<20, with: $0) }
            guard let candidate = create(Data(bytes) as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(candidate, 0.08)
            let role: String? = attribute(candidate, kAXRoleAttribute)
            guard role == kAXWindowRole || role == kAXSheetRole,
                  let wid = windowNumber.id(for: candidate) else { continue }
            // Cache other resolved windows of this process to avoid repeating the search.
            let matching = live.values.filter { $0.app.pid == identity.pid && $0.app.launchTime == identity.launchTime }
            for entry in matching {
                if let server = try? SystemWindowReader.capture(apps: [entry.app]).windows.first(where: { $0.identity.windowID == wid }) {
                    resolvedRemote[server.identity.runtimeToken] = candidate
                }
            }
            if wid == identity.windowID { resolvedRemote[token] = candidate; return candidate }
        }
        return nil
    }

    private func containsWindow(_ target: AXUIElement, in roots: [AXUIElement]) -> Bool {
        var pending = roots; var seen: [AXUIElement] = []
        while let window = pending.popLast() {
            if CFEqual(window, target) { return true }
            guard !seen.contains(where: { CFEqual($0, window) }) else { continue }
            seen.append(window)
            AXUIElementSetMessagingTimeout(window, 0.5)
            if let children: [AXUIElement] = attribute(window, kAXChildrenAttribute) {
                pending.append(contentsOf: children.filter { (attribute($0, kAXRoleAttribute) as String?) == kAXSheetRole })
            }
        }
        return false
    }

    private func validate(topology: Topology) async throws {
        try Task.checkCancellation()
        guard PermissionService.isTrusted else { throw WindowServiceError.permission }
        let current = await DisplayService.capture()
        try Task.checkCancellation()
        guard current.sameLayout(as: topology) else { throw CancellationError() }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if session["CGSSessionScreenIsLocked"] as? Bool == true { throw CancellationError() }
            if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { throw CancellationError() }
        }
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
    private func frame(_ element: AXUIElement) -> Rect? {
        var positionRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRaw) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success,
              let positionRaw, let sizeRaw,
              CFGetTypeID(positionRaw) == AXValueGetTypeID(), CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }
        let position = positionRaw as! AXValue
        let size = sizeRaw as! AXValue
        var point = CGPoint.zero; var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return Rect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }
    private func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var value: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
    }
    private func hash(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) throws {
        let error = AXUIElementSetAttributeValue(element, name as CFString, value)
        if error != .success { throw WindowServiceError.ax(error.rawValue) }
    }
}

/// A private read-only bridge maps an already accessible AX object to its WindowServer ID.
private final class AXWindowNumberReader {
    typealias Read = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
    private let library: UnsafeMutableRawPointer?
    private let read: Read?
    typealias Create = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    let createRemote: Create?
    init() {
        library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL)
        if let library, let symbol = dlsym(library, "_AXUIElementCreateWithRemoteToken") {
            createRemote = unsafeBitCast(symbol, to: Create.self)
        } else { createRemote = nil }
        if let library, let symbol = dlsym(library, "_AXUIElementGetWindow") {
            read = unsafeBitCast(symbol, to: Read.self)
        } else { read = nil }
    }
    deinit { if let library { dlclose(library) } }
    func id(for window: AXUIElement) -> UInt32? {
        var id: UInt32 = 0
        guard let read, read(window, &id) == .success, id != 0 else { return nil }; return id
    }
}
