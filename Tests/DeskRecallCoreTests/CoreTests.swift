import Foundation
import DeskRecallCore
import DeskRecallPlatform

@MainActor final class CoreTests {
    private func display(_ id: String, x: Double = 0, width: Double = 1440) -> DisplaySnapshot {
        DisplaySnapshot(id: id, name: id, builtIn: id == "mac", frame: Rect(x: x, y: 0, width: width, height: 900),
                        visibleFrame: Rect(x: x, y: 25, width: width, height: 850))
    }
    private func window(_ title: String? = "title", token: UUID = UUID(), app: String = "test.app") -> WindowSnapshot {
        WindowSnapshot(runtimeToken: token, appID: app, titleHash: title, displayID: "mac",
                       frame: Rect(x: 10, y: 40, width: 600, height: 400))
    }
    func testTopologyIgnoresEnumerationOrderAndGeometryForProfileKey() {
        let a = Topology(displays: [display("mac"), display("external", x: -1440)])
        let b = Topology(displays: [display("external", x: 1440), display("mac")])
        expectEqual(a.key, b.key)
        expectFalse(a.sameLayout(as: b))
        expectNotEqual(a.key, Topology(displays: [display("mac")]).key)
        expectFalse(Topology(displays: [display("mac"), display("mac")]).isSupported)
        expectFalse(Topology(displays: [display("mac")], mirrored: true).isSupported)
        expectFalse(Topology(displays: [display("mac")], identificationComplete: false).isSupported)
    }
    func testDuplicateTitlesNeverPickAnArbitraryWindow() {
        expectTrue(WindowMatcher.match(saved: [window(), window()], current: [window(), window()]).isEmpty)
        expectTrue(WindowMatcher.match(saved: [window(), window()], current: [window()]).isEmpty)
        expectTrue(WindowMatcher.match(saved: [window()], current: [window(), window()]).isEmpty)
    }
    func testRuntimeIdentityResolvesDuplicatesAndNoWindowIsReused() {
        let a = window(); let b = window()
        let matches = WindowMatcher.match(saved: [a, b], current: [b, a])
        expectEqual(matches.map(\.currentIndex), [1, 0])
    }
    func testMatchingDoesNotCrossApplicationsOrInventEvidence() {
        expectTrue(WindowMatcher.match(saved: [window("same")], current: [window("same", app: "other.app")]).isEmpty)
        expectTrue(WindowMatcher.match(saved: [window(nil)], current: [window(nil)]).isEmpty)
    }
    func testStrongIdentityPrecedesConflictingTitle() {
        var a = window("old"); a.documentHash = "document"
        var current = window("new"); current.documentHash = "document"
        let distraction = window("old")
        expectEqual(WindowMatcher.match(saved: [a], current: [distraction, current]).first?.currentIndex, 1)
    }
    func testCoordinatesSupportDisplaysAboveAndLeftOfPrimary() {
        let above = Geometry.fromAppKit(Rect(x: -1000, y: 900, width: 1000, height: 700), primaryTop: 900)
        expectEqual(above, Rect(x: -1000, y: -700, width: 1000, height: 700))
        let below = Geometry.fromAppKit(Rect(x: 0, y: -700, width: 1000, height: 700), primaryTop: 900)
        expectEqual(below.y, 900)
    }
    func testGeometryNormalizesAndKeepsWindowsInsideChangedArea() {
        let original = Rect(x: 0, y: 0, width: 1000, height: 1000)
        let new = Rect(x: -500, y: 20, width: 500, height: 500)
        let result = Geometry.target(window: Rect(x: 500, y: 500, width: 500, height: 500), oldArea: original, newArea: new)
        expectEqual(result, Rect(x: -250, y: 270, width: 250, height: 250))
        let huge = Geometry.target(window: Rect(x: -100, y: -100, width: 4000, height: 4000), oldArea: original, newArea: new)
        expectEqual(huge, new)
    }
    func testInvalidGeometryAndUnknownDisplayRejectProfile() {
        var w = window(); w.frame.width = .nan
        expectFalse(Profile(topology: Topology(displays: [display("mac")]), windows: [w]).isValid)
        w = window(); w.displayID = "missing"
        expectFalse(Profile(topology: Topology(displays: [display("mac")]), windows: [w]).isValid)
    }
    func testGenerationRejectsStalePlans() {
        var epoch = RestoreEpoch()
        let old = epoch.advance(); expectTrue(epoch.accepts(old))
        let new = epoch.advance(); expectFalse(epoch.accepts(old)); expectTrue(epoch.accepts(new))
    }
    func testStoreSeparatesTopologiesAndKeepsPreviousBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let a = Profile(topology: Topology(displays: [display("mac")]), windows: [window()])
        let b = Profile(topology: Topology(displays: [display("mac"), display("external")]), windows: [window()])
        try await store.save(a); try await store.save(b)
        let loaded = try await store.load(key: a.topology.key)
        expectEqual(loaded, a)
        var replacement = a; replacement.windows[0].frame.x = 200
        try await store.save(replacement)
        let file = await store.url(for: a.topology.key)
        let backup = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: file.appendingPathExtension("backup")))
        expectEqual(backup, a)
        let bLoaded = try await store.load(key: b.topology.key)
        expectEqual(bLoaded, b)
    }
    func testStorePreservesCorruptAndFutureProfiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProfileStore(directory: directory)
        let profile = Profile(topology: Topology(displays: [display("mac")]), windows: [window()])
        try await store.save(profile)
        let url = await store.url(for: profile.topology.key)
        for bytes in [Data("broken".utf8), Data("{\"schemaVersion\":99}".utf8)] {
            try bytes.write(to: url, options: .atomic)
            do { try await store.save(profile); recordFailure("Must not overwrite invalid profile") } catch { }
            expectEqual(try Data(contentsOf: url), bytes)
        }
    }
}

