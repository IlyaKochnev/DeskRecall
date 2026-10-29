import CoreGraphics
import DeskRecallCore
import DeskRecallPrivateBridge

public enum NativeWindowBridge {
    public static var available: Bool { DRBridgeAvailable() != 0 }
    public static func move(windowID: UInt32, to spaceID: UInt64) -> Bool {
        var number = windowID
        return DRMoveWindowsToSpace(&number, 1, spaceID) == 0
    }
    public static func add(windowID: UInt32, to spaces: [UInt64]) -> Bool {
        spaces.withUnsafeBufferPointer { DRAddWindowToSpaces(windowID, $0.baseAddress, Int32($0.count)) == 0 }
    }
    public static func moveSpace(_ id: UInt64, displayID: String, index: Int) -> Bool {
        displayID.withCString { DRMoveSpaceToDisplay(id, $0, Int32(index - 1)) == 0 }
    }
    public static func createSpace() -> UInt64 { DRCreateSpace() }
    public static func destroySpace(_ id: UInt64) -> Bool { DRDestroySpace(id) == 0 }
    public static func selectSpace(_ space: SpaceReference) -> Bool {
        space.displayID.withCString { DRSelectSpace($0, space.systemID) == 0 }
    }
}
