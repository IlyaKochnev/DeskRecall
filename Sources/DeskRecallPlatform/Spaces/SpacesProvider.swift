public struct SpacesCapabilities: Sendable {
    public var canEnumerate = false
    public var canReadMembership = false
    public var canMoveWindows = false
    public var canCreate = false
    public var canReorder = false
    public var canMoveBetweenDisplays = false
    public init() {}
}

public protocol SpacesProvider: Sendable {
    var capabilities: SpacesCapabilities { get }
    var explanation: String { get }
}

public struct UnsupportedSpacesProvider: SpacesProvider {
    public let capabilities = SpacesCapabilities()
    public let explanation = "Виртуальные столы не сохраняются и не восстанавливаются в этой версии."
    public init() {}
}
