import Foundation

enum CapabilityHealth: String, Codable, Sendable {
    case ready
    case disabled
    case degraded
    case unavailable
}

struct CapabilityReadinessFacts: Equatable, Sendable {
    var coreSessionReady: Bool
    var localUIReady: Bool
    var screenOcrReady: Bool
    var fileReadReady: Bool
    var fileWriteReady: Bool
    var shellReady: Bool
    var clipboardReady: Bool
    var telegramCredentialsPresent: Bool
    var telegramReady: Bool
    var meridianCredentialsPresent: Bool
    var meridianSearchReady: Bool
    var meridianTelegramConfigured: Bool
    var meridianTelegramReady: Bool
    var remoteConnectorConfigured: Bool
    var remoteConnectorReady: Bool

    init(
        coreSessionReady: Bool = true,
        localUIReady: Bool = false,
        screenOcrReady: Bool = false,
        fileReadReady: Bool = false,
        fileWriteReady: Bool = false,
        shellReady: Bool = false,
        clipboardReady: Bool = false,
        telegramCredentialsPresent: Bool = false,
        telegramReady: Bool = false,
        meridianCredentialsPresent: Bool = false,
        meridianSearchReady: Bool = false,
        meridianTelegramConfigured: Bool = false,
        meridianTelegramReady: Bool = false,
        remoteConnectorConfigured: Bool = false,
        remoteConnectorReady: Bool = false
    ) {
        self.coreSessionReady = coreSessionReady
        self.localUIReady = localUIReady
        self.screenOcrReady = screenOcrReady
        self.fileReadReady = fileReadReady
        self.fileWriteReady = fileWriteReady
        self.shellReady = shellReady
        self.clipboardReady = clipboardReady
        self.telegramCredentialsPresent = telegramCredentialsPresent
        self.telegramReady = telegramReady
        self.meridianCredentialsPresent = meridianCredentialsPresent
        self.meridianSearchReady = meridianSearchReady
        self.meridianTelegramConfigured = meridianTelegramConfigured
        self.meridianTelegramReady = meridianTelegramReady
        self.remoteConnectorConfigured = remoteConnectorConfigured
        self.remoteConnectorReady = remoteConnectorReady
    }
}

struct CapabilityState: Codable, Equatable, Sendable {
    let desired: Bool
    let configured: Bool
    let ready: Bool
    let health: CapabilityHealth
    let dependencies: [String]
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case desired
        case configured
        case ready
        case health
        case dependencies
        case reason
    }

    init(
        desired: Bool,
        configured: Bool,
        ready: Bool,
        health: CapabilityHealth,
        dependencies: [String],
        reason: String?
    ) {
        self.desired = desired
        self.configured = configured
        self.ready = ready
        self.health = health
        self.dependencies = dependencies
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            desired: try container.decode(Bool.self, forKey: .desired),
            configured: try container.decode(Bool.self, forKey: .configured),
            ready: try container.decode(Bool.self, forKey: .ready),
            health: try container.decode(CapabilityHealth.self, forKey: .health),
            dependencies: try container.decode([String].self, forKey: .dependencies),
            reason: try container.decodeIfPresent(String.self, forKey: .reason)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(desired, forKey: .desired)
        try container.encode(configured, forKey: .configured)
        try container.encode(ready, forKey: .ready)
        try container.encode(health, forKey: .health)
        try container.encode(dependencies, forKey: .dependencies)
        if let reason {
            try container.encode(reason, forKey: .reason)
        } else {
            try container.encodeNil(forKey: .reason)
        }
    }
}

struct CapabilityPolicySnapshot: Codable, Equatable, Sendable {
    let approvedFileRoots: [String]
    let clipboardMutation: Bool
}

enum CapabilitySnapshotError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported capability snapshot schema " + String(version) + "."
        }
    }
}

