import Foundation

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

    init(
        store: ConfigurationStore,
        userDefaults: UserDefaults,
        keychain: KeychainStore,
        legacyConfigurationURL: URL,
        runtimeDirectory: URL,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        readinessEvaluator: @escaping ReadinessEvaluator
    ) {
        self.store = store
        self.userDefaults = userDefaults
        self.keychain = keychain
        self.legacyConfigurationURL = legacyConfigurationURL
        self.runtimeDirectory = runtimeDirectory
        self.inheritedEnvironment = inheritedEnvironment
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
        return try await makeLaunchContract(configuration: store.load())
    }

    func reload() async throws -> ManagedRuntimeLaunchContract {
        try await makeLaunchContract(configuration: store.load())
    }

    func updateConfiguration(
        _ update: (inout AppConfiguration) throws -> Void
    ) async throws -> ManagedRuntimeLaunchContract {
        let configuration = try store.update(update)
        return try await makeLaunchContract(configuration: configuration)
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
}
