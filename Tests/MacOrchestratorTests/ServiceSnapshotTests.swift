import XCTest
@testable import MacOrchestrator

final class ServiceSnapshotTests: XCTestCase {
    func testAuthenticatedLifecycleProjectsRemoteCapabilityWithoutURLState() {
        let base = CapabilitySnapshot(
            configGeneration: 3,
            controlProfile: .guided,
            capabilities: [
                "core.session": CapabilityState(
                    desired: true,
                    configured: true,
                    ready: true,
                    health: .ready,
                    dependencies: [],
                    reason: nil
                ),
                "remote.connector": CapabilityState(
                    desired: true,
                    configured: true,
                    ready: false,
                    health: .degraded,
                    dependencies: ["core.session"],
                    reason: "Remote connector readiness has not been authenticated."
                ),
            ],
            policy: CapabilityPolicySnapshot(approvedFileRoots: [], clipboardMutation: false)
        )
        let local = ComponentLifecycleSnapshot(
            id: .mcpServer,
            desired: .enabled,
            lifecycle: .ready,
            liveness: .running,
            readiness: .ready,
            generation: 2
        )
        let remote = ComponentLifecycleSnapshot(
            id: .remoteConnector,
            desired: .enabled,
            lifecycle: .ready,
            liveness: .running,
            readiness: .ready,
            generation: 2
        )
        let lifecycle = LifecycleSnapshot(mcpServer: local, remoteConnector: remote)

        var service = ServiceSnapshot()
        service.effectiveCapabilitySnapshot = base
        service.applyLifecycleSnapshot(lifecycle)

        XCTAssertEqual(service.effectiveCapabilitySnapshot?.capabilities["remote.connector"]?.ready, true)
        XCTAssertEqual(service.readyCapabilityCount, 2)
        XCTAssertEqual(service.effectiveCapabilitySnapshot?.configGeneration, 3)
    }

    func testRemoteReadinessProjectionDoesNotChangeThePythonLaunchContract() {
        let configuration = AppConfiguration.fresh(ownerID: "projection-test")
        let snapshot = CapabilitySnapshot(
            configGeneration: 7,
            controlProfile: .guided,
            capabilities: [
                "core.session": CapabilityState(
                    desired: true,
                    configured: true,
                    ready: true,
                    health: .ready,
                    dependencies: [],
                    reason: nil
                ),
                "remote.connector": CapabilityState(
                    desired: true,
                    configured: true,
                    ready: false,
                    health: .degraded,
                    dependencies: ["core.session"],
                    reason: "Remote readiness is lifecycle-owned."
                ),
            ],
            policy: CapabilityPolicySnapshot(approvedFileRoots: [], clipboardMutation: false)
        )
        let current = ManagedRuntimeLaunchContract(
            port: 8000,
            configuration: configuration,
            capabilitySnapshot: snapshot,
            environment: ["MAC_ORCHESTRATOR_PORT": "8000"],
            redactedSecrets: [],
            ngrokAuthtoken: nil
        )
        let replacement = ManagedRuntimeLaunchContract(
            port: 8000,
            configuration: configuration,
            capabilitySnapshot: snapshot,
            environment: ["MAC_ORCHESTRATOR_PORT": "8000"],
            redactedSecrets: [],
            ngrokAuthtoken: nil
        )

        let readyProjection = snapshot.projected(
            from: LifecycleSnapshot(
                mcpServer: ComponentLifecycleSnapshot(
                    id: .mcpServer,
                    desired: .enabled,
                    lifecycle: .ready,
                    liveness: .running,
                    readiness: .ready
                ),
                remoteConnector: ComponentLifecycleSnapshot(
                    id: .remoteConnector,
                    desired: .enabled,
                    lifecycle: .ready,
                    liveness: .running,
                    readiness: .ready
                )
            )
        )

        XCTAssertTrue(readyProjection.capabilities["remote.connector"]?.ready == true)
        XCTAssertFalse(ManagedRuntimeTransition.between(current: current, replacement: replacement).requiresRestart)
    }
}
