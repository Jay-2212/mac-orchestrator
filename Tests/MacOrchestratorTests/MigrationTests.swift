import Foundation
import XCTest
@testable import MacOrchestrator

final class MigrationTests: XCTestCase {
    func testLegacyUserDefaultsPreserveExistingBehaviorAndUseFullProfile() throws {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: "serverDesired")
        defaults.set(true, forKey: "tunnelDesired")
        defaults.set("owner-legacy", forKey: "ownerID")
        let store = try makeStore()

        let configuration = try UserDefaultsMigrator.migrate(userDefaults: defaults, store: store)

        XCTAssertEqual(configuration.controlProfile, .full)
        XCTAssertFalse(configuration.process.serverDesired)
        XCTAssertTrue(configuration.process.tunnelDesired)
        XCTAssertEqual(configuration.ownerID, "owner-legacy")
        XCTAssertTrue(configuration.desiredCapabilities["remote.connector"] == true)
        XCTAssertTrue(configuration.onboarding.migrationMarkers.contains("legacy-control-profile-v1"))
    }

    func testRunningUserDefaultsMigrationTwiceDoesNotResetOrDuplicateMarkers() throws {
        let defaults = makeIsolatedDefaults()
        defaults.set("owner-legacy", forKey: "ownerID")
        let store = try makeStore()
        let first = try UserDefaultsMigrator.migrate(userDefaults: defaults, store: store)
        var changed = first
        changed.localMCPPort = 9123
        _ = try store.save(changed)

        let second = try UserDefaultsMigrator.migrate(userDefaults: defaults, store: store)

        XCTAssertEqual(second.localMCPPort, 9123)
        XCTAssertEqual(
            second.onboarding.migrationMarkers.filter { $0 == "user-defaults-v1" }.count,
            1
        )
        XCTAssertEqual(
            second.onboarding.migrationMarkers.filter { $0 == "legacy-control-profile-v1" }.count,
            1
        )
    }

    func testLegacySecretsMigrateToNamedKeychainItemsWithoutDeletingPlaintext() throws {
        let directory = try makeTemporaryDirectory()
        let legacyURL = directory.appendingPathComponent("legacy.json")
        let legacy = """
        {
          "TELEGRAM_BOT_TOKEN": "bot-secret",
          "TELEGRAM_CHAT_ID": "123456",
          "INGEST_TOKEN": "ingest-secret",
          "unrelatedSetting": "preserve-me"
        }
        """
        try Data(legacy.utf8).write(to: legacyURL)
        let store = try makeStore()
        let fake = FakeKeychainClient()
        let keychain = KeychainStore(client: fake, meridianAccount: "legacy-user")

        let result = try LegacySecretMigrator(
            legacyURL: legacyURL,
            keychain: keychain,
            store: store
        ).migrate()

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.migratedItems, [
            KeychainItem.telegramSendBotToken.key,
            KeychainItem.telegramSendChatID.key,
            KeychainItem.meridianIngestToken(account: "legacy-user").key,
        ])
        XCTAssertEqual(try keychain.value(for: .telegramSendBotToken), "bot-secret")
        XCTAssertEqual(try keychain.value(for: .telegramSendChatID), "123456")
        XCTAssertEqual(try keychain.meridianIngestToken(), "ingest-secret")

        let persisted = try store.load()
        XCTAssertTrue(persisted.onboarding.legacyPlaintextCleanupPending)
        XCTAssertEqual(persisted.onboarding.legacyPlaintextKeys, [
            "INGEST_TOKEN",
            "TELEGRAM_BOT_TOKEN",
            "TELEGRAM_CHAT_ID",
        ])
        XCTAssertTrue(persisted.onboarding.migrationMarkers.contains("legacy-secrets-v1"))
        let persistedJSON = String(decoding: try Data(contentsOf: store.configurationURL), as: UTF8.self)
        XCTAssertFalse(persistedJSON.contains("bot-secret"))
        XCTAssertFalse(persistedJSON.contains("ingest-secret"))

        let sourceAfterMigration = try JSONSerialization.jsonObject(
            with: Data(contentsOf: legacyURL)
        ) as? [String: String]
        XCTAssertEqual(sourceAfterMigration?["unrelatedSetting"], "preserve-me")
        XCTAssertEqual(sourceAfterMigration?["TELEGRAM_BOT_TOKEN"], "bot-secret")
    }

    func testRerunningSecretMigrationDoesNotCreateDuplicateItemsOrResetState() throws {
        let directory = try makeTemporaryDirectory()
        let legacyURL = directory.appendingPathComponent("legacy.json")
        try Data("{\"TELEGRAM_BOT_TOKEN\":\"bot-secret\"}".utf8).write(to: legacyURL)
        let store = try makeStore()
        let fake = FakeKeychainClient()
        let keychain = KeychainStore(client: fake, meridianAccount: "legacy-user")
        let migrator = LegacySecretMigrator(legacyURL: legacyURL, keychain: keychain, store: store)

        _ = try migrator.migrate()
        let createCount = fake.createCalls.count
        let firstConfiguration = try store.load()
        _ = try migrator.migrate()
        let secondConfiguration = try store.load()

        XCTAssertEqual(fake.createCalls.count, createCount)
        XCTAssertEqual(secondConfiguration, firstConfiguration)
    }

    func testKeychainWriteFailureLeavesCleanupPendingWithoutCompletionMarker() throws {
        let directory = try makeTemporaryDirectory()
        let legacyURL = directory.appendingPathComponent("legacy.json")
        try Data(
            "{\"TELEGRAM_BOT_TOKEN\":\"bot-secret\",\"TELEGRAM_CHAT_ID\":\"123456\"}".utf8
        ).write(to: legacyURL)
        let store = try makeStore()
        let fake = FakeKeychainClient(failingCreateKeys: [KeychainItem.telegramSendChatID.key])
        let keychain = KeychainStore(client: fake, meridianAccount: "legacy-user")
        let migrator = LegacySecretMigrator(legacyURL: legacyURL, keychain: keychain, store: store)

        XCTAssertThrowsError(try migrator.migrate())

        let pending = try store.load()
        XCTAssertTrue(pending.onboarding.legacyPlaintextCleanupPending)
        XCTAssertFalse(pending.onboarding.migrationMarkers.contains("legacy-secrets-v1"))

        fake.failingCreateKeys.remove(KeychainItem.telegramSendChatID.key)
        let recovered = try migrator.migrate()
        XCTAssertTrue(recovered.completed)
        XCTAssertTrue((try store.load()).onboarding.migrationMarkers.contains("legacy-secrets-v1"))
    }

    func testExistingLegacyMeridianIngestItemIsPreservedWithoutCreatingAlias() throws {
        let directory = try makeTemporaryDirectory()
        let legacyURL = directory.appendingPathComponent("legacy.json")
        try Data("{\"INGEST_TOKEN\":\"new-secret\"}".utf8).write(to: legacyURL)
        let item = KeychainItem.meridianIngestToken(account: "legacy-user")
        let fake = FakeKeychainClient(values: [item.key: "existing-secret"])
        let keychain = KeychainStore(client: fake, meridianAccount: "legacy-user")
        let store = try makeStore()

        _ = try LegacySecretMigrator(legacyURL: legacyURL, keychain: keychain, store: store).migrate()

        XCTAssertEqual(try keychain.meridianIngestToken(), "existing-secret")
        XCTAssertFalse(fake.createCalls.contains(KeychainItem.meridianIngestTokenAlias.key))
        XCTAssertFalse(fake.updateCalls.contains(item.key))
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "MacOrchestratorMigrationTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    private func makeStore() throws -> ConfigurationStore {
        ConfigurationStore(directoryURL: try makeTemporaryDirectory(), ownerIDProvider: { "owner-test" })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOrchestratorMigrationTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private final class FakeKeychainClient: KeychainClient {
        private(set) var values: [String: String]
        private(set) var createCalls: [String] = []
        private(set) var updateCalls: [String] = []
        var failingCreateKeys: Set<String>

        init(values: [String: String] = [:], failingCreateKeys: Set<String> = []) {
            self.values = values
            self.failingCreateKeys = failingCreateKeys
        }

        func read(service: String, account: String) throws -> String? {
            values[KeychainItem.key(service: service, account: account)]
        }

        func create(value: String, service: String, account: String) throws {
            let key = KeychainItem.key(service: service, account: account)
            if failingCreateKeys.contains(key) {
                throw KeychainStoreError.operationFailed(-1)
            }
            guard values[key] == nil else {
                throw KeychainStoreError.operationFailed(-2)
            }
            createCalls.append(key)
            values[key] = value
        }

        func update(value: String, service: String, account: String) throws {
            let key = KeychainItem.key(service: service, account: account)
            guard values[key] != nil else {
                throw KeychainStoreError.itemNotFound
            }
            updateCalls.append(key)
            values[key] = value
        }
    }
}
