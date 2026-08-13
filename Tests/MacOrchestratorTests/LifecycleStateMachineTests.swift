import Foundation
import XCTest
@testable import MacOrchestrator

@MainActor
final class LifecycleStateMachineTests: XCTestCase {
    func testLifecycleVocabularyContainsOnlyTheCurrentlyManagedComponents() {
        XCTAssertEqual(ManagedComponentID.allCases, [.mcpServer, .remoteConnector])
        XCTAssertEqual(ComponentDesiredState.enabled.rawValue, "enabled")
        XCTAssertEqual(ComponentDesiredState.disabled.rawValue, "disabled")
        XCTAssertEqual(ComponentLifecycleState.ready.rawValue, "ready")
        XCTAssertEqual(ComponentLifecycleState.waitingForPrerequisites.rawValue, "waitingForPrerequisites")
        XCTAssertEqual(ProductReadinessState.partiallyReady.rawValue, "partiallyReady")
    }

    func testDesiredRemoteWaitsForServerWithoutConsumingFailureBudget() {
        let (machine, _) = makeMachine()

        machine.setDesiredState(.enabled, for: .remoteConnector)

        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertEqual(machine.snapshot.remoteConnector.recentFailureCount, 0)
        XCTAssertNil(machine.snapshot.remoteConnector.nextRetryAt)
    }

    func testBothComponentsCanHavePendingRetriesAtTheSameTime() {
        let (machine, scheduler) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markReady(for: .remoteConnector)

        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        machine.recordFailure(for: .mcpServer, reason: "server exited")

        XCTAssertEqual(scheduler.pendingWork(for: .mcpServer).count, 1)
        XCTAssertEqual(scheduler.pendingWork(for: .remoteConnector).count, 1)
        XCTAssertNotNil(machine.retryHandle(for: .mcpServer))
        XCTAssertNotNil(machine.retryHandle(for: .remoteConnector))
    }

    func testSchedulingConnectorRetryDoesNotCancelServerRetry() {
        let (machine, scheduler) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markReady(for: .remoteConnector)

        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        let connectorHandle = try! XCTUnwrap(machine.retryHandle(for: .remoteConnector))
        machine.recordFailure(for: .mcpServer, reason: "server exited")

        XCTAssertFalse(connectorHandle.isCancelled)
        XCTAssertTrue(scheduler.isPending(connectorHandle))
        XCTAssertEqual(machine.snapshot.mcpServer.recentFailureCount, 1)
    }

    func testSchedulingServerRetryDoesNotCancelConnectorRetry() {
        let (machine, scheduler) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markReady(for: .remoteConnector)

        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        machine.recordFailure(for: .mcpServer, reason: "server exited")
        let serverHandle = try! XCTUnwrap(machine.retryHandle(for: .mcpServer))

        XCTAssertFalse(serverHandle.isCancelled)
        XCTAssertTrue(scheduler.isPending(serverHandle))
        XCTAssertEqual(machine.snapshot.mcpServer.recentFailureCount, 1)
    }

