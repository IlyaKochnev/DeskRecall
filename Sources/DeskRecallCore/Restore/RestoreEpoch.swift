/// A generation gate prevents stale async scans and plans from mutating a newer layout.
public struct RestoreEpoch: Sendable {
    public private(set) var generation: UInt64 = 0
    public init() {}
    @discardableResult public mutating func advance() -> UInt64 { generation &+= 1; return generation }
    public func accepts(_ candidate: UInt64) -> Bool { generation == candidate }
}
