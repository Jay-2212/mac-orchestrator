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
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        markReady(machine, for: .remoteConnector)

        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        machine.recordFailure(for: .mcpServer, reason: "server exited")

        XCTAssertEqual(scheduler.pendingWork(for: .mcpServer).count, 1)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertEqual(scheduler.pendingWork(for: .remoteConnector).count, 1)
        XCTAssertNotNil(machine.retryHandle(for: .mcpServer))
        XCTAssertNotNil(machine.retryHandle(for: .remoteConnector))
    }

    func testSchedulingConnectorRetryDoesNotCancelServerRetry() {
        let (machine, scheduler) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        markReady(machine, for: .remoteConnector)

        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        let connectorHandle = try! XCTUnwrap(machine.retryHandle(for: .remoteConnector))
        machine.recordFailure(for: .mcpServer, reason: "server exited")
        let serverHandle = try! XCTUnwrap(machine.retryHandle(for: .mcpServer))

        XCTAssertFalse(connectorHandle.isCancelled)
        XCTAssertTrue(scheduler.isPending(connectorHandle))
        XCTAssertFalse(serverHandle.isCancelled)
        XCTAssertTrue(scheduler.isPending(serverHandle))
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertEqual(machine.snapshot.remoteConnector.recentFailureCount, 1)
        XCTAssertEqual(machine.snapshot.mcpServer.recentFailureCount, 1)
    }

    func testSchedulingServerRetryDoesNotCancelConnectorRetry() {
        let (machine, scheduler) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        markReady(machine, for: .remoteConnector)

        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        let connectorHandle = try! XCTUnwrap(machine.retryHandle(for: .remoteConnector))
        machine.recordFailure(for: .mcpServer, reason: "server exited")
        let serverHandle = try! XCTUnwrap(machine.retryHandle(for: .mcpServer))

        XCTAssertFalse(connectorHandle.isCancelled)
        XCTAssertTrue(scheduler.isPending(connectorHandle))
        XCTAssertFalse(serverHandle.isCancelled)
        XCTAssertTrue(scheduler.isPending(serverHandle))
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertNotNil(machine.retryHandle(for: .remoteConnector))
        XCTAssertEqual(machine.snapshot.mcpServer.recentFailureCount, 1)
    }

    func testPendingRemoteRetryCallbackStaysFencedWhileMCPIsNotReady() {
        var effects = [LifecycleEffect]()
        let (machine, scheduler) = makeMachine(onEffect: { effects.append($0) })
        markReady(machine, for: .mcpServer)
        markReady(machine, for: .remoteConnector)
        effects.removeAll()

        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        let remoteHandle = try! XCTUnwrap(machine.retryHandle(for: .remoteConnector))
        machine.recordFailure(for: .mcpServer, reason: "server exited")
        effects.removeAll()

        scheduler.fire(remoteHandle)

        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertEqual(machine.snapshot.remoteConnector.recentFailureCount, 1)
        XCTAssertNil(machine.retryHandle(for: .remoteConnector))
        XCTAssertFalse(effects.contains(.start(.remoteConnector)))
    }

    func testRetiredSchedulerCallbackStillRunsForDeterministicFenceCoverage() {
        let scheduler = TestLifecycleScheduler(start: Date(timeIntervalSince1970: 1_000_000))
        var invoked = false
        let handle = scheduler.schedule(at: scheduler.now.addingTimeInterval(1), label: "retired") {
            invoked = true
        }

        scheduler.cancel(handle)
        scheduler.fireIgnoringCancellation(handle)

        XCTAssertTrue(invoked)
        XCTAssertTrue(handle.isCancelled)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testStoppingOneComponentCancelsOnlyItsRetryAndPreservesOtherHistory() {
        let (machine, scheduler) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        markReady(machine, for: .remoteConnector)
        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        let connectorHandle = try! XCTUnwrap(machine.retryHandle(for: .remoteConnector))
        machine.recordFailure(for: .mcpServer, reason: "server exited")

        machine.setDesiredState(.disabled, for: .mcpServer)

        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .stopped)
        XCTAssertEqual(machine.snapshot.mcpServer.recentFailureCount, 0)
        XCTAssertTrue(scheduler.pendingWork(for: .mcpServer).isEmpty)
        XCTAssertFalse(connectorHandle.isCancelled)
        XCTAssertTrue(scheduler.isPending(connectorHandle))
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertEqual(machine.snapshot.remoteConnector.recentFailureCount, 1)
    }

    func testCircuitOpensIndependentlyForTheServer() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        markReady(machine, for: .mcpServer)

        recordFailures(machine, for: .mcpServer)

        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .circuitOpen)
        XCTAssertEqual(machine.snapshot.mcpServer.recentFailureCount, 6)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .stopped)
    }

    func testCircuitOpensIndependentlyForTheConnectorAndLeavesMCPReady() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        markReady(machine, for: .remoteConnector)

        recordFailures(machine, for: .remoteConnector)

        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .circuitOpen)
        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .ready)
        XCTAssertEqual(machine.snapshot.productReadiness, .needsAttention)
    }

    func testServerCircuitOpenBlocksRemoteRestartUntilServerRecovers() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        markReady(machine, for: .remoteConnector)
        recordFailures(machine, for: .mcpServer)

        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertEqual(machine.snapshot.remoteConnector.recentFailureCount, 0)
        XCTAssertNil(machine.retryHandle(for: .remoteConnector))

        machine.reset(.mcpServer)
        markReady(machine, for: .mcpServer)

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
        markReady(machine, for: .mcpServer)
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
        markReady(machine, for: .mcpServer)
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

    func testLegacyProjectionDoesNotTreatNonRunningReadyAsRunning() {
        let mcp = ComponentLifecycleSnapshot(
            id: .mcpServer,
            desired: .enabled,
            lifecycle: .ready,
            liveness: .stopped,
            readiness: .ready
        )
        let remote = ComponentLifecycleSnapshot(
            id: .remoteConnector,
            desired: .disabled,
            lifecycle: .stopped,
            liveness: .stopped,
            readiness: .notReady
        )
        var legacy = ServiceSnapshot()
        legacy.applyLifecycleSnapshot(
            LifecycleSnapshot(mcpServer: mcp, remoteConnector: remote)
        )

        XCTAssertEqual(legacy.server, .starting)
        XCTAssertFalse(legacy.isHealthy)
    }

    func testSuccessfulRecoveryClearsRemoteRetryDeadline() {
        let (machine, scheduler) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        markReady(machine, for: .remoteConnector)
        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        let connectorHandle = try! XCTUnwrap(machine.retryHandle(for: .remoteConnector))

        scheduler.fire(connectorHandle)
        machine.markProcessRunning(for: .remoteConnector)
        markReady(machine, for: .remoteConnector)

        XCTAssertNil(machine.snapshot.mcpServer.nextRetryAt)
        XCTAssertNil(machine.snapshot.remoteConnector.nextRetryAt)
        XCTAssertEqual(machine.snapshot.remoteConnector.recentFailureCount, 1)
    }

    func testStaleRetryCallbackCannotResurrectDisabledComponent() {
        var effects = [LifecycleEffect]()
        let (machine, scheduler) = makeMachine(onEffect: { effects.append($0) })
        machine.setDesiredState(.enabled, for: .mcpServer)
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        markReady(machine, for: .remoteConnector)
        effects.removeAll()
        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        let staleHandle = try! XCTUnwrap(machine.retryHandle(for: .remoteConnector))

        machine.setDesiredState(.disabled, for: .remoteConnector)
        machine.markStopped(for: .remoteConnector)
        effects.removeAll()
        scheduler.fireIgnoringCancellation(staleHandle)

        XCTAssertEqual(machine.snapshot.remoteConnector.desired, .disabled)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .stopped)
        XCTAssertNil(machine.retryHandle(for: .remoteConnector))
        XCTAssertFalse(effects.contains(.start(.remoteConnector)))
    }

    func testStaleRetryCallbackCannotStartWhileQuiescing() {
        var effects = [LifecycleEffect]()
        let (machine, scheduler) = makeMachine(onEffect: { effects.append($0) })
        markReady(machine, for: .mcpServer)
        markReady(machine, for: .remoteConnector)
        effects.removeAll()
        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        let staleHandle = try! XCTUnwrap(machine.retryHandle(for: .remoteConnector))

        machine.prepareForMaintenance()
        machine.markStopped(for: .remoteConnector)
        machine.markStopped(for: .mcpServer)
        effects.removeAll()
        scheduler.fireIgnoringCancellation(staleHandle)

        XCTAssertEqual(machine.snapshot.remoteConnector.desired, .enabled)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .stopped)
        XCTAssertTrue(scheduler.pendingWork(for: .remoteConnector).isEmpty)
        XCTAssertFalse(effects.contains(.start(.remoteConnector)))
    }

    func testSchedulerAdvancesLogicalNowBeforeNestedWorkRuns() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let scheduler = TestLifecycleScheduler(start: start)
        var observed = [Date]()

        scheduler.schedule(at: start.addingTimeInterval(10), label: "outer") {
            observed.append(scheduler.now)
            scheduler.schedule(at: scheduler.now.addingTimeInterval(5), label: "nested") {
                observed.append(scheduler.now)
            }
        }

        scheduler.advance(to: start.addingTimeInterval(20))

        XCTAssertEqual(
            observed,
            [start.addingTimeInterval(10), start.addingTimeInterval(15)]
        )
        XCTAssertEqual(scheduler.now, start.addingTimeInterval(20))
    }

    func testRemoteFailureWhileMCPIsRetryingWaitsWithoutSpendingRemoteBudget() {
        let (machine, scheduler) = makeMachine()
        markReady(machine, for: .mcpServer)
        markReady(machine, for: .remoteConnector)

        machine.recordFailure(for: .mcpServer, reason: "server exited")
        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")

        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .retrying)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertEqual(machine.snapshot.remoteConnector.recentFailureCount, 0)
        XCTAssertNil(machine.retryHandle(for: .remoteConnector))
        XCTAssertEqual(scheduler.pendingWork(for: .remoteConnector).count, 0)
    }

    func testMCPRetryStopsReadyRemoteAndLeavesRemoteFailureHistoryUntouched() {
        var effects = [LifecycleEffect]()
        let (machine, scheduler) = makeMachine(onEffect: { effects.append($0) })
        markReady(machine, for: .mcpServer)
        markReady(machine, for: .remoteConnector)
        effects.removeAll()
        machine.recordFailure(for: .remoteConnector, reason: "tunnel exited")
        let remoteFailures = machine.snapshot.remoteConnector.recentFailureCount
        let remoteHandle = try! XCTUnwrap(machine.retryHandle(for: .remoteConnector))
        scheduler.fire(remoteHandle)
        machine.markProcessRunning(for: .remoteConnector)
        markReady(machine, for: .remoteConnector)
        effects.removeAll()

        machine.recordFailure(for: .mcpServer, reason: "server exited")

        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertEqual(machine.snapshot.remoteConnector.recentFailureCount, remoteFailures)
        XCTAssertTrue(effects.contains(.stop(.remoteConnector)))
    }

    func testMCPStartingStoppingDegradedFailedAndResetBlockRemote() {
        var effects = [LifecycleEffect]()
        let (machine, _) = makeMachine(onEffect: { effects.append($0) })
        markReady(machine, for: .mcpServer)
        markReady(machine, for: .remoteConnector)

        effects.removeAll()
        machine.markStarting(for: .mcpServer)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertTrue(effects.contains(.stop(.remoteConnector)))

        markReady(machine, for: .mcpServer)
        markReady(machine, for: .remoteConnector)
        effects.removeAll()
        machine.markStopped(for: .mcpServer)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertTrue(effects.contains(.stop(.remoteConnector)))

        markReady(machine, for: .mcpServer)
        markReady(machine, for: .remoteConnector)
        effects.removeAll()
        machine.markDegraded(for: .mcpServer, reason: "health mismatch")
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertTrue(effects.contains(.stop(.remoteConnector)))

        markReady(machine, for: .mcpServer)
        markReady(machine, for: .remoteConnector)
        effects.removeAll()
        machine.markFailed(for: .mcpServer, reason: "startup failure")
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertTrue(effects.contains(.stop(.remoteConnector)))

        machine.reset(.mcpServer)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
    }

    func testNetworkLossDoesNotRestartLocalServerAndRestorationSchedulesRemoteOnly() {
        let (machine, scheduler) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        markReady(machine, for: .remoteConnector)

        machine.handleNetworkAvailabilityChanged(false)

        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .ready)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .degraded)

        machine.handleNetworkAvailabilityChanged(true)

        XCTAssertEqual(scheduler.pendingWork(for: .mcpServer).count, 0)
        XCTAssertEqual(scheduler.pendingWork(for: .remoteConnector).count, 1)
    }

    func testNetworkLossAndRestorationPreserveRemoteCircuitUntilExplicitReset() {
        let (machine, scheduler) = makeMachine()
        markReady(machine, for: .mcpServer)
        markReady(machine, for: .remoteConnector)
        recordFailures(machine, for: .remoteConnector)

        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .circuitOpen)
        machine.handleNetworkAvailabilityChanged(false)
        machine.handleNetworkAvailabilityChanged(true)

        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .circuitOpen)
        XCTAssertEqual(machine.snapshot.remoteConnector.circuit, .open)
        XCTAssertTrue(scheduler.pendingWork(for: .remoteConnector).isEmpty)
    }

    func testFailedRemoteRemainsTerminalAcrossNetworkChanges() {
        let (machine, scheduler) = makeMachine()
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markProcessRunning(for: .remoteConnector)
        machine.markFailed(
            for: .remoteConnector,
            reason: "invalid connector configuration",
            liveness: .running
        )

        machine.handleNetworkAvailabilityChanged(false)
        machine.handleNetworkAvailabilityChanged(true)

        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .failed)
        XCTAssertEqual(machine.snapshot.remoteConnector.liveness, .running)
        XCTAssertFalse(machine.snapshot.remoteConnector.isReady)
        XCTAssertTrue(scheduler.pendingWork(for: .remoteConnector).isEmpty)
    }

    func testWakeRevalidatesRemoteWithoutStartingAnotherOwnedProcess() {
        var effects = [LifecycleEffect]()
        let (machine, _) = makeMachine(onEffect: { effects.append($0) })
        machine.setDesiredState(.enabled, for: .mcpServer)
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        markReady(machine, for: .remoteConnector)
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
        markReady(machine, for: .mcpServer)
        machine.setDesiredState(.enabled, for: .remoteConnector)
        markReady(machine, for: .remoteConnector)
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

    func testReadyRequiresRunningLiveness() {
        let direct = ComponentLifecycleSnapshot(
            id: .mcpServer,
            desired: .enabled,
            lifecycle: .ready,
            liveness: .stopped,
            readiness: .ready
        )
        XCTAssertFalse(direct.isReady)

        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markReady(for: .mcpServer)

        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .starting)
        XCTAssertEqual(machine.snapshot.mcpServer.liveness, .starting)
        XCTAssertFalse(machine.snapshot.mcpServer.isReady)
    }

    func testStructuralFailureProjectsThroughLifecycleIntoLegacySnapshot() {
        let (machine, _) = makeMachine()
        machine.markStructuralFailure(
            for: .mcpServer,
            reason: "Configuration startup failed: invalid runtime contract."
        )
        var legacy = ServiceSnapshot()
        legacy.applyLifecycleSnapshot(machine.snapshot)

        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .failed)
        XCTAssertEqual(machine.snapshot.productReadiness, .needsAttention)
        XCTAssertEqual(legacy.server, .failed)
        XCTAssertEqual(legacy.productReadiness, .needsAttention)
        XCTAssertEqual(legacy.error, "Configuration startup failed: invalid runtime contract.")

        machine.setDesiredState(.enabled, for: .mcpServer)
        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .starting)
    }

    func testExplicitEnableClearsAlreadyEnabledStructuralFailure() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .mcpServer)
        machine.markStructuralFailure(
            for: .mcpServer,
            reason: "Configuration startup failed."
        )

        machine.setDesiredState(.enabled, for: .mcpServer)

        XCTAssertEqual(machine.snapshot.mcpServer.desired, .enabled)
        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .starting)
        XCTAssertNil(machine.snapshot.mcpServer.reason)
    }

    func testEnablingStructuralFailureDoesNotClearRemoteComponentState() {
        let (machine, _) = makeMachine()
        machine.setDesiredState(.enabled, for: .remoteConnector)
        machine.markStructuralFailure(
            for: .mcpServer,
            reason: "Configuration startup failed."
        )
        let remoteBefore = machine.snapshot.remoteConnector

        machine.setDesiredState(.enabled, for: .mcpServer)

        XCTAssertEqual(machine.snapshot.mcpServer.lifecycle, .starting)
        XCTAssertEqual(machine.snapshot.remoteConnector.desired, remoteBefore.desired)
        XCTAssertEqual(machine.snapshot.remoteConnector.lifecycle, .waitingForPrerequisites)
        XCTAssertEqual(
            machine.snapshot.remoteConnector.recentFailureCount,
            remoteBefore.recentFailureCount
        )
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

    func testTerminationAuthorizationRequiresLivePIDAndExactComponentMarker() {
        let owner = "owner-123"
        let serverCommand = "python automac_mcp.py --managed-owner \(owner)"
        let tunnelCommand = "ngrok --metadata mac-orchestrator-owner=\(owner)"

        XCTAssertTrue(ProcessOwnership.authorizesTermination(
            pidExists: true,
            commandLine: serverCommand,
            component: .server,
            ownerID: owner
        ))
        XCTAssertTrue(ProcessOwnership.authorizesTermination(
            pidExists: true,
            commandLine: tunnelCommand,
            component: .tunnel,
            ownerID: owner
        ))
        XCTAssertFalse(ProcessOwnership.authorizesTermination(
            pidExists: false,
            commandLine: serverCommand,
            component: .server,
            ownerID: owner
        ))
        XCTAssertFalse(ProcessOwnership.authorizesTermination(
            pidExists: true,
            commandLine: "python automac_mcp.py",
            component: .server,
            ownerID: owner
        ))
        XCTAssertFalse(ProcessOwnership.authorizesTermination(
            pidExists: true,
            commandLine: tunnelCommand,
            component: .server,
            ownerID: owner
        ))
        XCTAssertFalse(ProcessOwnership.authorizesTermination(
            pidExists: true,
            commandLine: serverCommand,
            component: .tunnel,
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

    private func markReady(
        _ machine: LifecycleStateMachine,
        for component: ManagedComponentID
    ) {
        machine.setDesiredState(.enabled, for: component)
        machine.markProcessRunning(for: component)
        machine.markReady(for: component)
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
