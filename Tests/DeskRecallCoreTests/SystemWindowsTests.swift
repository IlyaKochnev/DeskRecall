import Foundation
import DeskRecallCore

@MainActor extension CoreTests {
    private func identity(_ id: UInt32, pid: Int32 = 100, launch: Double = 10, boot: String = "boot") -> SystemWindowIdentity {
        SystemWindowIdentity(windowID: id, pid: pid, launchTime: launch, bootSession: boot)
    }
    private var systemRect: Rect { Rect(x: 0, y: 30, width: 800, height: 600) }
    private var systemTopology: Topology {
        Topology(displays: [DisplaySnapshot(id: "display", name: "display", builtIn: true,
            frame: Rect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: Rect(x: 0, y: 30, width: 1440, height: 870))])
    }
    func testSystemInventorySurvivesEmptyAXListsAcrossSixDesktops() throws {
        let spaces = (1...6).map { SpaceReference(systemID: UInt64($0), displayID: "display", index: $0, active: $0 == 1) }
        let apps = ["com.google.Chrome", "com.google.Chrome", "com.google.Chrome", "com.apple.Terminal", "com.apple.iCal", "com.apple.ActivityMonitor"]
        let system = apps.enumerated().map { index, app in
            SystemWindowRecord(identity: identity(UInt32(index + 1)), appID: app, frame: systemRect,
                               onScreen: index == 0, spaces: [spaces[index]])
        }
        let captured = WindowSnapshotAssembler.assemble(system: system, accessibility: [], topology: systemTopology)
        expectEqual(captured.count, 6)
        expectEqual(Set(captured.compactMap { $0.systemIdentity?.windowID }), Set(1...6).map { UInt32($0) }.reduce(into: Set<UInt32>()) { $0.insert($1) })
        expectTrue(captured.allSatisfy { $0.captureSource == .system })
        var profile = Profile(topology: systemTopology, windows: captured)
        profile.captureScope = .systemAndAccessibility; profile.spaces = spaces
        let loaded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        expectTrue(loaded.isValid); expectEqual(loaded.spaces?.count, 6)
        expectEqual(loaded.windows.map(\.spaces), captured.map(\.spaces))
    }
    func testWindowIDsDoNotCrossProcessesLaunchesOrBoots() {
        let base = identity(123)
        expectNotEqual(base.runtimeToken, identity(123, pid: 101).runtimeToken)
        expectNotEqual(base.runtimeToken, identity(123, launch: 11).runtimeToken)
        expectNotEqual(base.runtimeToken, identity(123, boot: "other").runtimeToken)
        var a = WindowSnapshot(appID: "app", displayID: "display", frame: systemRect)
        a.systemIdentity = base
        var b = a; b.runtimeToken = UUID(); b.subrole = "AXStandardWindow"
        expectEqual(WindowMatcher.match(saved: [a], current: [b]).count, 1)
        b.systemIdentity = identity(123, boot: "other"); b.runtimeToken = UUID(); b.subrole = ""
        expectEqual(WindowMatcher.match(saved: [a], current: [b]).count, 0)
    }
    func testAmbiguousGeometryNeverAttachesAXToWrongSystemWindow() {
        let a = SystemWindowRecord(identity: identity(1), appID: "app", frame: systemRect, onScreen: false, spaces: [])
        let b = SystemWindowRecord(identity: identity(2), appID: "app", frame: systemRect, onScreen: false, spaces: [])
        let ax = WindowSnapshot(appID: "app", titleHash: "title", displayID: "display", frame: systemRect)
        let merged = WindowSnapshotAssembler.assemble(system: [a,b], accessibility: [ax], topology: systemTopology)
        expectEqual(merged.count, 2)
        expectEqual(merged.filter { $0.captureSource == .system }.count, 2)
        expectTrue(merged.filter { $0.systemIdentity != nil }.allSatisfy { $0.titleHash == nil })
        var exact = ax; exact.systemIdentity = b.identity
        let matched = WindowSnapshotAssembler.assemble(system: [a,b], accessibility: [exact], topology: systemTopology)
        expectEqual(matched.count, 2)
        expectEqual(matched.first { $0.systemIdentity == b.identity }?.titleHash, "title")
    }
}
