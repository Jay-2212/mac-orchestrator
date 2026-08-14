import Foundation
import XCTest
@testable import MacOrchestrator

final class RemoteProbeCoordinatorTests: XCTestCase {
    func testEndpointOnlyDoesNotMarkRemoteAuthenticated() async {
        let adapter = FakeAdapter(
            inspection: .available(endpoints: [
                NgrokEndpoint(
                    url: "https://remote.example",
                    upstream: NgrokEndpointUpstream(url: "http://127.0.0.1:8000")
                ),
            ])
        )
        let coordinator = RemoteProbeCoordinator(
            adapter: adapter,
            probeRunner: { _, _ in
                XCTFail("The authenticated probe must not be skipped for an unknown endpoint.")
                return RemoteActivationProbeOutcome(phase: .initialize, error: .transport)
            }
        )

        let result = await coordinator.run(
            RemoteProbeRequest(
                tunnelTarget: "http://127.0.0.1:8000",
                connectorToken: "connector-token"
            )
        )

        guard case .authenticated(let origin, _) = result else {
            return XCTFail("A current endpoint must proceed to authenticated readiness.")
        }
        XCTAssertEqual(origin.value, "https://remote.example")
    }

    func testStableOriginUsesAgentAPIInspectionWithoutRepeatingAuthenticatedActivation() async {
        let adapter = FakeAdapter(
            inspection: .available(endpoints: [
                NgrokEndpoint(
                    url: "https://remote.example/",
                    upstream: NgrokEndpointUpstream(url: "http://127.0.0.1:8000/")
                ),
            ])
        )
        let probeCalls = CallCounter()
        let coordinator = RemoteProbeCoordinator(
            adapter: adapter,
            probeRunner: { _, _ in
                await probeCalls.increment()
                return RemoteActivationProbeOutcome(
                    phase: .safeCall,
                    details: RemoteActivationProbeDetails(
                        exposedTools: ["get_session_state"],
                        sessionEstablished: true,
                        safeCallSucceeded: true
                    )
                )
            }
        )
        let request = RemoteProbeRequest(
            tunnelTarget: "http://127.0.0.1:8000",
            connectorToken: "connector-token",
            knownPublicOrigin: try! RemotePublicOrigin("https://remote.example"),
            forceAuthenticatedProbe: false
        )

        let result = await coordinator.run(request)

        XCTAssertEqual(
            result,
            .unchanged(publicOrigin: try! RemotePublicOrigin("https://remote.example"))
        )
        let observedProbeCalls = await probeCalls.value()
        XCTAssertEqual(observedProbeCalls, 0)
    }

    func testAmbiguousEndpointFailsBeforeAuthentication() async {
        let adapter = FakeAdapter(
            inspection: .available(endpoints: [
                NgrokEndpoint(
                    url: "https://one.example",
                    upstream: NgrokEndpointUpstream(url: "http://127.0.0.1:8000")
                ),
                NgrokEndpoint(
                    url: "https://two.example",
                    upstream: NgrokEndpointUpstream(url: "http://127.0.0.1:8000")
                ),
            ])
        )
        let coordinator = RemoteProbeCoordinator(
            adapter: adapter,
            probeRunner: { _, _ in
                XCTFail("Ambiguous endpoints must not reach MCP authentication.")
                return RemoteActivationProbeOutcome(phase: .initialize, error: .transport)
            }
        )

        let result = await coordinator.run(
            RemoteProbeRequest(
                tunnelTarget: "http://127.0.0.1:8000",
                connectorToken: "connector-token"
            )
        )

        XCTAssertEqual(result, .failed(.ambiguousEndpoint))
    }

