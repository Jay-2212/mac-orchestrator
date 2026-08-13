import Foundation

enum MaintenanceTransactionState: String, Codable, CaseIterable, Equatable, Sendable {
    case discovered
    case manifestAuthenticated
    case candidateStaged
    case candidateValidated
    case migrationPrepared
    case currentStateBackedUp
    case servicesQuiesced
    case promoting
    case structurallyValidated
    case launchAgentInstalled
    case committed
    case postflight
    case failed
}

struct MaintenanceTransactionRecord: Codable, Equatable, Sendable {
    let id: UUID
    let targetVersion: String
    let manifestSHA256: String
    let manifestURL: URL
    let createdAt: Date
    var updatedAt: Date
    var state: MaintenanceTransactionState
    var failure: String?

    init(
        id: UUID = UUID(),
        targetVersion: String,
        manifestSHA256: String,
        manifestURL: URL,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        state: MaintenanceTransactionState = .discovered,
        failure: String? = nil
    ) throws {
        guard (try? SemanticVersion(targetVersion)) != nil else {
            throw MaintenanceTransactionError.invalidRecord
        }
        guard manifestSHA256.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil else {
            throw MaintenanceTransactionError.invalidRecord
        }
        self.id = id
        self.targetVersion = targetVersion
        self.manifestSHA256 = manifestSHA256.lowercased()
        self.manifestURL = manifestURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.failure = failure
    }
}

enum MaintenanceTransactionError: Error, Equatable, LocalizedError, Sendable {
    case invalidRecord
    case notFound(UUID)
    case invalidTransition(MaintenanceTransactionState, MaintenanceTransactionState)
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidRecord: return "The maintenance transaction record is invalid."
        case let .notFound(id): return "Maintenance transaction \(id.uuidString) was not found."
        case let .invalidTransition(from, to): return "Invalid maintenance transition: \(from.rawValue) -> \(to.rawValue)."
        case .persistenceFailed: return "The maintenance transaction could not be persisted safely."
        }
    }
}

final class MaintenanceTransactionLedger {
    let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func begin(targetVersion: String, manifestSHA256: String, manifestURL: URL) throws -> MaintenanceTransactionRecord {
        let record = try MaintenanceTransactionRecord(
            targetVersion: targetVersion,
            manifestSHA256: manifestSHA256,
            manifestURL: manifestURL
        )
        try persist(record)
        return record
    }

    func load(_ id: UUID) throws -> MaintenanceTransactionRecord? {
        let url = url(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(MaintenanceTransactionRecord.self, from: Data(contentsOf: url))
        } catch {
            throw MaintenanceTransactionError.persistenceFailed
        }
    }

    @discardableResult
    func advance(_ id: UUID, to next: MaintenanceTransactionState) throws -> MaintenanceTransactionRecord {
        guard var record = try load(id) else { throw MaintenanceTransactionError.notFound(id) }
        guard Self.allowedTransitions[record.state, default: []].contains(next) else {
            throw MaintenanceTransactionError.invalidTransition(record.state, next)
        }
        record.state = next
        record.failure = nil
        record.updatedAt = Date()
        try persist(record)
        return record
    }

    @discardableResult
    func markFailure(_ id: UUID, error: Error) throws -> MaintenanceTransactionRecord {
        guard var record = try load(id) else { throw MaintenanceTransactionError.notFound(id) }
        record.state = .failed
        record.failure = error.localizedDescription
        record.updatedAt = Date()
        try persist(record)
        return record
    }

    private static let allowedTransitions: [MaintenanceTransactionState: Set<MaintenanceTransactionState>] = [
        .discovered: [.manifestAuthenticated, .failed],
        .manifestAuthenticated: [.candidateStaged, .failed],
        .candidateStaged: [.candidateValidated, .failed],
        .candidateValidated: [.migrationPrepared, .failed],
        .migrationPrepared: [.currentStateBackedUp, .failed],
        .currentStateBackedUp: [.servicesQuiesced, .failed],
        .servicesQuiesced: [.promoting, .failed],
        .promoting: [.structurallyValidated, .failed],
        .structurallyValidated: [.launchAgentInstalled, .failed],
        .launchAgentInstalled: [.committed, .failed],
        .committed: [.postflight],
        .postflight: [],
        .failed: [],
    ]

    private func url(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("transaction-\(id.uuidString.lowercased()).json")
    }

    private func persist(_ record: MaintenanceTransactionRecord) throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            let data = try encoder.encode(record)
            let destination = url(for: record.id)
            let temporary = directoryURL.appendingPathComponent(".transaction-\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            throw MaintenanceTransactionError.persistenceFailed
        }
    }
}

enum MaintenanceFaultPoint: String, Codable, CaseIterable, Sendable {
    case beforeManifestAuthentication
    case afterManifestAuthentication
    case beforeCandidateStage
    case afterCandidateStage
    case beforeCandidateValidation
    case afterCandidateValidation
    case beforeMigrationPreparation
    case afterMigrationPreparation
    case beforeCurrentStateBackup
    case afterCurrentStateBackup
    case beforeServicesQuiesce
    case afterServicesQuiesce
    case beforePromotion
    case afterPromotion
    case beforeStructuralValidation
    case afterStructuralValidation
    case beforeLaunchAgentInstall
    case afterLaunchAgentInstall
    case beforeCommit
    case afterCommit
    case beforeRollback
    case afterRollback
    case postflight
    case uninstallBeforeRemoval
    case uninstallAfterRemoval
}