    func testStoppingOneComponentCancelsOnlyItsRetryAndPreservesOtherHistory() {
        let (machine, scheduler) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markReady(for: .remoteConnector)
        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        machine.recordFailure(for: .mcpServer, reason: "server exited")
        let connectorHandle = try! XCTUnwrap(machine.retryHandle(for: .remoteConnector))

        machine.setDesiredState(.disabled, for: .mcpServer)

        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .stopped)
        XCTAssertEqual(machine.snapshot.mcpServer.recentFailureCount, 0)
        XCTAssertTrue(scheduler.pendingWork(for: .mcpServer).isEmpty)
        XCTAssertFalse(connectorHandle.isCancelled)
        XCTAssertEqual(machine.snapshot.remoteConnector.recentFailureCount, 1)
    }

    func testCircuitOpensIndependentlyForTheServer() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)

        recordFailures(machine, for: .mcpServer)

        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .circuitOpen)
        XCTAssertEqual(machine.snapshot.mcpServer.recentFailureCount, 6)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .stopped)
    }

    func testCircuitOpensIndependentlyForTheConnectorAndLeavesMCPReady() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markReady(for: .remoteConnector)

        recordFailures(machine, for: .remoteConnector)

        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .circuitOpen)
        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .ready)
        XCTAssertEqual(machine.snapshot.productReadiness, .needsAttention)
    }

    func testServerCircuitOpenBlocksRemoteRestartUntilServerRecovers() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markReady(for: .remoteConnector)
        recordFailures(machine, for: .mcpServer)

        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertEqual(machine.snapshot.remoteConnector.recentFailureCount, 0)
        XCTAssertNil(machine.retryHandle(for: .remoteConnector))

        machine.reset(.mcpServer)
        machine.markReady(for: .mcpServer)

        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .starting)
    }

    func testProcessLivenessWithoutSuccessfulReadinessIsNotReady() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markProcessRunning(for: .mcpServer)

        XCTAssertEqual(machine.snapshot.mcpServer.liveness, .running)
        XCTAssertEqual(machine.snapshot.mcpServer.readiness, .notReady)
        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .starting)
        XCTAssertNotEqual(machine.snapshot.productReadiness, .ready)

        machine.markDegraded(for: .mcpServer, reason: "exact health body did not match")
        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .degraded)
        XCTAssertNotEqual(machine.snapshot.productReadiness, .ready)
    }

    func testProductReadinessDistinguishesReadyPartialAndNeedsAttention() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        XCTAssertEqual(machine.snapshot.productReadiness, .ready)

        machine.setDesiredState(.enabled, for: .remoteConnector)
        XCTAssertEqual(machine.snapshot.productReadiness, .partiallyReady)

        machine.markDegraded(for: .remoteConnector, reason: "endpoint not confirmed")
        XCTAssertEqual(machine.snapshot.productReadiness, .partiallyReady)

        recordFailures(machine, for: .remoteConnector)
        XCTAssertEqual(machine.snapshot.productReadiness, .needsAttention)
    }

    func testDisabledOptionalConnectorDoesNotDegradeReadyProduct() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.disabled, for: .remoteConnector)

        XCTAssertEqual(machine.snapshot.productReadiness, .ready)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .stopped)
    }

    func testLegacyServiceSnapshotProjectsFromLifecycleState() {
        let mcp = ComponentLifecycleSnapshot(
            id: .mcpServer,
            desired: .enabled,
            lifecycle: .ready,
            liveness: .running,
            readiness: .ready
        )
        let remote = ComponentLifecycleSnapshot(
            id: .remoteConnector,
            desired: .enabled,
            lifecycle: .retrying,
            liveness: .stopped,
            readiness: .notReady,
            nextRetryAt: Date(timeIntervalSince1970: 1_000_001),
            reason: "endpoint not confirmed"
        )
        let lifecycle = LifecycleSnapshot(mcpServer: mcp, remoteConnector: remote)
        var legacy = ServiceSnapshot()
        legacy.applyLifecycleSnapshot(lifecycle)

        XCTAssertEqual(legacy.server, .running)
        XCTAssertEqual(legacy.tunnel, .reconnecting)
        XCTAssertEqual(legacy.productReadiness, .partiallyReady)
        XCTAssertEqual(legacy.error, "endpoint not confirmed")
    }

    func testSuccessfulRecoveryClearsOnlyRelevantRetryDeadline() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markReady(for: .remoteConnector)
        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        machine.recordFailure(for: .mcpServer, reason: "server exited")
        let connectorDeadline = machine.snapshot.remoteConnector.nextRetryAt

        machine.markReady(for: .mcpServer)

        XCTAssertNil(machine.snapshot.mcpServer.nextRetryAt)
        XCTAssertEqual(machine.snapshot.remoteConnector.nextRetryAt, connectorDeadline)
        XCTAssertEqual(machine.snapshot.remoteConnector.recentFailureCount, 1)
    }

    func testStaleRetryCallbackCannotResurrectDisabledComponent() {
        let (machine, scheduler) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markReady(for: .remoteConnector)
        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        let staleHandle = try! XCTUnwrap(machine.retryHandle(for: .remoteConnector))

        machine.setDesiredState(.disabled, for: .remoteConnector)
        scheduler.fire(staleHandle)

        XCTAssertEqual(machine.snapshot.remoteConnector.desired, .disabled)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .stopped)
        XCTAssertNil(machine.retryHandle(for: .remoteConnector))
    }

    func testNetworkLossDoesNotRestartLocalServerAndRestorationSchedulesRemoteOnly() {
        let (machine, scheduler) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markReady(for: .remoteConnector)

        machine.handleNetworkAvailabilityChanged(false)

        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .ready)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .degraded)

        machine.handleNetworkAvailabilityChanged(true)

        XCTAssertEqual(scheduler.pendingWork(for: .mcpServer).count, 0)
        XCTAssertEqual(scheduler.pendingWork(for: .remoteConnector).count, 1)
    }

    func testWakeRevalidatesRemoteWithoutStartingAnotherOwnedProcess() {
        var effects = [LifecycleEffect]()
        let (machine, _) = makeMachine(onEffect: { effects.append($0) })
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markReady(for: .remoteConnector)
        effects.removeAll()

        machine.handleWake()

        XCTAssertEqual(effects, [.revalidate(.remoteConnector)])
        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .ready)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .ready)
    }

    func testMaintenanceStopsRemoteBeforeServerAndPreservesDesiredState() {
        var effects = [LifecycleEffect]()
        let (machine, _) = makeMachine(onEffect: { effects.append($0) })
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markReady(for: .remoteConnector)
        effects.removeAll()

        machine.prepareForMaintenance()

        XCTAssertEqual(effects, [.stop(.remoteConnector), .stop(.mcpServer)])
        XCTAssertEqual(machine.snapshot.mcpServer.desired, .enabled)
        XCTAssertEqual(machine.snapshot.remoteConnector.desired, .enabled)
        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .stopping)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .stopping)

        machine.markStopped(for: .remoteConnector)
        machine.markStopped(for: .mcpServer)
        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .stopped)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .stopped)
    }

    func testOwnershipMarkersCannotBeConfusedAcrossComponents() {
        let owner = "owner-123"
        XCTAssertTrue(ProcessOwnership.matches(
            commandLine: "python automac_mcp.py --managed-owner \(owner)",
            component: .server,
            ownerID: owner
        ))
        XCTAssertFalse(ProcessOwnership.matches(
            commandLine: "ngrok --metadata mac-orchestrator-owner=\(owner)",
            component: .server,
            ownerID: owner
        ))
        XCTAssertFalse(ProcessOwnership.matches(
            commandLine: "python automac_mcp.py --managed-owner another-owner",
            component: .server,
            ownerID: owner
        ))
    }

    func testOccupiedPersistedPortRefusesStartWithoutAuthorizingTermination() {
        XCTAssertEqual(
            PortSafetyPolicy.decision(isOccupied: true),
            .refuseWithoutTermination
        )
        XCTAssertEqual(
            PortSafetyPolicy.decision(isOccupied: false),
            .allowStart
        )
    }

    private func makeMachine(
        onEffect: ((LifecycleEffect) -> Void)? = nil
    ) -> (LifecycleStateMachine, TestLifecycleScheduler) {
        let scheduler = TestLifecycleScheduler(
            start: Date(timeIntervalSince1970: 1_000_000)
        )
        let machine = LifecycleStateMachine(scheduler: scheduler)
        machine.onEffect = onEffect
        return (machine, scheduler)
    }

    private func recordFailures(
        _ machine: LifecycleStateMachine,
        for component: ManagedComponentID
    ) {
        for index in 0..<6 {
            machine.recordFailure(
                for: component,
                reason: "failure \(index)",
                at: Date(timeIntervalSince1970: 1_000_000)
            )
        }
    }
}
