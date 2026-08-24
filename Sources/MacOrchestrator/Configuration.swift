import Foundation

enum ControlProfile: String, Codable, Sendable {
    case guided
    case full
}

struct ProcessConfiguration: Codable, Equatable, Sendable {
    var serverDesired: Bool
    var tunnelDesired: Bool

    init(serverDesired: Bool = true, tunnelDesired: Bool = false) {
        self.serverDesired = serverDesired
        self.tunnelDesired = tunnelDesired
    }

    private enum CodingKeys: String, CodingKey {
        case serverDesired
        case tunnelDesired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            serverDesired: try container.decodeIfPresent(Bool.self, forKey: .serverDesired) ?? true,
            tunnelDesired: try container.decodeIfPresent(Bool.self, forKey: .tunnelDesired) ?? false
        )
    }
}

struct ConfigurationPolicy: Codable, Equatable, Sendable {
    var clipboardMutation: Bool

    init(clipboardMutation: Bool = false) {
        self.clipboardMutation = clipboardMutation
    }

    private enum CodingKeys: String, CodingKey {
        case clipboardMutation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            clipboardMutation: try container.decodeIfPresent(Bool.self, forKey: .clipboardMutation) ?? false
        )
    }
}

struct SchedulingPlaceholder: Codable, Equatable, Sendable {
    var enabled: Bool
    var scheduleIdentifier: String?
    var lastRunAt: Date?
    var nextRunAt: Date?

    init(
        enabled: Bool = false,
        scheduleIdentifier: String? = nil,
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil
    ) {
        self.enabled = enabled
        self.scheduleIdentifier = scheduleIdentifier
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case scheduleIdentifier
        case lastRunAt
        case nextRunAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            scheduleIdentifier: try container.decodeIfPresent(String.self, forKey: .scheduleIdentifier),
            lastRunAt: try container.decodeIfPresent(Date.self, forKey: .lastRunAt),
            nextRunAt: try container.decodeIfPresent(Date.self, forKey: .nextRunAt)
        )
    }
}

struct IntegrationConfiguration: Codable, Equatable, Sendable {
    var meridianDeploymentURL: String?
    var meridianAlias: String?
    var aliases: [String: String]
    var meridianIndexer: MeridianIndexerConfiguration

    init(
        meridianDeploymentURL: String? = nil,
        meridianAlias: String? = nil,
        aliases: [String: String] = [:],
        meridianIndexer: MeridianIndexerConfiguration = MeridianIndexerConfiguration()
    ) {
        self.meridianDeploymentURL = meridianDeploymentURL
        self.meridianAlias = meridianAlias
        self.aliases = aliases
        self.meridianIndexer = meridianIndexer
    }

    private enum CodingKeys: String, CodingKey {
        case meridianDeploymentURL
        case meridianAlias
        case aliases
        case meridianIndexer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            meridianDeploymentURL: try container.decodeIfPresent(String.self, forKey: .meridianDeploymentURL),
            meridianAlias: try container.decodeIfPresent(String.self, forKey: .meridianAlias),
            aliases: try container.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:],
            meridianIndexer: try container.decodeIfPresent(
                MeridianIndexerConfiguration.self,
                forKey: .meridianIndexer
            ) ?? MeridianIndexerConfiguration()
        )
    }
}

struct OnboardingConfiguration: Codable, Equatable, Sendable {
    var completed: Bool
    var phase2State: Phase2OnboardingState?
    var migrationMarkers: [String]
    var legacyPlaintextCleanupPending: Bool
    var legacyPlaintextKeys: [String]

    init(
        completed: Bool = false,
        phase2State: Phase2OnboardingState? = nil,
        migrationMarkers: [String] = [],
        legacyPlaintextCleanupPending: Bool = false,
        legacyPlaintextKeys: [String] = []
    ) {
        self.completed = completed
        self.phase2State = phase2State
        self.migrationMarkers = migrationMarkers
        self.legacyPlaintextCleanupPending = legacyPlaintextCleanupPending
        self.legacyPlaintextKeys = legacyPlaintextKeys
    }

