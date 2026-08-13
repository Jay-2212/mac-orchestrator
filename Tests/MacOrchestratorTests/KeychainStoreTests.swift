import Foundation
import Security
import XCTest
@testable import MacOrchestrator

final class KeychainStoreTests: XCTestCase {
    func testConnectorTokenReadsExistingIdentityWithoutCreatingOrRotating() throws {
        let fake = FakeKeychainClient(values: [
            KeychainItem.connectorToken.key: "connector-stable-value"
        ])
        let store = KeychainStore(client: fake)

        XCTAssertEqual(try store.connectorTokenValue(), "connector-stable-value")
        XCTAssertEqual(fake.createCalls, [])
        XCTAssertEqual(fake.updateCalls, [])
    }

    func testNamedSecretCreatesThenUpdatesThroughInjectedClient() throws {
        let fake = FakeKeychainClient()
        let store = KeychainStore(client: fake)

        try store.set("telegram-one", for: .telegramSendBotToken)
        try store.set("telegram-two", for: .telegramSendBotToken)

        XCTAssertEqual(try store.value(for: .telegramSendBotToken), "telegram-two")
        XCTAssertEqual(fake.createCalls, [KeychainItem.telegramSendBotToken.key])
        XCTAssertEqual(fake.updateCalls, [KeychainItem.telegramSendBotToken.key])
    }

    func testMeridianIngestUsesExistingPythonServiceAndUserAccount() {
        let item = KeychainItem.meridianIngestToken(account: "jay")

        XCTAssertEqual(item.service, "com.jay.mac-orchestrator.ingest-token")
        XCTAssertEqual(item.account, "jay")
    }

    func testSeparateNamedItemsExistForTelegramAndFutureMeridianCredentials() {
        XCTAssertNotEqual(KeychainItem.telegramSendBotToken.key, KeychainItem.telegramSendChatID.key)
        XCTAssertNotEqual(
            KeychainItem.meridianTelegramBotToken.key,
            KeychainItem.meridianTelegramWebhookSecret.key
        )
    }

    func testGenerateConnectorTokenUsesExactly32InjectedRandomBytesWithoutPersisting() throws {
        let fake = FakeKeychainClient()
        let store = KeychainStore(client: fake, random: FixedRandomBytes(byte: 0xab))

        let token = try store.generateConnectorToken()

        XCTAssertEqual(token, String(repeating: "ab", count: 32))
        XCTAssertNil(try store.value(for: .connectorToken))
        XCTAssertEqual(fake.createCalls, [])
    }

    func testConnectorReplacementUsesCompareAndReplaceOnCanonicalItem() throws {
        let oldToken = "old-token"
        let newToken = String(repeating: "cd", count: 32)
        let fake = FakeKeychainClient(values: [KeychainItem.connectorToken.key: oldToken])
        let store = KeychainStore(client: fake)

        try store.replaceConnectorToken(expectedCurrent: oldToken, with: newToken)

        XCTAssertEqual(try store.value(for: .connectorToken), newToken)
        XCTAssertEqual(fake.createCalls, [])
        XCTAssertEqual(fake.updateCalls, [KeychainItem.connectorToken.key])
    }

    func testConnectorReplacementRejectsConcurrentCanonicalValueWithoutChangingIt() throws {
        let fake = FakeKeychainClient(values: [KeychainItem.connectorToken.key: "actual-token"])
        let store = KeychainStore(client: fake)
        let newToken = String(repeating: "ef", count: 32)

        XCTAssertThrowsError(
            try store.replaceConnectorToken(expectedCurrent: "stale-token", with: newToken)
        ) { error in
            XCTAssertEqual(error as? KeychainStoreError, .concurrentModification)
            XCTAssertFalse(String(describing: error).contains("stale-token"))
            XCTAssertFalse(String(describing: error).contains(newToken))
        }
        XCTAssertEqual(try store.value(for: .connectorToken), "actual-token")
        XCTAssertEqual(fake.updateCalls, [])
    }

    func testNgrokReplacementCommitsOnlyExplicitCandidateValue() throws {
        let fake = FakeKeychainClient(values: [KeychainItem.ngrokAuthtoken.key: "old-authtoken"])
        let store = KeychainStore(client: fake)

        try store.replaceNgrokAuthtoken(
            expectedCurrent: "old-authtoken",
            with: "candidate-authtoken"
        )

        XCTAssertEqual(try store.value(for: .ngrokAuthtoken), "candidate-authtoken")
        XCTAssertEqual(fake.updateCalls, [KeychainItem.ngrokAuthtoken.key])
    }

    private final class FakeKeychainClient: KeychainClient {
        private(set) var values: [String: String]
        private(set) var createCalls: [String] = []
        private(set) var updateCalls: [String] = []

        init(values: [String: String] = [:]) {
            self.values = values
        }

        func read(service: String, account: String) throws -> String? {
            values[KeychainItem.key(service: service, account: account)]
        }

        func create(value: String, service: String, account: String) throws {
            let key = KeychainItem.key(service: service, account: account)
            guard values[key] == nil else {
                throw KeychainStoreError.operationFailed(Int(errSecDuplicateItem))
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

        func delete(service: String, account: String) throws {
            values.removeValue(forKey: KeychainItem.key(service: service, account: account))
        }
    }

    private struct FixedRandomBytes: SecureRandomByteGenerating {
        let byte: UInt8

        func randomBytes(count: Int) throws -> [UInt8] {
            Array(repeating: byte, count: count)
        }
    }
}
