import Foundation
import CryptoKit
import DeskRecallCore

public enum ProfileStoreError: Error, LocalizedError {
    case unsupportedSchema(Int)
    case invalidProfile
    case topologyMismatch
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "Версия профиля \(version) не поддерживается. Файл оставлен без изменений."
        case .invalidProfile: return "Профиль повреждён или содержит недопустимые данные. Файл оставлен без изменений."
        case .topologyMismatch: return "Профиль относится к другой конфигурации экранов."
        }
    }
}

public actor ProfileStore {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskRecall/Profiles", isDirectory: true)
    }
    public func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    public func load(key: String) throws -> Profile? {
        let file = url(for: key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        struct Header: Decodable { var schemaVersion: Int }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data) }
        catch { throw ProfileStoreError.invalidProfile }
        guard (1...Profile.currentSchema).contains(header.schemaVersion) else { throw ProfileStoreError.unsupportedSchema(header.schemaVersion) }
        let profile: Profile
        do { profile = try JSONDecoder().decode(Profile.self, from: data) }
        catch { throw ProfileStoreError.invalidProfile }
        guard profile.isValid else { throw ProfileStoreError.invalidProfile }
        guard profile.topology.key == key else { throw ProfileStoreError.topologyMismatch }
        return profile
    }
    public func save(_ profile: Profile) throws {
        try Task.checkCancellation()
        guard profile.isValid else { throw ProfileStoreError.invalidProfile }
        // Validate the existing file before replacing it, including its schema version.
        let previous = try load(key: profile.topology.key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = url(for: profile.topology.key)
        if previous != nil {
            let old = try Data(contentsOf: file)
            let backup = file.appendingPathExtension("backup")
            try old.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var upgraded = profile
        upgraded.schemaVersion = Profile.currentSchema
        let data = try encoder.encode(upgraded)
        try Task.checkCancellation()
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
