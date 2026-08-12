import Foundation
import XCTest
@testable import MacOrchestrator

final class RuntimeBootstrapTests: XCTestCase {
    @MainActor
    func testPrepareRunsBothMigrationsBeforeReadinessAndBuildsOneExactSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let defaultsName = "runtime-bootstrap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set("legacy-owner", forKey: "ownerID")
        defaults.set(false, forKey: "serverDesired")

        let store = ConfigurationStore(
            directoryURL: directory.appendingPathComponent("support", isDirectory: true),
            ownerIDProvider: { "fresh-owner" }
        )
        let legacyURL = directory.appendingPathComponent("legacy-config.json")
        try Data("{\"TELEGRAM_BOT_TOKEN\":\"migrated-bot\"}".utf8).write(to: legacyURL)
        let keychainClient = BootstrapKeychainClient(values: [
            KeychainItem.connectorToken.key: String(repeating: "c", count: 48),
        ])
        let keychain = KeychainStore(client: keychainClient, meridianAccount: "runtime-test")
        let runtimeDirectory = directory.appendingPathComponent("runtime", isDirectory: true)
        var configurationSeenByReadiness: AppConfiguration?
        var tokenSeenByReadiness: String?

        let coordinator = NativeRuntimeCoordinator(
            store: store,
            userDefaults: defaults,
            keychain: keychain,
            legacyConfigurationURL: legacyURL,
            runtimeDirectory: runtimeDirectory,
            inheritedEnvironment: ["PATH": "/usr/bin"],
            readinessEvaluator: { configuration, evaluatedKeychain, _ in
                configurationSeenByReadiness = configuration
                tokenSeenByReadiness = try? evaluatedKeychain.value(for: .telegramSendBotToken)
                return CapabilityReadinessFacts(coreSessionReady: true)
            }
        )

        let contract = try await coordinator.prepare()

        XCTAssertEqual(configurationSeenByReadiness?.ownerID, "legacy-owner")
        XCTAssertEqual(configurationSeenByReadiness?.controlProfile, .full)
        XCTAssertEqual(configurationSeenByReadiness?.process.serverDesired, false)
        XCTAssertEqual(tokenSeenByReadiness, "migrated-bot")
        XCTAssertEqual(contract.configuration, configurationSeenByReadiness)
        XCTAssertEqual(
            contract.capabilitySnapshot.configGeneration,
            configurationSeenByReadiness?.generation
        )
        let encoded = try XCTUnwrap(
            contract.environment["MAC_ORCHESTRATOR_CAPABILITY_SNAPSHOT"]
        )
        XCTAssertEqual(
            try CapabilitySnapshotCodec.decode(Data(encoded.utf8)),
            contract.capabilitySnapshot
        )
    }

    @MainActor
    func testPhase2CompletionRequiresCurrentManagedUIReadiness() async throws {
        let testID = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-completion-\(testID)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let defaultsName = "runtime-completion-\(testID)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = ConfigurationStore(
            directoryURL: directory.appendingPathComponent("support", isDirectory: true),
            ownerIDProvider: { "completion-owner" }
        )
        _ = try store.loadOrCreate()
        let keychain = KeychainStore(
            client: BootstrapKeychainClient(),
            meridianAccount: "runtime-completion"
        )
        var uiReady = false
        let coordinator = NativeRuntimeCoordinator(
            store: store,
            userDefaults: defaults,
            keychain: keychain,
            legacyConfigurationURL: directory.appendingPathComponent("legacy-config.json"),
            runtimeDirectory: directory.appendingPathComponent("runtime", isDirectory: true),
            readinessEvaluator: { _, _, _ in
                CapabilityReadinessFacts(
                    coreSessionReady: true,
                    localUIReady: uiReady
                )
            }
        )

        do {
            _ = try await coordinator.markPhase2Completed()
            XCTFail("Phase 2 must remain pending while the required UI requester is unavailable.")
        } catch let error as OnboardingCompletionError {
            XCTAssertEqual(error, .requiredCapabilityPending("mac.ui"))
        }
        XCTAssertFalse(try store.load().onboarding.completed)

        uiReady = true
        _ = try await coordinator.markPhase2Completed()
        let completed = try store.load()
        XCTAssertTrue(completed.onboarding.completed)
        XCTAssertEqual(completed.onboarding.phase2State, .completed)
    }
}

private final class BootstrapKeychainClient: KeychainClient {
    private var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func read(service: String, account: String) throws -> String? {
        values[KeychainItem.key(service: service, account: account)]
    }

    func create(value: String, service: String, account: String) throws {
        values[KeychainItem.key(service: service, account: account)] = value
    }

    func update(value: String, service: String, account: String) throws {
        values[KeychainItem.key(service: service, account: account)] = value
    }
}
