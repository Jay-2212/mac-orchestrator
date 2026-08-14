import Foundation
import Security
import XCTest
@testable import MacOrchestrator

final class RemoteCredentialTransactionTests: XCTestCase {
    func testCredentialOperationCoordinatorRejectsOverlapWithoutBlocking() async throws {
        let coordinator = RemoteCredentialOperationCoordinator()
        try await coordinator.acquire()

        do {
            try await coordinator.acquire()
            XCTFail("Expected overlapping operation to be rejected")
        } catch {
            XCTAssertEqual(error as? RemoteCredentialOperationError, .operationInProgress)
        }

        await coordinator.release()
        try await coordinator.acquire()
        await coordinator.release()
    }

    func testSuccessfulConnectorRotationAdvancesGenerationExactlyOnceAndScopesOldTokenToNegativeHooks() async throws {
        let fixture = try ConnectorFixture()

        let receipt = try await fixture.transaction.execute()

        XCTAssertEqual(receipt.generation, 1)
        XCTAssertEqual(receipt.clientHandoff, .notAvailable)
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
        XCTAssertNil(state.handoffReceipt)
        XCTAssertNil(state.pendingConnectorCredentialGeneration)
        XCTAssertEqual(state.recoveryPhase, .stable)
        XCTAssertEqual(state.lastRemoteResult, .ready)
    }