@MainActor extension CoreTests {
    func testAllWindowStatesRoundTripIncludingIdenticalGeometry() throws {
        let topology = Topology(displays: [display("mac")])
        let states = [
            WindowState(onScreen: false),
            WindowState(minimized: true, onScreen: false),
            WindowState(fullscreen: true, canMove: false, canResize: false, onScreen: false),
            WindowState(canMove: false, canResize: false),
            WindowState()
        ]
        var coverage = WindowCoverage()
        let windows = states.map { state in
            var w = window(); w.state = state
            coverage.discovered += 1; coverage.include(state)
            return w
        }
        let profile = Profile(topology: topology, windows: windows, coverage: coverage)
        expectTrue(profile.isValid)
        let loaded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        expectEqual(loaded.windows.count, 5)
        expectEqual(loaded.windows.map(\.state), states.map { Optional($0) })
        expectEqual(loaded.coverage?.offScreen, 3)
        expectEqual(loaded.coverage?.minimized, 1)
        expectEqual(loaded.coverage?.fullscreen, 1)
        expectEqual(loaded.coverage?.readOnly, 2)
        expectEqual(WindowMatcher.match(saved: loaded.windows, current: windows).count, 5)
    }
    func testLegacyVisibleOnlyProfileLoadsAndUpgradesWithoutInventingScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ProfileStore(directory: directory)
        let profile = Profile(topology: Topology(displays: [display("mac")]), windows: [window()])
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        raw["schemaVersion"] = 1; raw.removeValue(forKey: "captureScope"); raw.removeValue(forKey: "coverage")
        let file = await store.url(for: profile.topology.key)
        let original = try JSONSerialization.data(withJSONObject: raw)
        try original.write(to: file)
        let old = try await store.load(key: profile.topology.key)
        expectEqual(old?.schemaVersion, 1); expectTrue(old?.captureScope == nil)
        expectEqual(try Data(contentsOf: file), original)
        var all = profile; all.coverage = WindowCoverage()
        try await store.save(all)
        let updated = try await store.load(key: profile.topology.key)
        expectEqual(updated?.schemaVersion, Profile.currentSchema)
        expectEqual(updated?.captureScope, .allAccessibleWindows)
        expectEqual(try Data(contentsOf: file.appendingPathExtension("backup")), original)
    }
    func testOffDisplayWindowGetsNearestDisplayInsteadOfBeingDropped() {
        let displays = [display("mac"), display("left", x: -1440)]
        let offscreen = Rect(x: -4000, y: 40, width: 500, height: 300)
        expectEqual(Geometry.display(for: offscreen, in: displays)?.id, "left")
        expectEqual(Geometry.display(for: Rect(x: 200, y: 40, width: 500, height: 300), in: displays)?.id, "mac")
    }
}
