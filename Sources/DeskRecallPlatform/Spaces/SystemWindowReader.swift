import AppKit
import CoreGraphics
import Darwin
import DeskRecallCore

public struct SystemInventory: Sendable {
    public var windows: [SystemWindowRecord]
    public var spaces: [SpaceReference]
    public var spaceReadAvailable: Bool
}

/// Read-only SkyLight calls are isolated here. No Space or window mutation APIs are loaded.
public enum SystemWindowReader {
    public static func capture(apps: [RunningApp]) throws -> SystemInventory {
        let mapper = SpaceReader()
        let appMap = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0) })
        guard let graph = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { throw WindowServiceError.unavailable }
        var windows: [SystemWindowRecord] = []
        let boot = bootSession()
        for item in graph {
            guard let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue, (0..<20).contains(layer),
                  let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, let app = appMap[pid],
                  let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            let frame = Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
            guard frame.isValid else { continue }
            let onScreen = (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let spaces = mapper.spaces(for: id)
            // Hidden staging/renderer windows with no desktop are not user windows on a Space.
            if mapper.available && spaces.isEmpty && !onScreen { continue }
            windows.append(SystemWindowRecord(identity: SystemWindowIdentity(windowID: id, pid: pid,
                launchTime: app.launchTime, bootSession: boot), appID: app.bundleID, frame: frame,
                onScreen: onScreen, spaces: spaces, layer: layer,
                opacity: (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1))
        }
        return SystemInventory(windows: windows, spaces: mapper.managed, spaceReadAvailable: mapper.available)
    }
    private static func bootSession() -> String {
        var length = 0
        if sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0) == 0, length > 1 {
            var buffer = [CChar](repeating: 0, count: length)
            if sysctlbyname("kern.bootsessionuuid", &buffer, &length, nil, 0) == 0 {
                return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        // No identifier reuse across app launches when the system's boot UUID cannot be obtained.
        return fallbackBoot
    }
    private static let fallbackBoot = UUID().uuidString
}

private final class SpaceReader {
    typealias Copy = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private var library: UnsafeMutableRawPointer?
    private var connection: UInt32 = 0
    private var copy: Copy?
    private(set) var managed: [SpaceReference] = []
    private(set) var available = false
    init() {
        let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        self.library = library
        guard let library, let c = dlsym(library, "CGSMainConnectionID"),
              let list = dlsym(library, "CGSCopyManagedDisplaySpaces"),
              let windows = dlsym(library, "SLSCopySpacesForWindows") else { return }
        connection = unsafeBitCast(c, to: (@convention(c) () -> UInt32).self)()
        copy = unsafeBitCast(windows, to: Copy.self)
        let read = unsafeBitCast(list, to: (@convention(c) (UInt32) -> Unmanaged<CFArray>?).self)
        guard let displays = read(connection)?.takeRetainedValue() as? [[String: Any]], !displays.isEmpty else { return }
        for display in displays {
            let displayID = display["Display Identifier"] as? String ?? ""
            let active = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
            for (index, space) in (display["Spaces"] as? [[String: Any]] ?? []).enumerated() {
                guard let id = space["ManagedSpaceID"] as? NSNumber else { continue }
                managed.append(SpaceReference(systemID: id.uint64Value, displayID: displayID, index: index + 1,
                    type: (space["type"] as? NSNumber)?.intValue ?? 0, active: id == active))
            }
        }
        available = !managed.isEmpty
    }
    deinit { if let library { dlclose(library) } }
    func spaces(for id: UInt32) -> [SpaceReference] {
        guard let copy, let values = copy(connection, 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        let ids = Set(values.map(\.uint64Value))
        return managed.filter { ids.contains($0.systemID) }
    }
}