struct MaintenanceInjectedFailure: Error, Equatable, LocalizedError, Sendable {
    let point: MaintenanceFaultPoint

    var errorDescription: String? {
        "Deterministic maintenance fault injected at \(point.rawValue)."
    }
}

protocol MaintenanceFaultInjector: Sendable {
    func check(_ point: MaintenanceFaultPoint) throws
}

struct NoMaintenanceFaultInjector: MaintenanceFaultInjector {
    func check(_ point: MaintenanceFaultPoint) throws {}
}

final class DeterministicMaintenanceFaultInjector: MaintenanceFaultInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Set<MaintenanceFaultPoint>

    init(failAt points: Set<MaintenanceFaultPoint>) {
        self.remaining = points
    }

    func check(_ point: MaintenanceFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        if remaining.remove(point) != nil {
            throw MaintenanceInjectedFailure(point: point)
        }
    }
}

struct ConfigurationMigrationStep {
    let identifier: String
    let sourceSchema: Int
    let targetSchema: Int
    let apply: (Data) throws -> Data

    init(identifier: String, sourceSchema: Int, targetSchema: Int, apply: @escaping (Data) throws -> Data) {
        self.identifier = identifier
        self.sourceSchema = sourceSchema
        self.targetSchema = targetSchema
        self.apply = apply
    }
}

struct ConfigurationMigrationPlan {
    let sourceSchema: Int
    let targetSchema: Int
    let steps: [ConfigurationMigrationStep]
}

enum ConfigurationMigrationError: Error, Equatable, LocalizedError, Sendable {
    case invalidSchema
    case missingStep(Int, Int)
    case duplicateStep(String)
    case stepFailed(String)
    case candidateInvalid

    var errorDescription: String? {
        switch self {
        case .invalidSchema: return "The configuration migration schema range is invalid."
        case let .missingStep(source, target): return "No configuration migration step exists from schema \(source) to \(target)."
        case let .duplicateStep(identifier): return "The configuration migration step \(identifier) is duplicated."
        case let .stepFailed(identifier): return "Configuration migration step \(identifier) failed."
        case .candidateInvalid: return "The migrated configuration candidate is invalid."
        }
    }
}

struct ConfigurationMigrationRegistry {
    let steps: [ConfigurationMigrationStep]

    init(steps: [ConfigurationMigrationStep]) {
        self.steps = steps
    }

    func plan(sourceSchema: Int, targetSchema: Int) throws -> ConfigurationMigrationPlan {
        guard sourceSchema >= 0, targetSchema >= sourceSchema else {
            throw ConfigurationMigrationError.invalidSchema
        }
        guard steps.allSatisfy({ $0.sourceSchema >= 0 && $0.targetSchema > $0.sourceSchema }) else {
            throw ConfigurationMigrationError.invalidSchema
        }
        var identifiers = Set<String>()
        var transitions = Set<String>()
        for step in steps {
            guard !step.identifier.isEmpty else { throw ConfigurationMigrationError.invalidSchema }
            guard identifiers.insert(step.identifier).inserted else {
                throw ConfigurationMigrationError.duplicateStep(step.identifier)
            }
            let transition = "\(step.sourceSchema)->\(step.targetSchema)"
            guard transitions.insert(transition).inserted else {
                throw ConfigurationMigrationError.duplicateStep(transition)
            }
        }
        var current = sourceSchema
        var selected: [ConfigurationMigrationStep] = []
        while current < targetSchema {
            guard let step = steps
                .filter({ $0.sourceSchema == current && $0.targetSchema <= targetSchema })
                .sorted(by: { $0.targetSchema > $1.targetSchema })
                .first else {
                throw ConfigurationMigrationError.missingStep(current, targetSchema)
            }
            selected.append(step)
            current = step.targetSchema
        }
        return ConfigurationMigrationPlan(sourceSchema: sourceSchema, targetSchema: targetSchema, steps: selected)
    }
}

struct PreparedConfigurationMigration {
    let source: Data
    let candidate: Data
    let plan: ConfigurationMigrationPlan
}

enum ConfigurationMigrationEngine {
    static func prepare(
        rawConfiguration: Data,
        plan: ConfigurationMigrationPlan,
        candidateValidator: (Data) throws -> Void
    ) throws -> PreparedConfigurationMigration {
        var candidate = Data(rawConfiguration)
        for step in plan.steps {
            do {
                candidate = try step.apply(candidate)
            } catch let error as ConfigurationMigrationError {
                throw error == .stepFailed(step.identifier) ? error : .stepFailed(step.identifier)
            } catch {
                throw ConfigurationMigrationError.stepFailed(step.identifier)
            }
        }
        do {
            try candidateValidator(candidate)
        } catch {
            throw ConfigurationMigrationError.candidateInvalid
        }
        return PreparedConfigurationMigration(source: rawConfiguration, candidate: candidate, plan: plan)
    }
}