    private enum CodingKeys: String, CodingKey {
        case completed
        case phase2State
        case migrationMarkers
        case legacyPlaintextCleanupPending
        case legacyPlaintextKeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            completed: try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false,
            phase2State: try container.decodeIfPresent(Phase2OnboardingState.self, forKey: .phase2State),
            migrationMarkers: try container.decodeIfPresent([String].self, forKey: .migrationMarkers) ?? [],
            legacyPlaintextCleanupPending: try container.decodeIfPresent(
                Bool.self,
                forKey: .legacyPlaintextCleanupPending
            ) ?? false,
            legacyPlaintextKeys: try container.decodeIfPresent([String].self, forKey: .legacyPlaintextKeys) ?? []
        )
    }
}

enum ConfigurationValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidGeneration(Int)
    case invalidPort(Int)
    case blankOwnerID
    case invalidMeridianURL
    case meridianIndexerRequiresDeploymentURL
    case invalidApprovedFileRoot(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "Unsupported configuration schema version " + String(version) + "."
        case let .invalidGeneration(generation):
            return "Configuration generation " + String(generation) + " is invalid."
        case let .invalidPort(port):
            return "Configuration port " + String(port) + " is invalid."
        case .blankOwnerID:
            return "Configuration owner identity is missing."
        case .invalidMeridianURL:
            return "Meridian deployment URL must use http:// or https://."
        case .meridianIndexerRequiresDeploymentURL:
            return "Meridian indexer configuration requires a Meridian deployment URL."
        case let .invalidApprovedFileRoot(root):
            return "Approved file root must be a nonblank normalized absolute path: " + root
        }
    }
}

enum ApprovedFileRootNormalizer {
    static func normalize(_ roots: [String]) throws -> [String] {
        var normalizedRoots = Set<String>()
        for root in roots {
            let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("~"),
                  trimmed.hasPrefix("/"),
                  !trimmed.contains("\0") else {
                throw ConfigurationValidationError.invalidApprovedFileRoot(root)
            }

            let normalized = (trimmed as NSString).standardizingPath
            guard normalized.hasPrefix("/"), !normalized.hasPrefix("~") else {
                throw ConfigurationValidationError.invalidApprovedFileRoot(root)
            }
            normalizedRoots.insert(normalized)
        }
        return normalizedRoots.sorted()
    }
}

