import Foundation
import Testing
@testable import MacOrchestrator

struct SupervisorPolicyTests {
    @Test
    func firstFiveFailuresUseExistingExponentialRetryDelays() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(
            SupervisorRetryPolicy.decision(failures: [], now: now)
                == .retry(failures: [now], delay: 1)
        )
        #expect(
            SupervisorRetryPolicy.decision(failures: [now], now: now)
                == .retry(failures: [now, now], delay: 2)
        )
        #expect(
            SupervisorRetryPolicy.decision(failures: [now, now], now: now)
                == .retry(failures: [now, now, now], delay: 4)
        )
        #expect(
            SupervisorRetryPolicy.decision(
                failures: [now, now, now],
                now: now
            ) == .retry(failures: [now, now, now, now], delay: 8)
        )
        #expect(
            SupervisorRetryPolicy.decision(
                failures: [now, now, now, now],
                now: now
            ) == .retry(failures: [now, now, now, now, now], delay: 16)
        )
    }

    @Test
    func sixthFailureWithinWindowStopsRetrying() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let failures = Array(repeating: now, count: 5)

        #expect(
            SupervisorRetryPolicy.decision(failures: failures, now: now)
                == .circuitOpen(failures: Array(repeating: now, count: 6))
        )
    }

    @Test
    func failuresOlderThanWindowDoNotTripCircuit() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oldFailures = Array(
            repeating: now.addingTimeInterval(-SupervisorRetryPolicy.failureWindow - 1),
            count: 5
        )

        #expect(
            SupervisorRetryPolicy.decision(failures: oldFailures, now: now)
                == .retry(failures: [now], delay: 1)
        )
    }

    @Test
    func ownershipMarkersMatchOnlyTheirComponentAndOwner() {
        #expect(
            ProcessOwnership.marker(for: .server, ownerID: "owner-123")
                == "--managed-owner owner-123"
        )
        #expect(
            ProcessOwnership.marker(for: .tunnel, ownerID: "owner-123")
                == "mac-orchestrator-owner=owner-123"
        )
        #expect(
            ProcessOwnership.matches(
                commandLine: "python automac_mcp.py --managed-owner owner-123",
                component: .server,
                ownerID: "owner-123"
            )
        )
        #expect(
            ProcessOwnership.matches(
                commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-123",
                component: .tunnel,
                ownerID: "owner-123"
            )
        )
        #expect(!ProcessOwnership.matches(
            commandLine: "python automac_mcp.py --managed-owner owner-456",
            component: .server,
            ownerID: "owner-123"
        ))
        #expect(!ProcessOwnership.matches(
            commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-123",
            component: .server,
            ownerID: "owner-123"
        ))
    }

    @Test
    func connectorURLUsesOnlyHTTPSAndAppendsCapabilityPath() {
        #expect(
            ConnectorURLBuilder.make(
                publicURL: "https://example.ngrok.app",
                capabilityToken: "test-token"
            )?.absoluteString == "https://example.ngrok.app/test-token/mcp"
        )
        #expect(
            ConnectorURLBuilder.make(
                publicURL: "http://example.ngrok.app",
                capabilityToken: "test-token"
            ) == nil
        )
    }

    @Test
    func healthySnapshotRequiresRunningServerAndAllowsStoppedTunnel() {
        var snapshot = ServiceSnapshot(server: .running, tunnel: .stopped)
        #expect(snapshot.isHealthy)

        snapshot.tunnel = .starting
        #expect(!snapshot.isHealthy)
    }

    @Test
    func ownedProcessStateRoundTripsWithoutKeychainOrFilesystem() throws {
        let state = OwnedProcessState(ownerID: "owner-123", serverPID: 12, tunnelPID: nil)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(OwnedProcessState.self, from: data)

        #expect(decoded.ownerID == "owner-123")
        #expect(decoded.serverPID == 12)
        #expect(decoded.tunnelPID == nil)
    }
}