    func testOverlappingRequestsReturnBusyAndOnlyOneRuns() async {
        let adapter = FakeAdapter(
            inspection: .available(endpoints: [
                NgrokEndpoint(
                    url: "https://remote.example",
                    upstream: NgrokEndpointUpstream(url: "http://127.0.0.1:8000")
                ),
            ])
        )
        let gate = ProbeGate()
        let coordinator = RemoteProbeCoordinator(
            adapter: adapter,
            probeRunner: { _, _ in
                await gate.waitUntilReleased()
                return RemoteActivationProbeOutcome(
                    phase: .safeCall,
                    details: RemoteActivationProbeDetails(
                        exposedTools: ["get_session_state"],
                        sessionEstablished: true,
                        safeCallSucceeded: true
                    )
                )
            }
        )
        let request = RemoteProbeRequest(
            tunnelTarget: "http://127.0.0.1:8000",
            connectorToken: "connector-token"
        )

        let first = Task { await coordinator.run(request) }
        await gate.waitUntilStarted()
        let second = await coordinator.run(request)
        await gate.release()
        let firstResult = await first.value

        XCTAssertEqual(second, .busy)
        guard case .authenticated = firstResult else {
            return XCTFail("The first request should finish normally after the gate opens.")
        }
    }

    func testFenceRejectsEveryStaleDimension() throws {
        let origin = try RemotePublicOrigin("https://remote.example")
        let baseline = RemoteProbeFence(
            tunnelProcessID: 11,
            serverProcessID: 12,
            tunnelLaunchGeneration: 13,
            serverLaunchGeneration: 14,
            configurationGeneration: 15,
            connectorCredentialGeneration: 16,
            knownPublicOrigin: origin,
            localMCPGeneration: 17,
            localMCPReady: true,
            remoteDesired: true,
            serverDesired: true,
            maintenance: false,
            quitting: false
        )

        let staleVariants: [RemoteProbeFence] = [
            RemoteProbeFence(tunnelProcessID: 99, serverProcessID: 12, tunnelLaunchGeneration: 13, serverLaunchGeneration: 14, configurationGeneration: 15, connectorCredentialGeneration: 16, knownPublicOrigin: origin, localMCPGeneration: 17, localMCPReady: true, remoteDesired: true, serverDesired: true, maintenance: false, quitting: false),
            RemoteProbeFence(tunnelProcessID: 11, serverProcessID: 12, tunnelLaunchGeneration: 99, serverLaunchGeneration: 14, configurationGeneration: 15, connectorCredentialGeneration: 16, knownPublicOrigin: origin, localMCPGeneration: 17, localMCPReady: true, remoteDesired: true, serverDesired: true, maintenance: false, quitting: false),
            RemoteProbeFence(tunnelProcessID: 11, serverProcessID: 12, tunnelLaunchGeneration: 13, serverLaunchGeneration: 99, configurationGeneration: 15, connectorCredentialGeneration: 16, knownPublicOrigin: origin, localMCPGeneration: 17, localMCPReady: true, remoteDesired: true, serverDesired: true, maintenance: false, quitting: false),
            RemoteProbeFence(tunnelProcessID: 11, serverProcessID: 12, tunnelLaunchGeneration: 13, serverLaunchGeneration: 14, configurationGeneration: 99, connectorCredentialGeneration: 16, knownPublicOrigin: origin, localMCPGeneration: 17, localMCPReady: true, remoteDesired: true, serverDesired: true, maintenance: false, quitting: false),
            RemoteProbeFence(tunnelProcessID: 11, serverProcessID: 12, tunnelLaunchGeneration: 13, serverLaunchGeneration: 14, configurationGeneration: 15, connectorCredentialGeneration: 99, knownPublicOrigin: origin, localMCPGeneration: 17, localMCPReady: true, remoteDesired: true, serverDesired: true, maintenance: false, quitting: false),
            RemoteProbeFence(tunnelProcessID: 11, serverProcessID: 12, tunnelLaunchGeneration: 13, serverLaunchGeneration: 14, configurationGeneration: 15, connectorCredentialGeneration: 16, knownPublicOrigin: try RemotePublicOrigin("https://changed.example"), localMCPGeneration: 17, localMCPReady: true, remoteDesired: true, serverDesired: true, maintenance: false, quitting: false),
            RemoteProbeFence(tunnelProcessID: 11, serverProcessID: 12, tunnelLaunchGeneration: 13, serverLaunchGeneration: 14, configurationGeneration: 15, connectorCredentialGeneration: 16, knownPublicOrigin: origin, localMCPGeneration: 99, localMCPReady: true, remoteDesired: true, serverDesired: true, maintenance: false, quitting: false),
            RemoteProbeFence(tunnelProcessID: 11, serverProcessID: 12, tunnelLaunchGeneration: 13, serverLaunchGeneration: 14, configurationGeneration: 15, connectorCredentialGeneration: 16, knownPublicOrigin: origin, localMCPGeneration: 17, localMCPReady: false, remoteDesired: true, serverDesired: true, maintenance: false, quitting: false),
            RemoteProbeFence(tunnelProcessID: 11, serverProcessID: 12, tunnelLaunchGeneration: 13, serverLaunchGeneration: 14, configurationGeneration: 15, connectorCredentialGeneration: 16, knownPublicOrigin: origin, localMCPGeneration: 17, localMCPReady: true, remoteDesired: false, serverDesired: true, maintenance: false, quitting: false),
            RemoteProbeFence(tunnelProcessID: 11, serverProcessID: 12, tunnelLaunchGeneration: 13, serverLaunchGeneration: 14, configurationGeneration: 15, connectorCredentialGeneration: 16, knownPublicOrigin: origin, localMCPGeneration: 17, localMCPReady: true, remoteDesired: true, serverDesired: false, maintenance: false, quitting: false),
            RemoteProbeFence(tunnelProcessID: 11, serverProcessID: 12, tunnelLaunchGeneration: 13, serverLaunchGeneration: 14, configurationGeneration: 15, connectorCredentialGeneration: 16, knownPublicOrigin: origin, localMCPGeneration: 17, localMCPReady: true, remoteDesired: true, serverDesired: true, maintenance: true, quitting: false),
            RemoteProbeFence(tunnelProcessID: 11, serverProcessID: 12, tunnelLaunchGeneration: 13, serverLaunchGeneration: 14, configurationGeneration: 15, connectorCredentialGeneration: 16, knownPublicOrigin: origin, localMCPGeneration: 17, localMCPReady: true, remoteDesired: true, serverDesired: true, maintenance: false, quitting: true),
        ]

        XCTAssertTrue(baseline.matches(baseline))
        staleVariants.forEach { stale in
            XCTAssertFalse(baseline.matches(stale))
        }
    }

