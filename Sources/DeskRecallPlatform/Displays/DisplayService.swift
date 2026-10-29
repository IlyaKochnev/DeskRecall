import AppKit
import CoreGraphics
import ColorSync
import DeskRecallCore

public enum DisplayService {
    @MainActor public static func capture() -> Topology {
        let primaryTop = NSScreen.screens.first(where: { displayID($0) == CGMainDisplayID() })?.frame.maxY
            ?? NSScreen.screens.first?.frame.maxY ?? 0
        let screens = NSScreen.screens.compactMap { screen -> DisplaySnapshot? in
            let id = displayID(screen)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let key = CFUUIDCreateString(nil, uuid) as String
            return DisplaySnapshot(id: key, name: screen.localizedName, builtIn: CGDisplayIsBuiltin(id) != 0,
                frame: Geometry.fromAppKit(rect(screen.frame), primaryTop: primaryTop),
                visibleFrame: Geometry.fromAppKit(rect(screen.visibleFrame), primaryTop: primaryTop),
                scale: screen.backingScaleFactor, rotation: CGDisplayRotation(id), isMain: id == CGMainDisplayID())
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let status = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        let mirrored = status != .success || ids.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
        return Topology(displays: screens, mirrored: mirrored, identificationComplete: screens.count == NSScreen.screens.count)
    }
    @MainActor private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    private static func rect(_ rect: NSRect) -> Rect {
        Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

public struct RunningApp: Sendable {
    public var pid: pid_t
    public var bundleID: String
    public var launchTime: TimeInterval
    public init(pid: pid_t, bundleID: String, launchTime: TimeInterval) {
        self.pid = pid; self.bundleID = bundleID; self.launchTime = launchTime
    }
    @MainActor public static func capture() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited, !app.isTerminated,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.bundleURL?.pathExtension == "app",
                  let bundleID = app.bundleIdentifier,
                  !["com.apple.loginwindow", "com.apple.Spotlight", "com.apple.dock", "com.apple.systemuiserver",
                    "com.apple.controlcenter", "com.apple.notificationcenterui", "com.openai.sky.CUAService"].contains(bundleID) else { return nil }
            return RunningApp(pid: app.processIdentifier, bundleID: bundleID,
                              launchTime: app.launchDate?.timeIntervalSince1970 ?? 0)
        }
    }
}
