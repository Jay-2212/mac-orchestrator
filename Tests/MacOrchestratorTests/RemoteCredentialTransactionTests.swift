import Foundation
import Security
import XCTest
@testable import MacOrchestrator

final class RemoteCredentialTransactionTests: XCTestCase {
    func testSuccessfulConnectorRotationAdvancesGenerationExactlyOnceAndScopesOldTokenToNegativeHooks() throws {
        let fixture = try ConnectorFixture()

        let receipt = try fixture.transaction.execute()

        XCTAssertEqual(receipt.generation, 1)
        XCTAssertEqual(receipt.handoffGeneration, 1)
        XCTAssertEqual(
            try fixture.keychain.value(for: .connectorToken),
            String(repeating: "ab", count: 32)
        )
        XCTAssertEqual(
            fixture.hooks.events,
            [
                "prerequisites",
                "restart-new",
                "activate-new",
                "reject-old-local",
                "reconcile-new",
                "ready-new",
                "reject-old-remote",
            ]
        )
        XCTAssertEqual(fixture.hooks.oldLocalTokens, ["old-token"])
        XCTAssertEqual(fixture.hooks.oldRemoteTokens, ["old-token"])
        XCTAssertEqual(fixture.hooks.newTokens, Array(repeating: String(repeating: "ab", count: 32), count: 4))
        let state = try XCTUnwrap(try fixture.stateStore.load())
        XCTAssertEqual(state.connectorCredentialGeneration, 1)
        XCTAssertEqual(state.lastConnectorHandoffGeneration, 1)
        XCTAssertNil(state.pendingConnectorCredentialGeneration)
        XCTAssertEqual(state.recoveryPhase, .stable)
        XCTAssertEqual(state.lastRemoteResult, .ready)
    }

