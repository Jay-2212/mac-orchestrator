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
    }
}