struct CapabilitySnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let snapshotSchemaVersion: Int
    let configGeneration: Int
    let controlProfile: ControlProfile
    let capabilities: [String: CapabilityState]
    let policy: CapabilityPolicySnapshot

    init(
        snapshotSchemaVersion: Int = CapabilitySnapshot.currentSchemaVersion,
        configGeneration: Int,
        controlProfile: ControlProfile,
        capabilities: [String: CapabilityState],
        policy: CapabilityPolicySnapshot
    ) {
        self.snapshotSchemaVersion = snapshotSchemaVersion
        self.configGeneration = configGeneration
        self.controlProfile = controlProfile
        self.capabilities = capabilities
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case snapshotSchemaVersion
        case configGeneration
        case controlProfile
        case capabilities
        case policy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .snapshotSchemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw CapabilitySnapshotError.unsupportedSchema(version)
        }
        self.init(
            snapshotSchemaVersion: version,
            configGeneration: try container.decode(Int.self, forKey: .configGeneration),
            controlProfile: try container.decode(ControlProfile.self, forKey: .controlProfile),
            capabilities: try container.decode([String: CapabilityState].self, forKey: .capabilities),
            policy: try container.decode(CapabilityPolicySnapshot.self, forKey: .policy)
        )
    }
}

enum CapabilitySnapshotCodec {
    static func encode(_ snapshot: CapabilitySnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> CapabilitySnapshot {
        try JSONDecoder().decode(CapabilitySnapshot.self, from: data)
    }
}

struct CapabilityRegistry {
    static let capabilityIDs = [
        "core.session",
        "mac.ui",
        "mac.screenOcr",
        "mac.files.read",
        "mac.files.write",
        "mac.shell",
        "mac.clipboard.write",
        "telegram.send",
        "meridian.search",
        "meridian.telegram",
        "remote.connector",
    ]

    private let configuration: AppConfiguration
    private let facts: CapabilityReadinessFacts

    init(configuration: AppConfiguration, facts: CapabilityReadinessFacts) {
        self.configuration = configuration
        self.facts = facts
    }

    func snapshot() -> CapabilitySnapshot {
        var resolved: [String: CapabilityState] = [:]
        for capabilityID in Self.capabilityIDs {
            let dependencies = Self.dependencies(for: capabilityID)
            let desired = configuration.desiredCapabilities[capabilityID] ?? false
            let (configured, configurationReason) = configurationState(for: capabilityID)

            let state: CapabilityState
            if !desired {
                state = CapabilityState(
                    desired: false,
                    configured: configured,
                    ready: false,
                    health: .disabled,
                    dependencies: dependencies,
                    reason: "Not enabled."
                )
            } else if !configured {
                state = CapabilityState(
                    desired: true,
                    configured: false,
                    ready: false,
                    health: .unavailable,
                    dependencies: dependencies,
                    reason: configurationReason
                )
            } else if let dependency = dependencies.first(where: {
                resolved[$0]?.ready != true
            }) {
                state = CapabilityState(
                    desired: true,
                    configured: true,
                    ready: false,
                    health: .degraded,
                    dependencies: dependencies,
                    reason: "Depends on " + dependency + " being ready."
                )
            } else if readinessFact(for: capabilityID) {
                state = CapabilityState(
                    desired: true,
                    configured: true,
                    ready: true,
                    health: .ready,
                    dependencies: dependencies,
                    reason: nil
                )
            } else {
                state = CapabilityState(
                    desired: true,
                    configured: true,
                    ready: false,
                    health: .degraded,
                    dependencies: dependencies,
                    reason: readinessReason(for: capabilityID)
                )
            }
            resolved[capabilityID] = state
        }

        return CapabilitySnapshot(
            configGeneration: configuration.generation,
            controlProfile: configuration.controlProfile,
            capabilities: resolved,
            policy: CapabilityPolicySnapshot(
                approvedFileRoots: normalizedApprovedFileRoots,
                clipboardMutation: configuration.policy.clipboardMutation
            )
        )
    }