    func testConnectorRotationFailureBeforeCutoverLeavesOldTokenCanonical() throws {
        let fixture = try ConnectorFixture(failingAt: .prerequisites)

        XCTAssertThrowsError(try fixture.transaction.execute()) { error in
            XCTAssertEqual(error as? ConnectorCredentialRotationError, .prerequisitesFailed)
            XCTAssertFalse(String(describing: error).contains("old-token"))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .connectorToken), "old-token")
        XCTAssertEqual(fixture.keychainClient.updateCalls, [])
    }

    func testConnectorRotationCutoverFailureLeavesOldTokenAndPendingRecoveryState() throws {
        let fixture = try ConnectorFixture(keychainUpdateFails: true)

        XCTAssertThrowsError(try fixture.transaction.execute()) { error in
            XCTAssertEqual(error as? ConnectorCredentialRotationError, .cutoverFailed)
            XCTAssertFalse(String(describing: error).contains("old-token"))
            XCTAssertFalse(String(describing: error).contains(String(repeating: "ab", count: 32)))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .connectorToken), "old-token")
        let state = try XCTUnwrap(try fixture.stateStore.load())
        XCTAssertEqual(state.recoveryPhase, .cutoverPendingValidation)
        XCTAssertEqual(state.pendingConnectorCredentialGeneration, 1)
    }

    func testConnectorRotationFailureAfterCutoverNeverRestoresOldToken() throws {
        let fixture = try ConnectorFixture(failingAt: .localActivation)

        XCTAssertThrowsError(try fixture.transaction.execute()) { error in
            XCTAssertEqual(
                error as? ConnectorCredentialRotationError,
                .validationFailed(.localActivation)
            )
            XCTAssertFalse(String(describing: error).contains("old-token"))
            XCTAssertFalse(String(describing: error).contains(String(repeating: "ab", count: 32)))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .connectorToken), String(repeating: "ab", count: 32))
        XCTAssertEqual(fixture.keychainClient.updateCalls.count, 1)
        XCTAssertEqual(fixture.hooks.restoreCalls, 0)
        let state = try XCTUnwrap(try fixture.stateStore.load())
        XCTAssertEqual(state.connectorCredentialGeneration, 1)
        XCTAssertEqual(state.recoveryPhase, .degraded)
        XCTAssertEqual(state.lastRemoteResult, .degraded)
    }

    func testConnectorRotationFailureAtOldRemoteValidationNeverRestoresOldToken() throws {
        let fixture = try ConnectorFixture(failingAt: .oldRemote)

        XCTAssertThrowsError(try fixture.transaction.execute()) { error in
            XCTAssertEqual(
                error as? ConnectorCredentialRotationError,
                .validationFailed(.oldRemoteValidation)
            )
            XCTAssertFalse(String(describing: error).contains("old-token"))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .connectorToken), String(repeating: "ab", count: 32))
        XCTAssertEqual(fixture.keychainClient.updateCalls.count, 1)
    }

    func testConnectorRotationStatePersistenceFailureAfterCutoverKeepsNewTokenCanonical() throws {
        let state = FailingStatePersistenceStore(failingSaveCount: 2)
        let fixture = try ConnectorFixture(stateStore: state)

        XCTAssertThrowsError(try fixture.transaction.execute()) { error in
            XCTAssertEqual(
                error as? ConnectorCredentialRotationError,
                .statePersistenceFailed(.stateCommit)
            )
            XCTAssertFalse(String(describing: error).contains("old-token"))
            XCTAssertFalse(String(describing: error).contains(String(repeating: "ab", count: 32)))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .connectorToken), String(repeating: "ab", count: 32))
    }

    func testConnectorRotationRejectsInterruptedPendingStateBeforeGeneratingAnotherToken() throws {
        let fixture = try ConnectorFixture()
        var state = try fixture.stateStore.loadOrCreate(provider: .ngrok)
        state.pendingConnectorCredentialGeneration = 1
        state.recoveryPhase = .cutoverPendingValidation
        try fixture.stateStore.save(state)

        XCTAssertThrowsError(try fixture.transaction.execute()) { error in
            XCTAssertEqual(error as? ConnectorCredentialRotationError, .interruptedRecoveryRequired)
        }
        XCTAssertEqual(fixture.keychainClient.updateCalls, [])
    }

    func testNgrokCandidateIsNotCommittedUntilEndpointAndReadinessValidationSucceed() throws {
        let fixture = try NgrokFixture()

        XCTAssertEqual(try fixture.transaction.execute(candidate: "candidate-authtoken").probe.origin.value,
                       "https://example.ngrok.app")

        XCTAssertEqual(fixture.hooks.observedCredentials, ["old-authtoken", "old-authtoken", "old-authtoken"])
        XCTAssertEqual(try fixture.keychain.value(for: .ngrokAuthtoken), "candidate-authtoken")
        XCTAssertEqual(fixture.hooks.candidateTokens, ["candidate-authtoken"])
    }

    func testNgrokCandidateValidationFailurePreservesOldCredentialInNormalMode() throws {
        let fixture = try NgrokFixture(failingAt: .readiness, policy: .preserveExistingCredential)

        XCTAssertThrowsError(try fixture.transaction.execute(candidate: "candidate-authtoken")) { error in
            XCTAssertEqual(error as? NgrokCredentialReplacementError, .candidateValidationFailed(.readiness))
            XCTAssertFalse(String(describing: error).contains("old-authtoken"))
            XCTAssertFalse(String(describing: error).contains("candidate-authtoken"))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .ngrokAuthtoken), "old-authtoken")
        XCTAssertEqual(fixture.hooks.restoreCalls, 1)
    }

    func testNgrokCompromisedOldModeFailsClosedWithoutRestoringOldCredential() throws {
        let fixture = try NgrokFixture(failingAt: .readiness, policy: .failClosedIfCompromised)

        XCTAssertThrowsError(try fixture.transaction.execute(candidate: "candidate-authtoken")) { error in
            XCTAssertEqual(error as? NgrokCredentialReplacementError, .failedClosed)
            XCTAssertFalse(String(describing: error).contains("old-authtoken"))
            XCTAssertFalse(String(describing: error).contains("candidate-authtoken"))
        }

        XCTAssertNil(try fixture.keychain.value(for: .ngrokAuthtoken))
        XCTAssertEqual(fixture.hooks.restoreCalls, 0)
    }

    private final class ConnectorFixture {
        let keychainClient: FakeKeychainClient
        let keychain: KeychainStore
        let stateStore: any RemoteConnectorStatePersisting
        let hooks: FakeConnectorHooks
        let transaction: ConnectorCredentialRotationTransaction
        private let directory: URL?

        init(
            failingAt: ConnectorFailurePoint? = nil,
            keychainUpdateFails: Bool = false,
            stateStore: (any RemoteConnectorStatePersisting)? = nil
        ) throws {
            let client = FakeKeychainClient(values: [KeychainItem.connectorToken.key: "old-token"])
            client.updateFails = keychainUpdateFails
            keychainClient = client
            keychain = KeychainStore(
                client: client,
                random: FixedRandomBytes(byte: 0xab)
            )
            hooks = FakeConnectorHooks(failingAt: failingAt)
            if let stateStore {
                self.stateStore = stateStore
                directory = nil
            } else {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("connector-transaction-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                self.stateStore = RemoteConnectorStateStore(directoryURL: directory)
                self.directory = directory
            }
            transaction = ConnectorCredentialRotationTransaction(
                keychain: keychain,
                stateStore: self.stateStore,
                hooks: hooks
            )
        }

        deinit {
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    private final class NgrokFixture {
        let keychainClient: FakeKeychainClient
        let keychain: KeychainStore
        let hooks: FakeNgrokHooks
        let transaction: NgrokCredentialReplacementTransaction

        init(
            failingAt: NgrokFailurePoint? = nil,
            policy: NgrokCredentialFailurePolicy = .preserveExistingCredential
        ) throws {
            let client = FakeKeychainClient(values: [KeychainItem.ngrokAuthtoken.key: "old-authtoken"])
            keychainClient = client
            keychain = KeychainStore(client: client)
            hooks = FakeNgrokHooks(failingAt: failingAt)
            hooks.readCurrent = { [weak client] in
                client?.value(for: .ngrokAuthtoken)
            }
            transaction = NgrokCredentialReplacementTransaction(
                keychain: keychain,
                hooks: hooks,
                failurePolicy: policy
            )
        }
    }

    private enum ConnectorFailurePoint {
        case prerequisites
        case localActivation
        case oldLocal
        case reconcile
        case readiness
        case oldRemote
    }

    private final class FakeConnectorHooks: ConnectorCredentialRotationHooks {
        let failingAt: ConnectorFailurePoint?
        var events: [String] = []
        var oldLocalTokens: [String] = []
        var oldRemoteTokens: [String] = []
        var newTokens: [String] = []
        var restoreCalls = 0

        init(failingAt: ConnectorFailurePoint?) {
            self.failingAt = failingAt
        }

        func validatePrerequisites() throws {
            events.append("prerequisites")
            if failingAt == .prerequisites { throw SyntheticFailure() }
        }

        func restartLocalMCP(using newToken: String) throws {
            events.append("restart-new")
            newTokens.append(newToken)
        }

        func validateLocalActivation(using newToken: String) throws {
            events.append("activate-new")
            newTokens.append(newToken)
            if failingAt == .localActivation { throw SyntheticFailure() }
        }

        func validateOldLocalRouteRejects(oldToken: String) throws {
            events.append("reject-old-local")
            oldLocalTokens.append(oldToken)
            if failingAt == .oldLocal { throw SyntheticFailure() }
        }

        func reconcileRemote(using newToken: String) throws {
            events.append("reconcile-new")
            newTokens.append(newToken)
            if failingAt == .reconcile { throw SyntheticFailure() }
        }

        func validateRemoteReadiness(using newToken: String) throws -> RemoteConnectorProbe {
            events.append("ready-new")
            newTokens.append(newToken)
            if failingAt == .readiness { throw SyntheticFailure() }
            return RemoteConnectorProbe(
                origin: try! RemotePublicOrigin("https://example.ngrok.app"),
                verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        func validateOldRemoteRouteRejects(oldToken: String) throws {
            events.append("reject-old-remote")
            oldRemoteTokens.append(oldToken)
            if failingAt == .oldRemote { throw SyntheticFailure() }
        }
    }

    private enum NgrokFailurePoint {
        case prerequisites
        case launch
        case endpoint
        case readiness
    }

    private final class FakeNgrokHooks: NgrokCredentialCandidateValidationHooks {
        let failingAt: NgrokFailurePoint?
        var candidateTokens: [String] = []
        var observedCredentials: [String?] = []
        var restoreCalls = 0
        var readCurrent: (() -> String?)?

        init(failingAt: NgrokFailurePoint?) {
            self.failingAt = failingAt
        }

        func validatePrerequisites() throws {
            if failingAt == .prerequisites { throw SyntheticFailure() }
        }

        func launchCandidateSession(using candidateAuthtoken: String) throws {
            observedCredentials.append(readCurrent?())
            candidateTokens.append(candidateAuthtoken)
            if failingAt == .launch { throw SyntheticFailure() }
        }

        func reconcileCandidateEndpoint() throws {
            observedCredentials.append(readCurrent?())
            if failingAt == .endpoint { throw SyntheticFailure() }
        }

        func validateAuthenticatedRemoteReadiness() throws -> RemoteConnectorProbe {
            observedCredentials.append(readCurrent?())
            if failingAt == .readiness { throw SyntheticFailure() }
            return RemoteConnectorProbe(
                origin: try! RemotePublicOrigin("https://example.ngrok.app"),
                verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        func restorePriorProviderSession() throws {
            restoreCalls += 1
        }
    }

    private final class FailingStatePersistenceStore: RemoteConnectorStatePersisting {
        private(set) var state: RemoteConnectorStateV1?
        private var saveCount = 0

        init(failingSaveCount: Int) {
            _ = failingSaveCount
        }

        func load() throws -> RemoteConnectorStateV1? {
            state
        }

        func loadOrCreate(provider: RemoteConnectorProvider) throws -> RemoteConnectorStateV1 {
            if let state { return state }
            let fresh = RemoteConnectorStateV1.fresh(provider: provider)
            state = fresh
            return fresh
        }

        func save(_ state: RemoteConnectorStateV1) throws -> RemoteConnectorStateV1 {
            saveCount += 1
            if saveCount >= 2 {
                throw RemoteConnectorStateStoreError.writeFailed
            }
            self.state = state
            return state
        }
    }

    private final class FakeKeychainClient: KeychainClient {
        private(set) var values: [String: String]
        private(set) var updateCalls: [String] = []
        var updateFails = false

        init(values: [String: String]) {
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
            values[key] = value
        }

        func update(value: String, service: String, account: String) throws {
            if updateFails { throw KeychainStoreError.operationFailed(-88) }
            let key = KeychainItem.key(service: service, account: account)
            guard values[key] != nil else { throw KeychainStoreError.itemNotFound }
            updateCalls.append(key)
            values[key] = value
        }

        func delete(service: String, account: String) throws {
            values.removeValue(forKey: KeychainItem.key(service: service, account: account))
        }

        func value(for item: KeychainItem) -> String? {
            values[item.key]
        }
    }

    private struct FixedRandomBytes: SecureRandomByteGenerating {
        let byte: UInt8

        func randomBytes(count: Int) throws -> [UInt8] {
            Array(repeating: byte, count: count)
        }
    }

    private struct SyntheticFailure: Error {}
}
