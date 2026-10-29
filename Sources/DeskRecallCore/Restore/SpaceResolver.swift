import Foundation

public enum SpaceResolutionError: Error, LocalizedError {
    case missingDisplay
    case missingSpace(Int)
    case specialSpace
    public var errorDescription: String? {
        switch self {
        case .missingDisplay: return "Нужный монитор не подключён."
        case .missingSpace(let index): return "Рабочий стол \(index) на нужном мониторе отсутствует."
        case .specialSpace: return "Полноэкранный или составной стол нельзя заменить обычным рабочим столом."
        }
    }
}
public enum SpaceResolver {
    /// Space IDs are hints within a boot. Display + ordinal is the persistent logical address.
    public static func resolve(saved: [SpaceReference], current: [SpaceReference], topology: Topology,
                               sameBoot: Bool) throws -> [SpaceReference] {
        try saved.map { space in
            guard topology.displays.contains(where: { $0.id == space.displayID }) || space.displayID == "Main" else {
                throw SpaceResolutionError.missingDisplay
            }
            if sameBoot, let exact = current.first(where: {
                $0.systemID == space.systemID && $0.displayID == space.displayID && $0.index == space.index && $0.type == space.type
            }) { return exact }
            guard let logical = current.first(where: {
                $0.displayID == space.displayID && $0.index == space.index && $0.type == space.type
            }) else { throw SpaceResolutionError.missingSpace(space.index) }
            return logical
        }
    }
}
