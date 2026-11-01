import Foundation

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0
    }
    public func intersectionArea(_ other: Rect) -> Double {
        max(0, min(x + width, other.x + other.width) - max(x, other.x)) *
        max(0, min(y + height, other.y + other.height) - max(y, other.y))
    }
    public func isClose(to other: Rect, tolerance: Double = 4) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance &&
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

public struct DisplaySnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var builtIn: Bool
    public var frame: Rect
    public var visibleFrame: Rect
    public var scale: Double
    public var rotation: Double
    public var isMain: Bool
    public init(id: String, name: String, builtIn: Bool, frame: Rect, visibleFrame: Rect,
                scale: Double = 1, rotation: Double = 0, isMain: Bool = false) {
        self.id = id; self.name = name; self.builtIn = builtIn
        self.frame = frame; self.visibleFrame = visibleFrame
        self.scale = scale; self.rotation = rotation; self.isMain = isMain
    }
}

public struct Topology: Codable, Equatable, Sendable {
    public var displays: [DisplaySnapshot]
    public var mirrored: Bool
    public var identificationComplete: Bool
    public init(displays: [DisplaySnapshot], mirrored: Bool = false, identificationComplete: Bool = true) {
        self.displays = displays.sorted { $0.id < $1.id }; self.mirrored = mirrored
        self.identificationComplete = identificationComplete
    }
    // JSON avoids ambiguous concatenation of display identifiers.
    public var key: String {
        let members = displays.map { "\($0.builtIn ? "builtin" : "external"):\($0.id)" }.sorted()
        let encoded = (try? JSONEncoder().encode(members)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "v1:\(mirrored ? "mirror" : "extended"):\(encoded)"
    }
    public var isSupported: Bool {
        identificationComplete && !mirrored && !displays.isEmpty && Set(displays.map(\.id)).count == displays.count &&
        displays.allSatisfy { !$0.id.isEmpty && $0.frame.isValid && $0.visibleFrame.isValid && $0.scale.isFinite && $0.scale > 0 }
    }
    public func sameLayout(as other: Topology) -> Bool {
        // Names may change on reconnect; only physical layout matters for stabilization.
        identificationComplete == other.identificationComplete && key == other.key && displays.count == other.displays.count && zip(displays, other.displays).allSatisfy {
            $0.id == $1.id && $0.frame == $1.frame && $0.visibleFrame == $1.visibleFrame &&
            $0.scale == $1.scale && $0.rotation == $1.rotation && $0.isMain == $1.isMain
        }
    }
}

public struct WindowState: Codable, Equatable, Sendable {
    public var minimized: Bool
    public var fullscreen: Bool
    public var canMove: Bool
    public var canResize: Bool
    public var onScreen: Bool
    public init(minimized: Bool = false, fullscreen: Bool = false, canMove: Bool = true,
                canResize: Bool = true, onScreen: Bool = true) {
        self.minimized = minimized; self.fullscreen = fullscreen; self.canMove = canMove
        self.canResize = canResize; self.onScreen = onScreen
    }
}

public struct WindowCoverage: Codable, Equatable, Sendable {
    public var applications = 0
    public var discovered = 0
    public var captured = 0
    public var onScreen = 0
    public var offScreen = 0
    public var minimized = 0
    public var fullscreen = 0
    public var readOnly = 0
    public var unreadable = 0
    public var systemWindowCount = 0
    public var systemOnly: Int?
    public var spacesRead: Bool?
    public var desktopCount: Int?
    public init() {}
    public mutating func include(_ state: WindowState) {
        captured += 1
        if state.onScreen { onScreen += 1 } else { offScreen += 1 }
        if state.minimized { minimized += 1 }
        if state.fullscreen { fullscreen += 1 }
        if !state.canMove && !state.canResize { readOnly += 1 }
    }
}

public enum CaptureScope: String, Codable, Sendable { case allAccessibleWindows, systemAndAccessibility }

public struct WindowSnapshot: Codable, Equatable, Sendable {
    public var runtimeToken: UUID
    public var appID: String
    public var role: String
    public var subrole: String
    public var identifierHash: String?
    public var documentHash: String?
    public var titleHash: String?
    public var displayID: String
    public var frame: Rect
    public var state: WindowState?
    public var systemIdentity: SystemWindowIdentity?
    public var spaces: [SpaceReference]?
    public var captureSource: WindowCaptureSource?
    public var serverLayer: Int?
    public var opacity: Double?
    public init(runtimeToken: UUID = UUID(), appID: String, role: String = "AXWindow",
                subrole: String = "AXStandardWindow", identifierHash: String? = nil,
                documentHash: String? = nil, titleHash: String? = nil, displayID: String, frame: Rect, state: WindowState? = nil) {
        self.runtimeToken = runtimeToken; self.appID = appID; self.role = role; self.subrole = subrole
        self.identifierHash = identifierHash; self.documentHash = documentHash; self.titleHash = titleHash
        self.displayID = displayID; self.frame = frame; self.state = state
    }
}

public struct Profile: Codable, Equatable, Sendable {
    public static let currentSchema = 3
    public var schemaVersion: Int
    public var id: UUID
    public var savedAt: Date
    public var topology: Topology
    public var windows: [WindowSnapshot]
    public var captureScope: CaptureScope?
    public var coverage: WindowCoverage?
    public var spaces: [SpaceReference]?
    public init(topology: Topology, windows: [WindowSnapshot], coverage: WindowCoverage? = nil) {
        schemaVersion = Self.currentSchema; id = UUID(); savedAt = Date()
        self.topology = topology; self.windows = windows
        self.captureScope = .allAccessibleWindows; self.coverage = coverage
    }
    public var isValid: Bool {
        (1...Self.currentSchema).contains(schemaVersion) && topology.isSupported && !windows.isEmpty &&
        Set(windows.map(\.runtimeToken)).count == windows.count && windows.allSatisfy {
            !$0.appID.isEmpty && $0.frame.isValid
        } && windows.allSatisfy { w in topology.displays.contains { $0.id == w.displayID } }
    }
}

public struct ScanIssue: Sendable {
    public var appID: String
    public var reason: String
    public init(appID: String, reason: String) { self.appID = appID; self.reason = reason }
}

public struct WindowScan: Sendable {
    public var windows: [WindowSnapshot]
    public var issues: [ScanIssue]
    public var excluded: Int
    public var coverage: WindowCoverage
    public var spaces: [SpaceReference] = []
    public init(windows: [WindowSnapshot], issues: [ScanIssue] = [], excluded: Int = 0, coverage: WindowCoverage = WindowCoverage()) {
        self.windows = windows; self.issues = issues; self.excluded = excluded; self.coverage = coverage
    }
}
