import Foundation

enum OnboardingCompletionError: Error, Equatable, LocalizedError, Sendable {
    case requiredCapabilityPending(String)

    var errorDescription: String? {
        switch self {
        case let .requiredCapabilityPending(capability):
            return "Required onboarding capability is still pending: \(capability)."
        }
    }
}

@MainActor
final class NativeRuntimeCoordinator {
    typealias ReadinessEvaluator = @MainActor (
        _ configuration: AppConfiguration,
        _ keychain: KeychainStore,
        _ runtimeDirectory: URL
    ) async -> CapabilityReadinessFacts

    private let store: ConfigurationStore
    private let userDefaults: UserDefaults
    private let keychain: KeychainStore
    private let legacyConfigurationURL: URL
    let runtimeDirectory: URL
    private let inheritedEnvironment: [String: String]
    private let readinessEvaluator: ReadinessEvaluator
    private let portIsOccupied: (Int) -> Bool

    init(
        store: ConfigurationStore,
        userDefaults: UserDefaults,
        keychain: KeychainStore,
        legacyConfigurationURL: URL,
        runtimeDirectory: URL,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        portIsOccupied: @escaping (Int) -> Bool = LocalPortAllocator.isOccupied,
        readinessEvaluator: @escaping ReadinessEvaluator
    ) {
        self.store = store
        self.userDefaults = userDefaults
        self.keychain = keychain
        self.legacyConfigurationURL = legacyConfigurationURL
        self.runtimeDirectory = runtimeDirectory
        self.inheritedEnvironment = inheritedEnvironment
        self.portIsOccupied = portIsOccupied
        self.readinessEvaluator = readinessEvaluator
    }

    func prepare() async throws -> ManagedRuntimeLaunchContract {
        _ = try store.loadOrCreate()
        _ = try UserDefaultsMigrator.migrate(userDefaults: userDefaults, store: store)
        _ = try LegacySecretMigrator(
            legacyURL: legacyConfigurationURL,
            keychain: keychain,
            store: store
        ).migrate()
        var configuration = try store.load()
        let state = OnboardingStateClassifier.classify(configuration)
        if state == .fresh {
            configuration = try store.update { configuration in
                configuration.onboarding.phase2State = .interrupted
            }
        }
        configuration = try allocatePortIfNeeded(configuration, state: state)
        return try await makeLaunchContract(configuration: configuration)
    }

    func reload() async throws -> ManagedRuntimeLaunchContract {
        let configuration = try store.load()
        let state = OnboardingStateClassifier.classify(configuration)
        return try await makeLaunchContract(
            configuration: allocatePortIfNeeded(configuration, state: state)
        )
    }

    func updateConfiguration(
        _ update: (inout AppConfiguration) throws -> Void
    ) async throws -> ManagedRuntimeLaunchContract {
        let configuration = try store.update(update)
        return try await makeLaunchContract(configuration: configuration)
    }

    @discardableResult
    func markPhase2Completed() async throws -> AppConfiguration {
        let configuration = try store.load()
        let facts = await readinessEvaluator(configuration, keychain, runtimeDirectory)
        let snapshot = CapabilityRegistry(
            configuration: configuration,
            facts: facts
        ).snapshot()

        guard snapshot.capabilities["core.session"]?.ready == true else {
            throw OnboardingCompletionError.requiredCapabilityPending("core session")
        }
        for capabilityID in ["mac.ui", "mac.screenOcr"] {
            guard configuration.desiredCapabilities[capabilityID] == true else { continue }
            guard snapshot.capabilities[capabilityID]?.ready == true else {
                throw OnboardingCompletionError.requiredCapabilityPending(capabilityID)
            }
        }

        return try store.update { configuration in
            configuration.onboarding.completed = true
            configuration.onboarding.phase2State = .completed
        }
    }

    static func defaultLegacyConfigurationURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("mac-orchestrator", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    private func makeLaunchContract(
        configuration: AppConfiguration
    ) async throws -> ManagedRuntimeLaunchContract {
        let facts = await readinessEvaluator(configuration, keychain, runtimeDirectory)
        let capabilitySnapshot = CapabilityRegistry(
            configuration: configuration,
            facts: facts
        ).snapshot()
        return try ManagedRuntimeLaunchContract.make(
            configuration: configuration,
            capabilitySnapshot: capabilitySnapshot,
            keychain: keychain,
            inheritedEnvironment: inheritedEnvironment
        )
    }

    private func allocatePortIfNeeded(
        _ configuration: AppConfiguration,
        state: Phase2OnboardingState
    ) throws -> AppConfiguration {
        guard state == .fresh || state == .interrupted else {
            return configuration
        }
        let selectedPort = try LocalPortAllocator.select(
            preferred: configuration.localMCPPort,
            isOccupied: portIsOccupied
        )
        guard selectedPort != configuration.localMCPPort else {
            return configuration
        }
        return try store.update { configuration in
            configuration.localMCPPort = selectedPort
        }
    }
}
