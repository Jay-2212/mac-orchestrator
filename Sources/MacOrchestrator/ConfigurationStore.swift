import Foundation

enum ConfigurationStoreError: Error, Equatable, LocalizedError, Sendable {
    case notFound
    case malformed
    case invalid(ConfigurationValidationError)
    case unsupportedSchema(Int)
    case backupUnavailable
    case recoveryFailed
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Mac Orchestrator configuration was not found."
        case .malformed:
            return "Mac Orchestrator configuration is malformed."
        case let .invalid(error):
            return error.localizedDescription
        case let .unsupportedSchema(version):
            return "Unsupported Mac Orchestrator configuration schema " + String(version) + "."
        case .backupUnavailable:
            return "Mac Orchestrator could not prepare a configuration backup."
        case .recoveryFailed:
            return "Mac Orchestrator could not recover its configuration safely."
        case .readFailed:
            return "Mac Orchestrator could not read its configuration."
        case .writeFailed:
            return "Mac Orchestrator could not write its configuration safely."
        }
    }
}

final class ConfigurationStore {
    private static let backupSuffix = ".backup"
    private static let corruptSuffix = ".corrupt"
    private static let schemaMigrationMarker = "schema-v1"
    private static let applicationSupportFolderName = "Mac Orchestrator"

    private let directoryURL: URL
    private let fileManager: FileManager
    private let ownerIDProvider: () -> String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent(Self.applicationSupportFolderName, isDirectory: true)
    }

    convenience init(
        fileManager: FileManager = .default,
        ownerIDProvider: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.init(
            directoryURL: Self.defaultDirectoryURL(fileManager: fileManager),
            fileManager: fileManager,
            ownerIDProvider: ownerIDProvider
        )
    }

    var configurationURL: URL {
        directoryURL.appendingPathComponent("config.json", isDirectory: false)
    }

    var backupURL: URL {
        directoryURL.appendingPathComponent("config.json" + Self.backupSuffix, isDirectory: false)
    }

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        ownerIDProvider: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.ownerIDProvider = ownerIDProvider
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> AppConfiguration {
        guard fileManager.fileExists(atPath: configurationURL.path) else {
            return try recoverWhenPrimaryIsMissing()
        }

        let primaryData: Data
        do {
            primaryData = try Data(contentsOf: configurationURL)
        } catch {
            return try recoverFromPrimaryFailure(original: .readFailed)
        }

        do {
            let decoded = try decode(primaryData)
            if decoded.requiresMigration {
                return try save(decoded.configuration)
            }
            return decoded.configuration
        } catch let error as ConfigurationStoreError {
            if case .unsupportedSchema = error {
                throw error
            }
            return try recoverFromPrimaryFailure(primaryData: primaryData, original: error)
        } catch {
            return try recoverFromPrimaryFailure(primaryData: primaryData, original: .malformed)
        }
    }

    func loadOrCreate() throws -> AppConfiguration {
        if fileManager.fileExists(atPath: configurationURL.path) ||
            fileManager.fileExists(atPath: backupURL.path) {
            return try load()
        }
        return try save(AppConfiguration.fresh(ownerID: ownerIDProvider()))
    }

    @discardableResult
    func save(_ configuration: AppConfiguration) throws -> AppConfiguration {
        var candidate: AppConfiguration
        do {
            candidate = try configuration.validated()
        } catch let error as ConfigurationValidationError {
            throw ConfigurationStoreError.invalid(error)
        }

        let primaryExists = fileManager.fileExists(atPath: configurationURL.path)
        if primaryExists {
            let existingData: Data
            do {
                existingData = try Data(contentsOf: configurationURL)
            } catch {
                throw ConfigurationStoreError.readFailed
            }
            let existing = try decode(existingData).configuration
            if candidate.generation <= existing.generation {
                candidate.generation = existing.generation + 1
            }
        }

        let data: Data
        do {
            data = try encoder.encode(candidate)
        } catch {
            throw ConfigurationStoreError.writeFailed
        }

        do {
            try ensureDirectory()
            let primaryTemp = try writeTemporary(data, label: "config")
            defer { try? fileManager.removeItem(at: primaryTemp) }

            if primaryExists {
                let existingData = try Data(contentsOf: configurationURL)
                let backupTemp = try writeTemporary(existingData, label: "backup")
                defer { try? fileManager.removeItem(at: backupTemp) }
                try replaceOrMove(backupTemp, at: backupURL)
            }
            try replaceOrMove(primaryTemp, at: configurationURL)
            return candidate
        } catch let error as ConfigurationStoreError {
            throw error
        } catch {
            if primaryExists {
                throw ConfigurationStoreError.backupUnavailable
            }
            throw ConfigurationStoreError.writeFailed
        }
    }

    @discardableResult
    func update(_ body: (inout AppConfiguration) throws -> Void) throws -> AppConfiguration {
        let current = try loadOrCreate()
        var updated = current
        try body(&updated)
        guard updated != current else {
            return current
        }
        updated.generation = max(updated.generation, current.generation + 1)
        return try save(updated)
    }

    private struct DecodedConfiguration {
        let configuration: AppConfiguration
        let requiresMigration: Bool
    }

    private func decode(_ data: Data) throws -> DecodedConfiguration {
        let decoded: AppConfiguration
        do {
            decoded = try decoder.decode(AppConfiguration.self, from: data)
        } catch {
            throw ConfigurationStoreError.malformed
        }

        if decoded.schemaVersion > AppConfiguration.currentSchemaVersion {
            throw ConfigurationStoreError.unsupportedSchema(decoded.schemaVersion)
        }

        if decoded.schemaVersion == 0 {
            var migrated = decoded
            migrated.schemaVersion = AppConfiguration.currentSchemaVersion
            migrated.generation = max(1, migrated.generation)
            if !migrated.onboarding.migrationMarkers.contains(Self.schemaMigrationMarker) {
                migrated.onboarding.migrationMarkers.append(Self.schemaMigrationMarker)
                migrated.onboarding.migrationMarkers.sort()
            }
            do {
                return DecodedConfiguration(
                    configuration: try migrated.validated(),
                    requiresMigration: true
                )
            } catch let error as ConfigurationValidationError {
                throw ConfigurationStoreError.invalid(error)
            }
        }

        do {
            return DecodedConfiguration(configuration: try decoded.validated(), requiresMigration: false)
        } catch let error as ConfigurationValidationError {
            if case let .unsupportedSchemaVersion(version) = error {
                throw ConfigurationStoreError.unsupportedSchema(version)
            }
            throw ConfigurationStoreError.invalid(error)
        }
    }

    private func recoverWhenPrimaryIsMissing() throws -> AppConfiguration {
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw ConfigurationStoreError.notFound
        }
        return try recoverFromBackup()
    }

    private func recoverFromPrimaryFailure(
        primaryData: Data? = nil,
        original: ConfigurationStoreError
    ) throws -> AppConfiguration {
        if primaryData != nil {
            do {
                try preserveCorruptPrimary()
            } catch {
                throw ConfigurationStoreError.recoveryFailed
            }
        }

        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw original
        }
        do {
            return try recoverFromBackup()
        } catch let error as ConfigurationStoreError {
            if case .unsupportedSchema = error {
                throw error
            }
            throw ConfigurationStoreError.recoveryFailed
        } catch {
            throw ConfigurationStoreError.recoveryFailed
        }
    }

    private func recoverFromBackup() throws -> AppConfiguration {
        let backupData: Data
        do {
            backupData = try Data(contentsOf: backupURL)
        } catch {
            throw ConfigurationStoreError.recoveryFailed
        }
        let decoded = try decode(backupData)
        let recoveredData: Data
        if decoded.requiresMigration {
            do {
                recoveredData = try encoder.encode(decoded.configuration)
            } catch {
                throw ConfigurationStoreError.recoveryFailed
            }
        } else {
            recoveredData = backupData
        }
        do {
            try writePrimaryWithoutBackup(recoveredData)
        } catch {
            throw ConfigurationStoreError.recoveryFailed
        }
        return decoded.configuration
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func writeTemporary(_ data: Data, label: String) throws -> URL {
        let temporaryURL = directoryURL.appendingPathComponent(
            "config.json." + label + "." + UUID().uuidString + ".tmp",
            isDirectory: false
        )
        try data.write(to: temporaryURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        return temporaryURL
    }

    private func replaceOrMove(_ source: URL, at destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func writePrimaryWithoutBackup(_ data: Data) throws {
        try ensureDirectory()
        let temporaryURL = try writeTemporary(data, label: "recovery")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try replaceOrMove(temporaryURL, at: configurationURL)
    }

    private func preserveCorruptPrimary() throws {
        let base = configurationURL.appendingPathExtension("corrupt")
        var destination = base
        var suffix = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = URL(fileURLWithPath: base.path + "." + String(suffix))
            suffix += 1
        }
        try fileManager.copyItem(at: configurationURL, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
