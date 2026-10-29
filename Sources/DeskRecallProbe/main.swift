import AppKit
import ApplicationServices
import DeskRecallCore
import DeskRecallPlatform
import Darwin

@MainActor func exerciseSpaceLifecycle() async throws {
    _ = NSApplication.shared
    let before = try SystemWindowReader.capture(apps: RunningApp.capture())
    guard let first = before.spaces.first(where: { $0.type == 0 }) else { throw WindowServiceError.unavailable }
    let created = NativeWindowBridge.createSpace()
    guard created != 0 else { print("{\"created\":false}"); throw DesktopRestoreError.unsupported }
    let index = before.spaces.filter { $0.displayID == first.displayID }.count + 1
    let submitted = NativeWindowBridge.moveSpace(created, displayID: first.displayID, index: index)
    var verified = false
    for _ in 0..<30 {
        try await Task.sleep(for: .milliseconds(100))
        if try SystemWindowReader.capture(apps: RunningApp.capture()).spaces.contains(where: { $0.systemID == created && $0.displayID == first.displayID }) { verified = true; break }
    }
    var movedAcrossDisplay = false
    if verified, let second = before.spaces.first(where: { $0.displayID != first.displayID }) {
        _ = NativeWindowBridge.moveSpace(created, displayID: second.displayID,
            index: before.spaces.filter { $0.displayID == second.displayID }.count + 1)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if try SystemWindowReader.capture(apps: RunningApp.capture()).spaces.contains(where: { $0.systemID == created && $0.displayID == second.displayID }) { movedAcrossDisplay = true; break }
        }
    }
    let current = try SystemWindowReader.capture(apps: RunningApp.capture())
    let exclusive = current.windows.filter { $0.spaces.count == 1 && $0.spaces[0].systemID == created }
    var removed = false
    if exclusive.isEmpty {
        _ = NativeWindowBridge.destroySpace(created)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if try !SystemWindowReader.capture(apps: RunningApp.capture()).spaces.contains(where: { $0.systemID == created }) { removed = true; break }
        }
    }
    let result: [String:Any] = ["created":true,"attached":submitted && verified,"movedAcrossDisplays":movedAcrossDisplay,
                               "testSpaceRemoved":removed,"originalDesktopCount":before.spaces.count,
                               "finalDesktopCount":try SystemWindowReader.capture(apps: RunningApp.capture()).spaces.count]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options:[.prettyPrinted,.sortedKeys]), as:UTF8.self))
    guard verified && movedAcrossDisplay && removed else { throw DesktopRestoreError.spaceNotVerified }
}

