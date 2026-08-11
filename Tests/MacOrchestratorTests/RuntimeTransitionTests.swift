import Foundation
import XCTest
@testable import MacOrchestrator

final class RuntimeTransitionTests: XCTestCase {
    func testServiceSnapshotRuntimeFieldsDefaultFailClosed() {
        let snapshot = ServiceSnapshot()

        XCTAssertNil(snapshot.controlProfile)
        XCTAssertEqual(snapshot.readyCapabilityCount, 0)
        XCTAssertEqual(snapshot.totalCapabilityCount, CapabilityRegistry.capabilityIDs.count)
        XCTAssertFalse(snapshot.clientRefreshRequired)
    }

    func testConfiguredPortChangeRequiresRestartAndClientRefresh() throws {
        let current = try makeContract(port: 8_000, uiDesired: true)
        let replacement = try makeContract(port: 49_876, uiDesired: true)

        let transition = ManagedRuntimeTransition.between(current: current, replacement: replacement)

        XCTAssertTrue(transition.requiresRestart)
        XCTAssertTrue(transition.requiresClientRefresh)
    }

    func testToolSurfaceChangeRequiresRestartAndClientRefresh() throws {
        let current = try makeContract(port: 8_000, uiDesired: false)
        let replacement = try makeContract(port: 8_000, uiDesired: true)

        let transition = ManagedRuntimeTransition.between(current: current, replacement: replacement)

        XCTAssertTrue(transition.requiresRestart)
        XCTAssertTrue(transition.requiresClientRefresh)
    }

    func testServiceSnapshotPublishesExactContractAndLatchesClientRefresh() throws {
        let contract = try makeContract(port: 8_000, uiDesired: true)
        var snapshot = ServiceSnapshot()

        snapshot.applyRuntimeContract(contract, requiresClientRefresh: true)
        snapshot.applyRuntimeContract(contract, requiresClientRefresh: false)

        XCTAssertEqual(snapshot.controlProfile, .guided)
        XCTAssertEqual(snapshot.readyCapabilityCount, 2)
        XCTAssertEqual(snapshot.totalCapabilityCount, 11)
        XCTAssertTrue(snapshot.clientRefreshRequired)
    }

    private func makeContract(port: Int, uiDesired: Bool) throws -> ManagedRuntimeLaunchContract {
        var configuration = AppConfiguration.fresh(ownerID: "transition-owner")
        configuration.localMCPPort = port
        configuration.desiredCapabilities["mac.ui"] = uiDesired
        let snapshot = CapabilityRegistry(
            configuration: configuration,
            facts: CapabilityReadinessFacts(coreSessionReady: true, localUIReady: true)
        ).snapshot()
        return try ManagedRuntimeLaunchContract.make(
            configuration: configuration,
            capabilitySnapshot: snapshot,
            keychain: KeychainStore(
                client: TransitionKeychainClient(values: [
                    KeychainItem.connectorToken.key: String(repeating: "c", count: 48),
                ]),
                meridianAccount: "runtime-test"
            ),
            inheritedEnvironment: [:]
        )
    }
}

private final class TransitionKeychainClient: KeychainClient {
    private var values: [String: String]

    init(values: [String: String]) {
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
