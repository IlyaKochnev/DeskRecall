import AppKit
import DeskRecallCore

public enum DesktopRestoreError: Error, LocalizedError {
    case unsupported, changed, spaceNotVerified, geometryNotVerified
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Системный механизм управления столами недоступен."
        case .changed: return "Конфигурация экранов или идентичность окна изменилась."
        case .spaceNotVerified: return "Перенос на нужный рабочий стол не подтверждён."
        case .geometryNotVerified: return "Положение окна не совпало с сохранённым."
        }
    }
}
public struct DesktopRestoreReport: Sendable {
    public var requested = 0
    public var verified = 0
    public var constrained = 0
    public var skipped = 0
    public var details: [String] = []
    public init() {}
}

public actor DesktopRestorer {
    private let windows: WindowService
    public init(windows: WindowService = WindowService()) { self.windows = windows }
    private func inventory() async throws -> SystemInventory {
        let apps = await RunningApp.capture()
        return try SystemWindowReader.capture(apps: apps)
    }
    private func validate(_ topology: Topology) async throws {
        try Task.checkCancellation()
        let current = await DisplayService.capture()
        guard current.sameLayout(as: topology) else { throw DesktopRestoreError.changed }
        if let info = CGSessionCopyCurrentDictionary() as? [String:Any],
           info["CGSSessionScreenIsLocked"] as? Bool == true { throw DesktopRestoreError.changed }
    }
    public func prepareSpaces(profile: Profile, topology: Topology) async throws {
        guard profile.topology.key == topology.key else { throw ProfileStoreError.topologyMismatch }
        guard NativeWindowBridge.available else { throw DesktopRestoreError.unsupported }
        let before = try await inventory()
        let sameBoot = profile.windows.compactMap(\.systemIdentity).contains { saved in
            before.windows.contains { $0.identity.bootSession == saved.bootSession }
        }
        let scan = try await windows.scan(apps: await RunningApp.capture(), topology: topology)
        let matches = LegacyWindowMatcher.match(saved: profile.windows, current: scan.windows)
        let content = DesktopContentMatcher.match(saved: profile.windows, current: scan.windows, matches: matches)
        let desiredSpaces = (profile.spaces ?? []).sorted { ($0.displayID,$0.index) < ($1.displayID,$1.index) }
        var assigned: [UInt64:UInt64] = [:]
        var used = Set<UInt64>()
        // Reserve all identities before looking up ordinal fallbacks, so a desktop belonging to
        // another saved slot cannot be stolen just because it currently occupies this ordinal.
        for desired in desiredSpaces {
            let id = sameBoot ? before.spaces.first(where: { $0.systemID == desired.systemID && $0.type == desired.type })?.systemID : content[desired.systemID]
            if let id, !used.contains(id) { assigned[desired.systemID] = id; used.insert(id) }
        }
        for desired in desiredSpaces where assigned[desired.systemID] == nil {
            try await validate(topology)
            guard topology.displays.contains(where: { $0.id == desired.displayID }) || desired.displayID == "Main" else { throw SpaceResolutionError.missingDisplay }
            if let existing = before.spaces.first(where: {
                $0.displayID == desired.displayID && $0.index == desired.index && $0.type == desired.type && !used.contains($0.systemID)
            }) {
                assigned[desired.systemID] = existing.systemID; used.insert(existing.systemID)
            } else {
                guard desired.type == 0 else { throw SpaceResolutionError.specialSpace }
                let id = NativeWindowBridge.createSpace()
                guard id != 0 else { throw SpaceResolutionError.missingSpace(desired.index) }
                assigned[desired.systemID] = id; used.insert(id)
            }
        }
        // Moves can shift the index of a previously positioned desktop. Verify the complete mapping.
        for _ in 0..<3 {
            for desired in desiredSpaces {
                try await validate(topology)
                guard let id = assigned[desired.systemID] else { throw DesktopRestoreError.spaceNotVerified }
                let current = try await inventory()
                if current.spaces.contains(where: { $0.systemID == id && $0.displayID == desired.displayID && $0.index == desired.index }) { continue }
                guard NativeWindowBridge.moveSpace(id, displayID: desired.displayID, index: desired.index) else { throw DesktopRestoreError.unsupported }
                try await awaitSpace(id:id,desired:desired,topology:topology)
            }
            let after = try await inventory()
            if desiredSpaces.allSatisfy({ desired in after.spaces.contains { $0.systemID == assigned[desired.systemID] && $0.displayID == desired.displayID && $0.index == desired.index } }) { return }
        }
        throw DesktopRestoreError.spaceNotVerified
    }
    private func awaitSpace(id: UInt64, desired: SpaceReference, topology: Topology) async throws {
        for _ in 0..<25 {
            try await validate(topology)
            if try await inventory().spaces.contains(where: { $0.systemID == id && $0.displayID == desired.displayID && $0.index == desired.index }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DesktopRestoreError.spaceNotVerified
    }
    public func move(identity: SystemWindowIdentity, to spaces: [SpaceReference], topology: Topology) async throws {
        try await validate(topology)
        let current = try await inventory()
        guard let window = current.windows.first(where: { $0.identity == identity }) else { throw WindowServiceError.unavailable }
        let target = Set(spaces.map(\.systemID))
        if target == Set(window.spaces.map(\.systemID)) { return }
        guard let destination = spaces.first else { throw DesktopRestoreError.unsupported }
        guard current.spaces.contains(where: { $0.systemID == destination.systemID }),
              NativeWindowBridge.move(windowID: identity.windowID, to: destination.systemID) else { throw DesktopRestoreError.unsupported }
        if spaces.count > 1 {
            guard NativeWindowBridge.add(windowID: identity.windowID, to: Array(spaces.dropFirst().map(\.systemID))) else {
                throw DesktopRestoreError.unsupported
            }
        }
        for _ in 0..<25 {
            try await validate(topology)
            if let actual = try await inventory().windows.first(where: { $0.identity == identity }), Set(actual.spaces.map(\.systemID)) == target { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DesktopRestoreError.spaceNotVerified
    }
    public func restoreWindow(saved: WindowSnapshot, current: WindowSnapshot, profile: Profile,
                              topology: Topology) async throws -> ApplyResult {
        try await validate(topology)
        guard let oldDisplay = profile.topology.displays.first(where: { $0.id == saved.displayID }),
              let newDisplay = topology.displays.first(where: { $0.id == saved.displayID }) else { throw SpaceResolutionError.missingDisplay }
        let target = Geometry.target(window: saved.frame, oldDisplay: oldDisplay, newDisplay: newDisplay)
        let prewarmApps = await RunningApp.capture().filter { $0.bundleID == current.appID }
        _ = try await windows.scan(apps: prewarmApps, topology: topology)
        let before = try await inventory()
        var desired: [SpaceReference] = []
        if let savedSpaces = saved.spaces, !savedSpaces.isEmpty {
            desired = try SpaceResolver.resolve(saved: savedSpaces, current: before.spaces, topology: topology,
                sameBoot: saved.systemIdentity?.bootSession == current.systemIdentity?.bootSession)
            guard let identity = current.systemIdentity else { throw WindowServiceError.unavailable }
            try await move(identity: identity, to: desired, topology: topology)
        }
        let actualBefore = try await inventory().windows.first { $0.identity == current.systemIdentity }
        let result: ApplyResult
        if let actualBefore, actualBefore.frame.isClose(to: target) {
            result = .restored(actual: actualBefore.frame)
        } else {
            result = try await applyGeometry(window: current, target: target, returnSpaces: desired, topology: topology)
        }
        try await validate(topology)
        if let identity = current.systemIdentity {
            guard let after = try await inventory().windows.first(where: { $0.identity == identity }) else { throw WindowServiceError.unavailable }
            if !desired.isEmpty && Set(after.spaces.map(\.systemID)) != Set(desired.map(\.systemID)) { throw DesktopRestoreError.spaceNotVerified }
            if after.frame.isClose(to: target) { return .restored(actual: after.frame) }
            return .constrained(actual: after.frame)
        }
        return result
    }
    public func restore(profile: Profile, topology: Topology) async throws -> DesktopRestoreReport {
        try await prepareSpaces(profile: profile, topology: topology)
        let apps = await RunningApp.capture()
        let scan = try await windows.scan(apps: apps, topology: topology)
        let matches = LegacyWindowMatcher.match(saved: profile.windows, current: scan.windows)
        return try await converge(profile:profile,current:scan.windows,matches:matches,topology:topology)
    }
    /// Final verification after all apps have reacted, rather than summing transient per-window successes.
    public func converge(profile: Profile, current: [WindowSnapshot], matches: [WindowMatch], topology: Topology) async throws -> DesktopRestoreReport {
        var failures: [Int:String] = [:]
        for _ in 0..<3 {
            try await validate(topology)
            let state = try await inventory()
            for pair in matches {
                let saved=profile.windows[pair.savedIndex]; let window=current[pair.currentIndex]
                if try isVerified(saved:saved,current:window,profile:profile,topology:topology,inventory:state) { continue }
                do { _ = try await restoreWindow(saved:saved,current:window,profile:profile,topology:topology) }
                catch is CancellationError { throw CancellationError() }
                catch { failures[pair.savedIndex]=error.localizedDescription }
            }
            try await Task.sleep(for:.milliseconds(700))
            let after = try await inventory()
            if try matches.allSatisfy({ try isVerified(saved:profile.windows[$0.savedIndex],current:current[$0.currentIndex],profile:profile,topology:topology,inventory:after) }) { break }
        }
        let final = try await inventory()
        var report=DesktopRestoreReport(); report.requested=profile.windows.count
        for pair in matches {
            let saved=profile.windows[pair.savedIndex]
            if try isVerified(saved:saved,current:current[pair.currentIndex],profile:profile,topology:topology,inventory:final) { report.verified += 1 }
            else { report.details.append(saved.appID + ": " + (failures[pair.savedIndex] ?? "Итоговая геометрия или стол не совпали с профилем.")) }
        }
        report.skipped=report.requested-report.verified
        return report
    }
    private func isVerified(saved: WindowSnapshot, current: WindowSnapshot, profile: Profile, topology: Topology, inventory: SystemInventory) throws -> Bool {
        guard let identity=current.systemIdentity, let live=inventory.windows.first(where: { $0.identity == identity }),
              let old=profile.topology.displays.first(where: { $0.id == saved.displayID }),
              let new=topology.displays.first(where: { $0.id == saved.displayID }) else { return false }
        let target=Geometry.target(window:saved.frame,oldDisplay:old,newDisplay:new)
        let desired=try SpaceResolver.resolve(saved:saved.spaces ?? [],current:inventory.spaces,topology:topology,sameBoot:false)
        return live.frame.isClose(to:target) && (desired.isEmpty || Set(live.spaces.map(\.systemID)) == Set(desired.map(\.systemID)))
    }
    private func applyGeometry(window: WindowSnapshot, target: Rect, returnSpaces: [SpaceReference], topology: Topology) async throws -> ApplyResult {
        let apps = await RunningApp.capture().filter { $0.bundleID == window.appID }
        _ = try await windows.scan(apps: apps, topology: topology)
        do {
            let result = try await windows.apply(token: window.runtimeToken, target: target, topology: topology)
            if case .restored = result { return result }
            throw DesktopRestoreError.geometryNotVerified
        }
        catch is CancellationError { throw CancellationError() }
        catch WindowServiceError.permission { throw WindowServiceError.permission }
        catch {
            // Some clients refuse remote AX objects. Temporarily stage only this window on a visible
            // user Space, reacquire its AX object, and return it to the requested Space afterwards.
            guard let identity = window.systemIdentity, PermissionService.isTrusted else { throw error }
            let state = try await inventory()
            guard let original = state.windows.first(where: { $0.identity == identity }),
                  let stage = state.spaces.first(where: { $0.active && $0.type == 0 && $0.displayID == window.displayID }) ??
                    state.spaces.first(where: { $0.active && $0.type == 0 }) else { throw error }
            let finalSpaces = returnSpaces.isEmpty ? original.spaces : returnSpaces
            let priorFront = await MainActor.run { NSWorkspace.shared.frontmostApplication }
            try await move(identity:identity,to:[stage],topology:topology)
            _ = await MainActor.run {
                NSRunningApplication(processIdentifier:identity.pid)?.activate(options:[])
            }
            try await Task.sleep(for:.milliseconds(350))
            do {
                _ = try await windows.scan(apps:apps,topology:topology)
                await windows.reacquireVisibleWindow(token:window.runtimeToken)
                let result = try await windows.apply(token:window.runtimeToken,target:target,topology:topology)
                try await move(identity:identity,to:finalSpaces,topology:topology)
                _ = await MainActor.run { priorFront?.activate(options:[]) }
                return result
            } catch {
                try? await move(identity:identity,to:finalSpaces,topology:topology)
                _ = await MainActor.run { priorFront?.activate(options:[]) }
                throw error
            }
        }
    }
    public func perturb(window: WindowSnapshot, frame: Rect, spaces: [SpaceReference], topology: Topology) async throws {
        guard let identity = window.systemIdentity else { throw WindowServiceError.unavailable }
        try await move(identity: identity, to: spaces, topology: topology)
        let result = try await applyGeometry(window: window, target: frame, returnSpaces: spaces, topology: topology)
        _ = result
        guard let actual = try await inventory().windows.first(where: { $0.identity == identity }),
              actual.frame.isClose(to: frame), Set(actual.spaces.map(\.systemID)) == Set(spaces.map(\.systemID)) else {
            throw DesktopRestoreError.geometryNotVerified
        }
    }
}
