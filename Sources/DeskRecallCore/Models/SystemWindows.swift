import Foundation
import CryptoKit

public struct SystemWindowIdentity: Codable, Equatable, Hashable, Sendable {
    public var windowID: UInt32
    public var pid: Int32
    public var launchTime: Double
    public var bootSession: String
    public init(windowID: UInt32, pid: Int32, launchTime: Double, bootSession: String) {
        self.windowID = windowID; self.pid = pid; self.launchTime = launchTime; self.bootSession = bootSession
    }
    public var runtimeToken: UUID {
        let bytes = Array(SHA256.hash(data: Data("\(bootSession)|\(pid)|\(launchTime)|\(windowID)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
public struct SpaceReference: Codable, Equatable, Sendable {
    public var systemID: UInt64
    public var displayID: String
    public var index: Int
    public var type: Int
    public var active: Bool
    public init(systemID: UInt64, displayID: String, index: Int, type: Int = 0, active: Bool = false) {
        self.systemID = systemID; self.displayID = displayID; self.index = index; self.type = type; self.active = active
    }
}
public struct SystemWindowRecord: Sendable {
    public var identity: SystemWindowIdentity
    public var appID: String
    public var frame: Rect
    public var onScreen: Bool
    public var layer: Int
    public var opacity: Double
    public var spaces: [SpaceReference]
    public init(identity: SystemWindowIdentity, appID: String, frame: Rect, onScreen: Bool, spaces: [SpaceReference], layer: Int = 0, opacity: Double = 1) {
        self.identity = identity; self.appID = appID; self.frame = frame; self.onScreen = onScreen; self.spaces = spaces; self.layer = layer; self.opacity = opacity
    }
}
public enum WindowCaptureSource: String, Codable, Sendable { case system, accessibility, combined }

public enum WindowSnapshotAssembler {
    /// WindowServer is authoritative for inventory and coordinates. AX only enriches it.
    public static func assemble(system: [SystemWindowRecord], accessibility: [WindowSnapshot],
                                topology: Topology) -> [WindowSnapshot] {
        var output: [WindowSnapshot] = []; var consumed = Set<Int>()
        for record in system {
            let exact = accessibility.indices.filter { accessibility[$0].systemIdentity == record.identity }
            let uniqueSystemGeometry = system.filter { $0.appID == record.appID && $0.frame.isClose(to: record.frame, tolerance: 2) }.count == 1
            let geometry = accessibility.indices.filter {
                uniqueSystemGeometry && accessibility[$0].systemIdentity == nil && accessibility[$0].appID == record.appID &&
                accessibility[$0].frame.isClose(to: record.frame, tolerance: 2)
            }
            let candidates = exact.isEmpty ? geometry : exact
            let index = candidates.count == 1 && !consumed.contains(candidates[0]) ? candidates[0] : nil
            let associatedDisplay = record.spaces.compactMap { space in topology.displays.first { $0.id == space.displayID } }.first
            guard let display = associatedDisplay ?? Geometry.display(for: record.frame, in: topology.displays) else { continue }
            var snapshot = index.map { accessibility[$0] } ?? WindowSnapshot(appID: record.appID,
                subrole: "", displayID: display.id, frame: record.frame)
            if let index { consumed.insert(index) }
            snapshot.runtimeToken = record.identity.runtimeToken
            snapshot.systemIdentity = record.identity; snapshot.spaces = record.spaces
            snapshot.serverLayer = record.layer; snapshot.opacity = record.opacity
            snapshot.captureSource = index == nil ? .system : .combined
            snapshot.frame = record.frame; snapshot.displayID = display.id
            var state = snapshot.state ?? WindowState(canMove: false, canResize: false, onScreen: record.onScreen)
            state.onScreen = record.onScreen
            state.fullscreen = state.fullscreen || record.spaces.contains { $0.type == 4 }
            snapshot.state = state
            output.append(snapshot)
        }
        // Preserve AX sheets and auxiliary windows absent from the server's normal-window list.
        for index in accessibility.indices where !consumed.contains(index) {
            let snapshot = accessibility[index]
            if let identity = snapshot.systemIdentity, system.contains(where: { $0.identity == identity }) { continue }
            if snapshot.systemIdentity == nil && snapshot.role == "AXWindow" && system.contains(where: {
                $0.appID == snapshot.appID && $0.frame.isClose(to: snapshot.frame, tolerance: 2)
            }) { continue }
            output.append(snapshot)
        }
        return output
    }
}