struct AppConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generation: Int
    var controlProfile: ControlProfile
    var localMCPPort: Int
    var process: ProcessConfiguration
    var desiredCapabilities: [String: Bool]
    var approvedFileRoots: [String]
    var excludePatterns: [String]
    var scheduling: SchedulingPlaceholder
    var integration: IntegrationConfiguration
    var onboarding: OnboardingConfiguration
    var ownerID: String
    var policy: ConfigurationPolicy

    init(
        schemaVersion: Int = AppConfiguration.currentSchemaVersion,
        generation: Int = 1,
        controlProfile: ControlProfile = .guided,
        localMCPPort: Int = 8000,
        process: ProcessConfiguration = ProcessConfiguration(),
        desiredCapabilities: [String: Bool] = AppConfiguration.defaultDesiredCapabilities,
        approvedFileRoots: [String] = [],
        excludePatterns: [String] = [],
        scheduling: SchedulingPlaceholder = SchedulingPlaceholder(),
        integration: IntegrationConfiguration = IntegrationConfiguration(),
        onboarding: OnboardingConfiguration = OnboardingConfiguration(),
        ownerID: String,
        policy: ConfigurationPolicy = ConfigurationPolicy()
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.controlProfile = controlProfile
        self.localMCPPort = localMCPPort
        self.process = process
        self.desiredCapabilities = desiredCapabilities
        self.approvedFileRoots = approvedFileRoots
        self.excludePatterns = excludePatterns
        self.scheduling = scheduling
        self.integration = integration
        self.onboarding = onboarding
        self.ownerID = ownerID
        self.policy = policy
    }

    static func fresh(ownerID: String) -> AppConfiguration {
        AppConfiguration(ownerID: ownerID)
    }

    private static let defaultDesiredCapabilities: [String: Bool] = [
        "core.session": true,
        "mac.ui": true,
        "mac.screenOcr": false,
        "mac.files.read": false,
        "mac.files.write": false,
        "mac.shell": false,
        "mac.clipboard.write": false,
        "telegram.send": false,
        "meridian.search": false,
        "meridian.telegram": false,
        "remote.connector": false,
    ]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generation
        case controlProfile
        case localMCPPort
        case process
        case desiredCapabilities
        case approvedFileRoots
        case excludePatterns
        case scheduling
        case integration
        case onboarding
        case ownerID
        case policy
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generation, forKey: .generation)
        try container.encode(controlProfile, forKey: .controlProfile)
        try container.encode(localMCPPort, forKey: .localMCPPort)
        try container.encode(process, forKey: .process)
        var capabilities = container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .desiredCapabilities)
        for key in desiredCapabilities.keys.sorted() {
            guard let codingKey = DynamicCodingKey(stringValue: key),
                  let value = desiredCapabilities[key] else { continue }
            try capabilities.encode(value, forKey: codingKey)
        }
        try container.encode(approvedFileRoots, forKey: .approvedFileRoots)
        try container.encode(excludePatterns, forKey: .excludePatterns)
        try container.encode(scheduling, forKey: .scheduling)
        try container.encode(integration, forKey: .integration)
        try container.encode(onboarding, forKey: .onboarding)
        try container.encode(ownerID, forKey: .ownerID)
        try container.encode(policy, forKey: .policy)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0,
            generation: try container.decodeIfPresent(Int.self, forKey: .generation) ?? 1,
            controlProfile: try container.decodeIfPresent(ControlProfile.self, forKey: .controlProfile) ?? .guided,
            localMCPPort: try container.decodeIfPresent(Int.self, forKey: .localMCPPort) ?? 8000,
            process: try container.decodeIfPresent(ProcessConfiguration.self, forKey: .process)
                ?? ProcessConfiguration(),
            desiredCapabilities: try container.decodeIfPresent(
                [String: Bool].self,
                forKey: .desiredCapabilities
            ) ?? AppConfiguration.defaultDesiredCapabilities,
            approvedFileRoots: try container.decodeIfPresent([String].self, forKey: .approvedFileRoots) ?? [],
            excludePatterns: try container.decodeIfPresent([String].self, forKey: .excludePatterns) ?? [],
            scheduling: try container.decodeIfPresent(SchedulingPlaceholder.self, forKey: .scheduling)
                ?? SchedulingPlaceholder(),
            integration: try container.decodeIfPresent(IntegrationConfiguration.self, forKey: .integration)
                ?? IntegrationConfiguration(),
            onboarding: try container.decodeIfPresent(OnboardingConfiguration.self, forKey: .onboarding)
                ?? OnboardingConfiguration(),
            ownerID: try container.decodeIfPresent(String.self, forKey: .ownerID) ?? "",
            policy: try container.decodeIfPresent(ConfigurationPolicy.self, forKey: .policy)
                ?? ConfigurationPolicy()
        )
    }

    func validated() throws -> AppConfiguration {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ConfigurationValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard generation >= 1 else {
            throw ConfigurationValidationError.invalidGeneration(generation)
        }
        guard (1...65535).contains(localMCPPort) else {
            throw ConfigurationValidationError.invalidPort(localMCPPort)
        }
        guard !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationValidationError.blankOwnerID
        }
        if let meridianURL = integration.meridianDeploymentURL,
           let url = URL(string: meridianURL),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            // The URL is a nonsecret alias/settings value. No further network
            // or provider validation belongs in the configuration layer.
        } else if integration.meridianDeploymentURL != nil {
            throw ConfigurationValidationError.invalidMeridianURL
        }
        _ = try integration.meridianIndexer.validated()
        if integration.meridianIndexer.enabled && integration.meridianDeploymentURL == nil {
            throw ConfigurationValidationError.meridianIndexerRequiresDeploymentURL
        }
        if integration.meridianIndexer.enabled,
           let deploymentURL = integration.meridianDeploymentURL,
           URL(string: deploymentURL)?.scheme?.lowercased() != "https" {
            throw ConfigurationValidationError.invalidMeridianURL
        }
        var normalized = self
        normalized.approvedFileRoots = try ApprovedFileRootNormalizer.normalize(approvedFileRoots)
        return normalized
    }
}