    func testConnectorRotationFailureBeforeCutoverLeavesOldTokenCanonical() async throws {
        let fixture = try ConnectorFixture(failingAt: .prerequisites)

        do {
            _ = try await fixture.transaction.execute()
            XCTFail("Expected prerequisites failure")
        } catch {
            XCTAssertEqual(error as? ConnectorCredentialRotationError, .prerequisitesFailed)
            XCTAssertFalse(String(describing: error).contains("old-token"))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .connectorToken), "old-token")
        XCTAssertEqual(fixture.keychainClient.updateCalls, [])
    }

    func testConnectorRotationCutoverFailureLeavesOldTokenAndPendingRecoveryState() async throws {
        let fixture = try ConnectorFixture(keychainUpdateFails: true)

        do {
            _ = try await fixture.transaction.execute()
            XCTFail("Expected cutover failure")
        } catch {
            XCTAssertEqual(error as? ConnectorCredentialRotationError, .cutoverFailed)
            XCTAssertFalse(String(describing: error).contains("old-token"))
            XCTAssertFalse(String(describing: error).contains(String(repeating: "ab", count: 32)))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .connectorToken), "old-token")
        let state = try XCTUnwrap(try fixture.stateStore.load())
        XCTAssertEqual(state.recoveryPhase, .cutoverPendingValidation)
        XCTAssertEqual(state.pendingConnectorCredentialGeneration, 1)
    }

    func testPostCutoverFailureRetainsNewTokenAndNeverRestoresOldToken() async throws {
        let fixture = try ConnectorFixture(failingAt: .localActivation)

        do {
            _ = try await fixture.transaction.execute()
            XCTFail("Expected local activation failure")
        } catch {
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

    func testConnectorRotationFailureAtOldRemoteValidationNeverRestoresOldToken() async throws {
        let fixture = try ConnectorFixture(failingAt: .oldRemote)

        do {
            _ = try await fixture.transaction.execute()
            XCTFail("Expected old remote validation failure")
        } catch {
            XCTAssertEqual(
                error as? ConnectorCredentialRotationError,
                .validationFailed(.oldRemoteValidation)
            )
            XCTAssertFalse(String(describing: error).contains("old-token"))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .connectorToken), String(repeating: "ab", count: 32))
        XCTAssertEqual(fixture.keychainClient.updateCalls.count, 1)
    }

    func testStateCommitFailureLeavesRecoverableDegradedState() async throws {
        let state = FailingStatePersistenceStore(failingSaveCount: 2)
        let fixture = try ConnectorFixture(stateStore: state)

        do {
            _ = try await fixture.transaction.execute()
            XCTFail("Expected state persistence failure")
        } catch {
            XCTAssertEqual(
                error as? ConnectorCredentialRotationError,
                .statePersistenceFailed(.stateCommit)
            )
            XCTAssertFalse(String(describing: error).contains("old-token"))
            XCTAssertFalse(String(describing: error).contains(String(repeating: "ab", count: 32)))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .connectorToken), String(repeating: "ab", count: 32))
        XCTAssertEqual(try XCTUnwrap(state.state).recoveryPhase, .degraded)
    }

    func testInterruptedRotationGeneratesFreshForwardTokenFromCurrentKeychainValue() async throws {
        var pending = RemoteConnectorStateV1.fresh(provider: .ngrok)
        pending.pendingConnectorCredentialGeneration = 1
        pending.recoveryPhase = .cutoverPendingValidation
        let fixture = try ConnectorFixture(
            currentConnectorToken: "possibly-new-current-token",
            randomByte: 0xcd,
            initialState: pending
        )

        let receipt = try await fixture.transaction.execute()

        XCTAssertEqual(receipt.generation, 2)
        XCTAssertEqual(fixture.hooks.oldLocalTokens, ["possibly-new-current-token"])
        XCTAssertEqual(fixture.hooks.oldRemoteTokens, ["possibly-new-current-token"])
        XCTAssertNotEqual(try fixture.keychain.value(for: .connectorToken), "possibly-new-current-token")
        let state = try XCTUnwrap(try fixture.stateStore.load())
        XCTAssertEqual(state.connectorCredentialGeneration, 2)
        XCTAssertEqual(state.recoveryPhase, .stable)
    }

    func testSuccessfulRotationPreservesOldHandoffReceipt() async throws {
        let origin = try RemotePublicOrigin("https://old.ngrok.app")
        var initial = RemoteConnectorStateV1.fresh(provider: .ngrok)
        initial.lastVerifiedPublicOrigin = origin
        initial.lastSuccessfulRemoteProbeAt = Date(timeIntervalSince1970: 1_700_000_000)
        initial.lastRemoteResult = .ready
        initial.handoffReceipt = RemoteConnectorHandoffReceipt(
            connectorCredentialGeneration: 0,
            publicOrigin: origin,
            handedOffAt: Date(timeIntervalSince1970: 1_699_999_999)
        )
        let fixture = try ConnectorFixture(initialState: initial)

        let receipt = try await fixture.transaction.execute()

        XCTAssertEqual(receipt.clientHandoff, .changed)
        let state = try XCTUnwrap(try fixture.stateStore.load())
        XCTAssertEqual(state.handoffReceipt?.connectorCredentialGeneration, 0)
        XCTAssertEqual(state.handoffReceipt?.publicOrigin, origin)
        XCTAssertEqual(state.clientHandoffClassification, .changed)
    }

    func testNgrokCandidateIsNotPersistedBeforeAuthenticatedValidation() async throws {
        let fixture = try NgrokFixture()

        let receipt = try await fixture.transaction.execute(candidate: "candidate-authtoken")
        XCTAssertEqual(receipt.probe.origin.value, "https://example.ngrok.app")

        XCTAssertEqual(fixture.hooks.observedCredentials, ["old-authtoken", "old-authtoken", "old-authtoken"])
        XCTAssertEqual(try fixture.keychain.value(for: .ngrokAuthtoken), "candidate-authtoken")
        XCTAssertEqual(fixture.hooks.candidateTokens, ["candidate-authtoken"])
        XCTAssertEqual(fixture.hooks.lastRemoteResultAtReadiness, .unknown)
        XCTAssertEqual(try XCTUnwrap(try fixture.stateStore.load()).lastRemoteResult, .ready)
    }

    func testNgrokCandidateValidationFailurePreservesOldCredentialInNormalMode() async throws {
        let fixture = try NgrokFixture(failingAt: .readiness, policy: .preserveExistingCredential)

        do {
            _ = try await fixture.transaction.execute(candidate: "candidate-authtoken")
            XCTFail("Expected ngrok validation failure")
        } catch {
            XCTAssertEqual(error as? NgrokCredentialReplacementError, .candidateValidationFailed(.readiness))
            XCTAssertFalse(String(describing: error).contains("old-authtoken"))
            XCTAssertFalse(String(describing: error).contains("candidate-authtoken"))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .ngrokAuthtoken), "old-authtoken")
        XCTAssertEqual(fixture.hooks.restoreCalls, 1)
    }

    func testNgrokCompromisedOldModeFailsClosedWithoutRestoringOldCredential() async throws {
        let fixture = try NgrokFixture(failingAt: .readiness, policy: .failClosedIfCompromised)

        do {
            _ = try await fixture.transaction.execute(candidate: "candidate-authtoken")
            XCTFail("Expected fail-closed result")
        } catch {
            XCTAssertEqual(error as? NgrokCredentialReplacementError, .failedClosed)
            XCTAssertFalse(String(describing: error).contains("old-authtoken"))
            XCTAssertFalse(String(describing: error).contains("candidate-authtoken"))
        }

        XCTAssertNil(try fixture.keychain.value(for: .ngrokAuthtoken))
        XCTAssertEqual(fixture.hooks.restoreCalls, 0)
    }

    func testNgrokCommitAmbiguityDoesNotRestorePossiblyCanonicalOldCredential() async throws {
        let fixture = try NgrokFixture()
        fixture.keychainClient.simulateNgrokReadBackMismatch = true

        do {
            _ = try await fixture.transaction.execute(candidate: "candidate-authtoken")
            XCTFail("Expected ambiguous commit")
        } catch {
            XCTAssertEqual(error as? NgrokCredentialReplacementError, .commitAmbiguous)
            XCTAssertFalse(String(describing: error).contains("old-authtoken"))
            XCTAssertFalse(String(describing: error).contains("candidate-authtoken"))
        }

        XCTAssertEqual(try fixture.keychain.value(for: .ngrokAuthtoken), "candidate-authtoken")
        XCTAssertEqual(fixture.hooks.restoreCalls, 0)
        XCTAssertEqual(try XCTUnwrap(try fixture.stateStore.load()).lastRemoteResult, .degraded)
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
            stateStore: (any RemoteConnectorStatePersisting)? = nil,
            currentConnectorToken: String = "old-token",
            randomByte: UInt8 = 0xab,
            initialState: RemoteConnectorStateV1? = nil
        ) throws {
            let client = FakeKeychainClient(values: [KeychainItem.connectorToken.key: currentConnectorToken])
            client.updateFails = keychainUpdateFails
            keychainClient = client
            keychain = KeychainStore(
                client: client,
                random: FixedRandomBytes(byte: randomByte)
            )
            hooks = FakeConnectorHooks(failingAt: failingAt)
            let resolvedStateStore: any RemoteConnectorStatePersisting
            if let stateStore {
                resolvedStateStore = stateStore
                directory = nil
            } else {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("connector-transaction-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                resolvedStateStore = RemoteConnectorStateStore(directoryURL: directory)
                self.directory = directory
            }
            self.stateStore = resolvedStateStore
            if let initialState {
                try resolvedStateStore.save(initialState)
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
        let stateStore: any RemoteConnectorStatePersisting
        let hooks: FakeNgrokHooks
        let transaction: NgrokCredentialReplacementTransaction
        private let directory: URL?

        init(
            failingAt: NgrokFailurePoint? = nil,
            policy: NgrokCredentialFailurePolicy = .preserveExistingCredential
        ) throws {
            let client = FakeKeychainClient(values: [KeychainItem.ngrokAuthtoken.key: "old-authtoken"])
            keychainClient = client
            keychain = KeychainStore(client: client)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ngrok-transaction-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let resolvedStateStore: any RemoteConnectorStatePersisting =
                RemoteConnectorStateStore(directoryURL: directory)
            self.stateStore = resolvedStateStore
            _ = try resolvedStateStore.loadOrCreate(provider: .ngrok)
            self.directory = directory
            hooks = FakeNgrokHooks(failingAt: failingAt)
            hooks.readCurrent = { [weak client] in
                client?.value(for: .ngrokAuthtoken)
            }
            hooks.stateStore = resolvedStateStore
            transaction = NgrokCredentialReplacementTransaction(
                keychain: keychain,
                hooks: hooks,
                failurePolicy: policy,
                stateStore: resolvedStateStore
            )
        }

        deinit {
            if let directory { try? FileManager.default.removeItem(at: directory) }
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

    private final class FakeConnectorHooks: @unchecked Sendable, ConnectorCredentialRotationHooks {
        let failingAt: ConnectorFailurePoint?
        var events: [String] = []
        var oldLocalTokens: [String] = []
        var oldRemoteTokens: [String] = []
        var newTokens: [String] = []
        var restoreCalls = 0

        init(failingAt: ConnectorFailurePoint?) {
            self.failingAt = failingAt
        }

        func validatePrerequisites() async throws {
            events.append("prerequisites")
            if failingAt == .prerequisites { throw SyntheticFailure() }
        }

        func restartLocalMCP(using newToken: String) async throws {
            events.append("restart-new")
            newTokens.append(newToken)
        }

        func validateLocalActivation(using newToken: String) async throws {
            events.append("activate-new")
            newTokens.append(newToken)
            if failingAt == .localActivation { throw SyntheticFailure() }
        }

        func validateOldLocalRouteRejects(oldToken: String) async throws {
            events.append("reject-old-local")
            oldLocalTokens.append(oldToken)
            if failingAt == .oldLocal { throw SyntheticFailure() }
        }

        func reconcileRemote(using newToken: String) async throws {
            events.append("reconcile-new")
            newTokens.append(newToken)
            if failingAt == .reconcile { throw SyntheticFailure() }
        }

        func validateRemoteReadiness(using newToken: String) async throws -> RemoteConnectorProbe {
            events.append("ready-new")
            newTokens.append(newToken)
            if failingAt == .readiness { throw SyntheticFailure() }
            return RemoteConnectorProbe(
                origin: try! RemotePublicOrigin("https://example.ngrok.app"),
                verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        func validateOldRemoteRouteRejects(oldToken: String) async throws {
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

    private final class FakeNgrokHooks: @unchecked Sendable, NgrokCredentialCandidateValidationHooks {
        let failingAt: NgrokFailurePoint?
        var candidateTokens: [String] = []
        var observedCredentials: [String?] = []
        var restoreCalls = 0
        var readCurrent: (() -> String?)?
        var stateStore: (any RemoteConnectorStatePersisting)?
        var lastRemoteResultAtReadiness: RemoteResultClassification?

        init(failingAt: NgrokFailurePoint?) {
            self.failingAt = failingAt
        }

        func validatePrerequisites() async throws {
            if failingAt == .prerequisites { throw SyntheticFailure() }
        }

        func launchCandidateSession(using candidateAuthtoken: String) async throws {
            observedCredentials.append(readCurrent?())
            candidateTokens.append(candidateAuthtoken)
            if failingAt == .launch { throw SyntheticFailure() }
        }

        func reconcileCandidateEndpoint() async throws {
            observedCredentials.append(readCurrent?())
            if failingAt == .endpoint { throw SyntheticFailure() }
        }

        func validateAuthenticatedRemoteReadiness() async throws -> RemoteConnectorProbe {
            observedCredentials.append(readCurrent?())
            if let stateStore {
                lastRemoteResultAtReadiness = try? stateStore.load()?.lastRemoteResult
            }
            if failingAt == .readiness { throw SyntheticFailure() }
            return RemoteConnectorProbe(
                origin: try! RemotePublicOrigin("https://example.ngrok.app"),
                verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }

        func restorePriorProviderSession() async throws {
            restoreCalls += 1
        }
    }

    private final class FailingStatePersistenceStore: RemoteConnectorStatePersisting {
        private(set) var state: RemoteConnectorStateV1?
        private var saveCount = 0
        private let failingSaveCount: Int

        init(failingSaveCount: Int) {
            self.failingSaveCount = failingSaveCount
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
            if saveCount == failingSaveCount {
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
        var simulateNgrokReadBackMismatch = false

        init(values: [String: String]) {
            self.values = values
        }

        func read(service: String, account: String) throws -> String? {
            if simulateNgrokReadBackMismatch,
               service == KeychainItem.ngrokAuthtoken.service,
               account == KeychainItem.ngrokAuthtoken.account {
                simulateNgrokReadBackMismatch = false
                return "old-authtoken"
            }
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
