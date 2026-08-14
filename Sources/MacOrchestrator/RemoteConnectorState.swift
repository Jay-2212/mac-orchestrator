import Foundation

enum RemoteResultClassification: String, Codable, Equatable, Sendable {
    case unknown
    case ready
    case notReady
    case degraded
}

enum RemoteConnectorRecoveryPhase: String, Codable, Equatable, Sendable {
    case stable
    case cutoverPendingValidation
    case degraded
}

enum RemotePublicOriginError: Error, Equatable, LocalizedError, Sendable {
    case invalid

    var errorDescription: String? {
        "The remote public origin is invalid."
    }
}

struct RemotePublicOrigin: Codable, Equatable, Hashable, Sendable {
    let value: String

    init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }),
              trimmed.count <= 512 else {
            throw RemotePublicOriginError.invalid
        }

        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              host.contains("."),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.port == nil || components.port == 443,
              components.url != nil else {
            throw RemotePublicOriginError.invalid
        }

        var canonical = components
        canonical.scheme = "https"
        canonical.host = host.lowercased()
        canonical.path = ""
        canonical.percentEncodedPath = ""
        self.value = canonical.url?.absoluteString ?? trimmed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

enum RemoteConnectorStateValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case invalidGeneration
    case invalidRecoveryPhase
    case invalidReadyState

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported remote connector state schema " + String(version) + "."
        case .invalidGeneration:
            return "The remote connector state generation is invalid."
        case .invalidRecoveryPhase:
            return "The remote connector state recovery phase is invalid."
        case .invalidReadyState:
            return "The remote connector state is not ready for remote use."
        }
    }
}

struct RemoteConnectorStateV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let knownCodingKeyNames: Set<String> = [
        "schemaVersion",
        "provider",
        "connectorCredentialGeneration",
        "pendingConnectorCredentialGeneration",
        "recoveryPhase",
        "lastVerifiedPublicOrigin",
        "lastSuccessfulRemoteProbeAt",
        "lastRemoteResult",
        "lastConnectorHandoffGeneration",
    ]

    var schemaVersion: Int
    var provider: RemoteConnectorProvider
    var connectorCredentialGeneration: UInt64
    var pendingConnectorCredentialGeneration: UInt64?
    var recoveryPhase: RemoteConnectorRecoveryPhase
    var lastVerifiedPublicOrigin: RemotePublicOrigin?
    var lastSuccessfulRemoteProbeAt: Date?
    var lastRemoteResult: RemoteResultClassification
    var lastConnectorHandoffGeneration: UInt64

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        provider: RemoteConnectorProvider,
        connectorCredentialGeneration: UInt64 = 0,
        pendingConnectorCredentialGeneration: UInt64? = nil,
        recoveryPhase: RemoteConnectorRecoveryPhase = .stable,
        lastVerifiedPublicOrigin: RemotePublicOrigin? = nil,
        lastSuccessfulRemoteProbeAt: Date? = nil,
        lastRemoteResult: RemoteResultClassification = .unknown,
        lastConnectorHandoffGeneration: UInt64 = 0
    ) throws {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.connectorCredentialGeneration = connectorCredentialGeneration
        self.pendingConnectorCredentialGeneration = pendingConnectorCredentialGeneration
        self.recoveryPhase = recoveryPhase
        self.lastVerifiedPublicOrigin = lastVerifiedPublicOrigin
        self.lastSuccessfulRemoteProbeAt = lastSuccessfulRemoteProbeAt
        self.lastRemoteResult = lastRemoteResult
        self.lastConnectorHandoffGeneration = lastConnectorHandoffGeneration
        _ = try validated()
    }

    static func fresh(provider: RemoteConnectorProvider) -> Self {
        // The fixed provider enum and literal defaults cannot fail validation.
        try! Self(provider: provider)
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RemoteConnectorStateValidationError.unsupportedSchema(schemaVersion)
        }
        guard lastConnectorHandoffGeneration <= connectorCredentialGeneration else {
            throw RemoteConnectorStateValidationError.invalidGeneration
        }

        switch (recoveryPhase, pendingConnectorCredentialGeneration) {
        case (.cutoverPendingValidation, let pending?):
            guard pending > connectorCredentialGeneration else {
                throw RemoteConnectorStateValidationError.invalidRecoveryPhase
            }
        case (.cutoverPendingValidation, nil):
            throw RemoteConnectorStateValidationError.invalidRecoveryPhase
        case (.stable, nil), (.degraded, nil):
            break
        default:
            throw RemoteConnectorStateValidationError.invalidRecoveryPhase
        }

        if recoveryPhase == .stable, lastRemoteResult == .ready {
            guard lastVerifiedPublicOrigin != nil,
                  lastSuccessfulRemoteProbeAt != nil,
                  lastConnectorHandoffGeneration == connectorCredentialGeneration else {
                throw RemoteConnectorStateValidationError.invalidReadyState
            }
        }
        return self
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case provider
        case connectorCredentialGeneration
        case pendingConnectorCredentialGeneration
        case recoveryPhase
        case lastVerifiedPublicOrigin
        case lastSuccessfulRemoteProbeAt
        case lastRemoteResult
        case lastConnectorHandoffGeneration
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        guard Set(rawContainer.allKeys.map(\.stringValue)).isSubset(of: Self.knownCodingKeyNames) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Unknown remote connector state field."
            ))
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RemoteConnectorStateValidationError.unsupportedSchema(schemaVersion)
        }
        try self.init(
            schemaVersion: schemaVersion,
            provider: container.decode(RemoteConnectorProvider.self, forKey: .provider),
            connectorCredentialGeneration: container.decode(UInt64.self, forKey: .connectorCredentialGeneration),
            pendingConnectorCredentialGeneration: container.decodeIfPresent(
                UInt64.self,
                forKey: .pendingConnectorCredentialGeneration
            ),
            recoveryPhase: container.decode(RemoteConnectorRecoveryPhase.self, forKey: .recoveryPhase),
            lastVerifiedPublicOrigin: container.decodeIfPresent(
                RemotePublicOrigin.self,
                forKey: .lastVerifiedPublicOrigin
            ),
            lastSuccessfulRemoteProbeAt: container.decodeIfPresent(
                Date.self,
                forKey: .lastSuccessfulRemoteProbeAt
            ),
            lastRemoteResult: container.decode(RemoteResultClassification.self, forKey: .lastRemoteResult),
            lastConnectorHandoffGeneration: container.decode(UInt64.self, forKey: .lastConnectorHandoffGeneration)
        )
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