    private struct FakeAdapter: RemoteConnectorAdapter, Sendable {
        let inspection: RemoteConnectorAgentAPIInspection

        var provider: RemoteConnectorProvider { .ngrok }

        func validatePrerequisites(
            _ input: RemoteConnectorPrerequisiteInput
        ) -> RemoteConnectorPrerequisiteReport {
            RemoteConnectorPrerequisiteReport(
                executableAvailable: true,
                configurationAvailable: true,
                authenticationConfigured: true,
                agentAPIBaseURLValid: true
            )
        }

        func makeLaunchSpecification(
            for input: RemoteConnectorLaunchInput
        ) throws -> RemoteConnectorLaunchSpecification {
            RemoteConnectorLaunchSpecification(
                executableURL: input.executableURL,
                arguments: [],
                environment: input.environment
            )
        }

        func inspectAgentAPI() async -> RemoteConnectorAgentAPIInspection {
            inspection
        }

        func reconcileEndpoint(
            from inspection: RemoteConnectorAgentAPIInspection,
            matching expectedUpstream: String
        ) -> RemoteEndpointReconciliation {
            switch inspection {
            case let .available(endpoints):
                return NgrokEndpointParser.reconcile(
                    endpoints: endpoints,
                    matching: expectedUpstream
                )
            case .unavailable:
                return .agentAPIUnavailable
            case .invalidResponse:
                return .invalidAgentAPIResponse
            }
        }

        func diagnostics(
            for prerequisites: RemoteConnectorPrerequisiteReport,
            inspection: RemoteConnectorAgentAPIInspection?,
            reconciliation: RemoteEndpointReconciliation?
        ) -> [RemoteConnectorDiagnostic] {
            []
        }
    }

    private actor CallCounter {
        private var count = 0

        func increment() { count += 1 }
        func value() -> Int { count }
    }

    private actor ProbeGate {
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func waitUntilReleased() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if released { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
}
