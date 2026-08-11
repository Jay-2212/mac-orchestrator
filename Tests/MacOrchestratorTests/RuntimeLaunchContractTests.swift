import Foundation
import XCTest
@testable import MacOrchestrator

final class RuntimeLaunchContractTests: XCTestCase {
    func testConfiguredPortDrivesEveryManagedServerEndpoint() throws {
        var configuration = AppConfiguration.fresh(ownerID: "owner-runtime")
        configuration.localMCPPort = 49_321
        let capabilitySnapshot = CapabilityRegistry(
            configuration: configuration,
            facts: CapabilityReadinessFacts(coreSessionReady: true)
        ).snapshot()
        let keychain = KeychainStore(
            client: RuntimeKeychainClient(values: [
                KeychainItem.connectorToken.key: String(repeating: "c", count: 48),
            ]),
            meridianAccount: "runtime-test"
        )

        let contract = try ManagedRuntimeLaunchContract.make(
            configuration: configuration,
            capabilitySnapshot: capabilitySnapshot,
            keychain: keychain,
            inheritedEnvironment: ["PATH": "/usr/bin"]
        )

        XCTAssertEqual(contract.port, 49_321)
        XCTAssertEqual(contract.environment["MAC_ORCHESTRATOR_PORT"], "49321")
        XCTAssertEqual(
            contract.healthURL,
            URL(string: "http://127.0.0.1:49321/__mac_orchestrator_health")
        )
        XCTAssertEqual(contract.tunnelTarget, "http://127.0.0.1:49321")
        XCTAssertTrue(contract.matchesTunnelAddress("http://127.0.0.1:49321"))
        XCTAssertTrue(contract.matchesTunnelAddress("http://localhost:49321"))
        XCTAssertFalse(contract.matchesTunnelAddress("http://127.0.0.1:8000"))
    }