    private static func dependencies(for capabilityID: String) -> [String] {
        switch capabilityID {
        case "core.session":
            return []
        case "mac.ui", "mac.files.read", "mac.shell", "mac.clipboard.write", "telegram.send",
             "meridian.search", "remote.connector":
            return ["core.session"]
        case "mac.screenOcr":
            return ["mac.ui"]
        case "mac.files.write":
            return ["mac.files.read"]
        case "meridian.telegram":
            return ["meridian.search"]
        default:
            return []
        }
    }

    private func configurationState(for capabilityID: String) -> (Bool, String?) {
        switch capabilityID {
        case "mac.files.read":
            if configuration.controlProfile == .full {
                return (true, nil)
            }
            guard !normalizedApprovedFileRoots.isEmpty else {
                return (false, "Approve at least one file root before enabling file access.")
            }
            return (true, nil)
        case "mac.files.write":
            guard configuration.controlProfile == .full else {
                return (false, "File writes require Full Control.")
            }
            return (true, nil)
        case "mac.shell":
            guard configuration.controlProfile == .full else {
                return (false, "Full Control must be explicitly selected.")
            }
            return (true, nil)
        case "mac.clipboard.write":
            guard configuration.policy.clipboardMutation else {
                return (false, "Clipboard mutation is not allowed by policy.")
            }
            return (true, nil)
        case "telegram.send":
            guard facts.telegramCredentialsPresent else {
                return (false, "Telegram Send credentials are not configured.")
            }
            return (true, nil)
        case "meridian.search":
            guard let url = configuration.integration.meridianDeploymentURL,
                  !url.isEmpty else {
                return (false, "Meridian deployment is not configured.")
            }
            guard facts.meridianCredentialsPresent else {
                return (false, "Meridian Search credentials are not configured.")
            }
            return (true, nil)
        case "meridian.telegram":
            guard facts.meridianTelegramConfigured else {
                return (false, "Meridian Telegram credentials are not configured.")
            }
            return (true, nil)
        case "remote.connector":
            guard facts.remoteConnectorConfigured else {
                return (false, "Remote connector compatibility is not configured.")
            }
            return (true, nil)
        default:
            return (true, nil)
        }
    }

    private var normalizedApprovedFileRoots: [String] {
        (try? ApprovedFileRootNormalizer.normalize(configuration.approvedFileRoots)) ?? []
    }

    private func readinessFact(for capabilityID: String) -> Bool {
        switch capabilityID {
        case "core.session": return facts.coreSessionReady
        case "mac.ui": return facts.localUIReady
        case "mac.screenOcr": return facts.screenOcrReady
        case "mac.files.read": return facts.fileReadReady
        case "mac.files.write": return facts.fileWriteReady
        case "mac.shell": return facts.shellReady
        case "mac.clipboard.write": return facts.clipboardReady
        case "telegram.send": return facts.telegramReady
        case "meridian.search": return facts.meridianSearchReady
        case "meridian.telegram": return facts.meridianTelegramReady
        case "remote.connector": return facts.remoteConnectorReady
        default: return false
        }
    }

    private func readinessReason(for capabilityID: String) -> String {
        switch capabilityID {
        case "core.session": return "The local session is not ready."
        case "mac.ui": return "Accessibility readiness has not been verified."
        case "mac.screenOcr": return "Screen OCR readiness has not been verified."
        case "mac.files.read": return "Approved file roots are not ready."
        case "mac.files.write": return "Approved writable file roots are not ready."
        case "mac.shell": return "Shell readiness has not been verified."
        case "mac.clipboard.write": return "Clipboard mutation readiness has not been verified."
        case "telegram.send": return "Telegram Send readiness has not been verified."
        case "meridian.search":
            return "Meridian Search compatibility and index readiness have not been verified."
        case "meridian.telegram": return "Meridian Telegram readiness has not been verified."
        case "remote.connector": return "Remote connector readiness has not been verified."
        default: return "Capability readiness has not been verified."
        }
    }
}