@MainActor func exerciseNativeRestoration() async throws {
    _ = NSApplication.shared
    let own = NSRunningApplication.current
    let token = RunningApp(pid: own.processIdentifier, bundleID: "local.deskrecall.probe",
                           launchTime: own.launchDate?.timeIntervalSince1970 ?? 0)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.title = "DeskRecall — проверка восстановления"
    window.orderFrontRegardless()
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(400))
    func current() throws -> SystemWindowRecord {
        guard let item = try SystemWindowReader.capture(apps: [token]).windows.first(where: { $0.identity.windowID == UInt32(window.windowNumber) }) else {
            throw WindowServiceError.unavailable
        }
        return item
    }
    let before = try current()
    let inventory = try SystemWindowReader.capture(apps: [token])
    guard let source = before.spaces.first,
          let destination = inventory.spaces.first(where: { $0.type == 0 && $0.displayID != source.displayID }) ?? inventory.spaces.first(where: { $0.systemID != source.systemID && $0.type == 0 }) else {
        throw WindowServiceError.unavailable
    }
    var submitted = NativeWindowBridge.move(windowID: before.identity.windowID, to: destination.systemID)
    var membership = false
    for _ in 0..<20 {
        try await Task.sleep(for: .milliseconds(100))
        if try current().spaces.contains(where: { $0.systemID == destination.systemID }) { membership = true; break }
    }
    submitted = NativeWindowBridge.move(windowID: before.identity.windowID, to: source.systemID) && submitted
    try await Task.sleep(for: .milliseconds(300))
    let restored = try current()
    let result: [String:Any] = ["bridgeAvailable":NativeWindowBridge.available,"spaceSubmitted":submitted,
        "spaceVerified":membership,"geometryMutationTested":false,
        "originalSpaceRestored":restored.spaces.contains { $0.systemID == source.systemID },
        "originalGeometryRestored":restored.frame.isClose(to:before.frame),
        "accessibilityTrusted":PermissionService.isTrusted]
    print(String(decoding:try JSONSerialization.data(withJSONObject: result, options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    guard membership else { throw WindowServiceError.readOnly }
}

@MainActor func captureAndVerifyProfile() async throws {
    _ = NSApplication.shared
    let topology = DisplayService.capture()
    guard topology.isSupported else { throw ProfileStoreError.invalidProfile }
    let apps = RunningApp.capture()
    let expected = try SystemWindowReader.capture(apps: apps)
    guard expected.spaceReadAvailable else { throw WindowServiceError.unavailable }
    let scan = try await WindowService().scan(apps: apps, topology: topology)
    let found = Set(scan.windows.compactMap { $0.systemIdentity?.windowID })
    let required = Set(expected.windows.map { $0.identity.windowID })
    guard required.isSubset(of: found), scan.issues.isEmpty, DisplayService.capture().sameLayout(as: topology) else {
        throw WindowServiceError.changed
    }
    var profile = Profile(topology: topology, windows: scan.windows, coverage: scan.coverage)
    profile.captureScope = .systemAndAccessibility; profile.spaces = scan.spaces
    let customDirectory = CommandLine.arguments.first(where: { $0.hasPrefix("--output-directory=") }).map { URL(fileURLWithPath:String($0.dropFirst("--output-directory=".count)),isDirectory:true) }
    let store = ProfileStore(directory:customDirectory)
    let diary = DiagnosticsLog()
    let operationID = UUID()
    var counts = DiagnosticCounts(); counts.scanned = scan.windows.count; counts.coverage = scan.coverage
    diary.record(DiagnosticEntry(event: .operationStarted, operationID: operationID, operation: .save,
        trigger: .manual, topology: topology, trusted: PermissionService.isTrusted))
    var outcome: DiagnosticOutcome = .failed
    defer {
        diary.record(DiagnosticEntry(event: .operationFinished, operationID: operationID, operation: .save,
            trigger: .manual, topology: topology, trusted: PermissionService.isTrusted, counts: counts, outcome: outcome))
        diary.flush()
    }
    try await store.save(profile)
    guard let loaded = try await store.load(key: topology.key), loaded == profile else { throw ProfileStoreError.invalidProfile }
    let after = try SystemWindowReader.capture(apps: RunningApp.capture())
    let saved = Set(loaded.windows.compactMap { $0.systemIdentity?.windowID })
    let missing = Set(after.windows.map { $0.identity.windowID }).subtracting(saved)
    let targets = ["com.google.Chrome", "com.apple.Terminal", "com.apple.iCal", "com.apple.ActivityMonitor"]
    let summary: [String: Any] = [
        "saved": true, "schemaVersion": loaded.schemaVersion, "profileWindows": loaded.windows.count,
        "systemWindows": after.windows.count, "systemOnly": scan.coverage.systemOnly ?? 0,
        "managedDesktops": loaded.spaces?.count ?? 0, "missingSystemWindows": missing.count,
        "allSystemWindowsSaved": missing.isEmpty,
        "targets": targets.map { app in
            let current = after.windows.filter { $0.appID == app }
            let persisted = loaded.windows.filter { $0.appID == app }
            let expectedIDs = Set(current.map { $0.identity.windowID })
            let actualIDs = Set(persisted.compactMap { $0.systemIdentity?.windowID })
            return ["appID": app, "systemWindows": current.count, "savedWindows": persisted.count,
                    "allSaved": expectedIDs.isSubset(of: actualIDs)] as [String: Any]
        },
        "desktops": (loaded.spaces ?? []).map { space in
            let current = after.windows.filter { $0.spaces.contains { $0.systemID == space.systemID } }
            let persisted = loaded.windows.filter { ($0.spaces ?? []).contains { $0.systemID == space.systemID } }
            return ["desktopIndex": space.index, "active": space.active,
                    "systemWindows": current.count, "savedWindows": persisted.count] as [String: Any]
        }
    ]
    print(String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    guard missing.isEmpty else { throw WindowServiceError.changed }
    outcome = .success
    diary.record(DiagnosticEntry(event: .profileSaved, operationID: operationID, operation: .save,
        trigger: .manual, topology: topology, trusted: PermissionService.isTrusted, counts: counts, profile: loaded))
}

@MainActor func probe() async {
    _ = NSApplication.shared
    let topology = DisplayService.capture()
    let apps = RunningApp.capture()
    var report: [String: Any] = [
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "accessibilityTrusted": PermissionService.isTrusted,
        "displayCount": topology.displays.count,
        "topologySupported": topology.isSupported,
        "mirrored": topology.mirrored,
        "eligibleApplicationCount": apps.count,
        "spacesMutationsAttempted": false,
        "screenRecordingRequested": false
    ]
    let appPIDs = Set(apps.map(\.pid))
    if let graph = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        let windows = graph.filter { item in
            guard let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return false }
            return appPIDs.contains(pid) && (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
        report["systemApplicationWindowCount"] = windows.count
        report["systemOffscreenWindowCount"] = windows.filter { ($0[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != true }.count
    }
    if PermissionService.isTrusted {
        do {
            let scan = try await WindowService().scan(apps: apps, topology: topology)
            report["accessibleWindowCount"] = scan.windows.count
            report["offscreenWindowCount"] = scan.coverage.offScreen
            report["minimizedWindowCount"] = scan.coverage.minimized
            report["fullscreenWindowCount"] = scan.coverage.fullscreen
            report["excludedWindowCount"] = scan.excluded
            report["scanIssueCount"] = scan.issues.count
        } catch { report["scanError"] = error.localizedDescription }
    }
    // Private APIs are confined to this explicitly requested read-only experiment, never the app.
    if CommandLine.arguments.contains("--probe-spaces") {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        if let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) {
            defer { dlclose(handle) }
            if let connectionSymbol = dlsym(handle, "CGSMainConnectionID"),
               let spacesSymbol = dlsym(handle, "CGSCopyManagedDisplaySpaces") {
                typealias Connection = @convention(c) () -> UInt32
                typealias CopySpaces = @convention(c) (UInt32) -> Unmanaged<CFArray>?
                let connection = unsafeBitCast(connectionSymbol, to: Connection.self)
                let copySpaces = unsafeBitCast(spacesSymbol, to: CopySpaces.self)
                if let result = copySpaces(connection())?.takeRetainedValue() as? [[String: Any]] {
                    report["privateSpacesReadSucceeded"] = true
                    report["managedDisplayCount"] = result.count
                    report["spaceCountsPerDisplay"] = result.map { ($0["Spaces"] as? [Any])?.count ?? 0 }
                } else { report["privateSpacesReadSucceeded"] = false }
            } else { report["privateSpacesSymbolsAvailable"] = false }
        } else { report["skyLightAvailable"] = false }
    }
    do {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch { fputs("Failed to encode diagnostic summary.\n", stderr) }
}
if CommandLine.arguments.contains("--exercise-space-lifecycle") {
    do { try await exerciseSpaceLifecycle() }
    catch { print("Space lifecycle exercise failed: \(error.localizedDescription)"); exit(1) }
} else if CommandLine.arguments.contains("--exercise-native") {
    do { try await exerciseNativeRestoration() }
    catch { print("Native exercise failed: \(error.localizedDescription)"); exit(1) }
} else if CommandLine.arguments.contains("--capture-profile") {
    do { try await captureAndVerifyProfile() }
    catch { print("Capture verification failed: \(error.localizedDescription)"); exit(1) }
} else { await probe() }