    func testManagedEnvironmentScrubsInheritedSecretsAndInjectsOnlyReadyCapabilitySecrets() throws {
        var configuration = AppConfiguration.fresh(ownerID: "owner-runtime")
        configuration.desiredCapabilities["telegram.send"] = true
        configuration.desiredCapabilities["meridian.search"] = false
        configuration.integration.meridianDeploymentURL = "https://meridian.invalid"
        let capabilitySnapshot = CapabilityRegistry(
            configuration: configuration,
            facts: CapabilityReadinessFacts(
                coreSessionReady: true,
                telegramCredentialsPresent: true,
                telegramReady: true,
                meridianCredentialsPresent: true,
                meridianSearchReady: false
            )
        ).snapshot()
        let connectorToken = String(repeating: "c", count: 48)
        let keychain = KeychainStore(
            client: RuntimeKeychainClient(values: [
                KeychainItem.connectorToken.key: connectorToken,
                KeychainItem.telegramSendBotToken.key: "keychain-telegram-bot",
                KeychainItem.telegramSendChatID.key: "keychain-telegram-chat",
                KeychainItem.meridianIngestToken(account: "runtime-test").key: "keychain-meridian-token",
            ]),
            meridianAccount: "runtime-test"
        )
        let inheritedSecrets = [
            "TELEGRAM_BOT_TOKEN": "legacy-bot",
            "TELEGRAM_CHAT_ID": "legacy-chat",
            "INGEST_TOKEN": "legacy-ingest",
            "WORKER_URL": "https://legacy-worker.invalid",
            "MAC_ORCHESTRATOR_TELEGRAM_BOT_TOKEN": "stale-dedicated-bot",
            "MAC_ORCHESTRATOR_TELEGRAM_CHAT_ID": "stale-dedicated-chat",
            "MAC_ORCHESTRATOR_MERIDIAN_INGEST_TOKEN": "stale-dedicated-ingest",
            "MAC_ORCHESTRATOR_WORKER_URL": "https://stale-worker.invalid",
            "AWS_SECRET_ACCESS_KEY": "unrelated-aws-secret",
            "GITHUB_TOKEN": "unrelated-github-token",
            "CUSTOM_SECRET": "unrelated-custom-secret",
            "PATH": "/usr/bin",
            "HOME": "/Users/synthetic",
            "LANG": "en_US.UTF-8",
        ]

        let contract = try ManagedRuntimeLaunchContract.make(
            configuration: configuration,
            capabilitySnapshot: capabilitySnapshot,
            keychain: keychain,
            inheritedEnvironment: inheritedSecrets
        )

        XCTAssertEqual(contract.environment["PATH"], "/usr/bin")
        XCTAssertEqual(contract.environment["HOME"], "/Users/synthetic")
        XCTAssertEqual(contract.environment["LANG"], "en_US.UTF-8")
        XCTAssertNil(contract.environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(contract.environment["GITHUB_TOKEN"])
        XCTAssertNil(contract.environment["CUSTOM_SECRET"])
        XCTAssertNil(contract.environment["TELEGRAM_BOT_TOKEN"])
        XCTAssertNil(contract.environment["TELEGRAM_CHAT_ID"])
        XCTAssertNil(contract.environment["INGEST_TOKEN"])
        XCTAssertNil(contract.environment["WORKER_URL"])
        XCTAssertEqual(
            contract.environment["MAC_ORCHESTRATOR_TELEGRAM_BOT_TOKEN"],
            "keychain-telegram-bot"
        )
        XCTAssertEqual(
            contract.environment["MAC_ORCHESTRATOR_TELEGRAM_CHAT_ID"],
            "keychain-telegram-chat"
        )
        XCTAssertNil(contract.environment["MAC_ORCHESTRATOR_MERIDIAN_INGEST_TOKEN"])
        XCTAssertNil(contract.environment["MAC_ORCHESTRATOR_WORKER_URL"])
        XCTAssertEqual(Set(contract.redactedSecrets), Set([
            connectorToken,
            "keychain-telegram-bot",
            "keychain-telegram-chat",
        ]))

        let encodedSnapshot = try XCTUnwrap(
            contract.environment["MAC_ORCHESTRATOR_CAPABILITY_SNAPSHOT"]
        )
        try XCTAssertEqual(
            try CapabilitySnapshotCodec.decode(Data(encodedSnapshot.utf8)),
            capabilitySnapshot
        )
        XCTAssertFalse(encodedSnapshot.contains("keychain-telegram-bot"))
        XCTAssertFalse(encodedSnapshot.contains("keychain-telegram-chat"))
        XCTAssertFalse(encodedSnapshot.contains("keychain-meridian-token"))
    }

    func testReadyCapabilityWithoutItsRequiredKeychainSecretFailsClosed() throws {
        var configuration = AppConfiguration.fresh(ownerID: "owner-runtime")
        configuration.desiredCapabilities["telegram.send"] = true
        let capabilitySnapshot = CapabilityRegistry(
            configuration: configuration,
            facts: CapabilityReadinessFacts(
                coreSessionReady: true,
                telegramCredentialsPresent: true,
                telegramReady: true
            )
        ).snapshot()
        let keychain = KeychainStore(
            client: RuntimeKeychainClient(values: [
                KeychainItem.connectorToken.key: String(repeating: "c", count: 48),
                KeychainItem.telegramSendBotToken.key: "keychain-telegram-bot",
            ]),
            meridianAccount: "runtime-test"
        )

        do {
            _ = try ManagedRuntimeLaunchContract.make(
                configuration: configuration,
                capabilitySnapshot: capabilitySnapshot,
                keychain: keychain,
                inheritedEnvironment: [:]
            )
            XCTFail("A ready Telegram capability must not launch without its chat ID.")
        } catch let error as ManagedRuntimeLaunchContractError {
            guard case let .missingRequiredSecret(name) = error else {
                XCTFail("Unexpected launch-contract error: \(error)")
                return
            }
            XCTAssertEqual(name, "MAC_ORCHESTRATOR_TELEGRAM_CHAT_ID")
        }
    }
}

private final class RuntimeKeychainClient: KeychainClient {
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
