import Foundation
import XCTest
@testable import MacOrchestrator

final class SupervisorPolicyTests: XCTestCase {
    func testFirstFiveFailuresUseExistingExponentialRetryDelays() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(
            SupervisorRetryPolicy.decision(failures: [], now: now)
                == .retry(failures: [now], delay: 1)
        )
        XCTAssertTrue(
            SupervisorRetryPolicy.decision(failures: [now], now: now)
                == .retry(failures: [now, now], delay: 2)
        )
        XCTAssertTrue(
            SupervisorRetryPolicy.decision(failures: [now, now], now: now)
                == .retry(failures: [now, now, now], delay: 4)
        )
        XCTAssertTrue(
            SupervisorRetryPolicy.decision(
                failures: [now, now, now],
                now: now
            ) == .retry(failures: [now, now, now, now], delay: 8)
        )
        XCTAssertTrue(
            SupervisorRetryPolicy.decision(
                failures: [now, now, now, now],
                now: now
            ) == .retry(failures: [now, now, now, now, now], delay: 16)
        )
    }

    func testSixthFailureWithinWindowStopsRetrying() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let failures = Array(repeating: now, count: 5)

        XCTAssertTrue(
            SupervisorRetryPolicy.decision(failures: failures, now: now)
                == .circuitOpen(failures: Array(repeating: now, count: 6))
        )
    }

    func testFailuresOlderThanWindowDoNotTripCircuit() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oldFailures = Array(
            repeating: now.addingTimeInterval(-SupervisorRetryPolicy.failureWindow - 1),
            count: 5
        )

        XCTAssertTrue(
            SupervisorRetryPolicy.decision(failures: oldFailures, now: now)
                == .retry(failures: [now], delay: 1)
        )
    }

    func testOwnershipMarkersMatchOnlyTheirComponentAndOwner() {
        XCTAssertEqual(
            ProcessOwnership.marker(for: .server, ownerID: "owner-123"),
            "--managed-owner owner-123"
        )
        XCTAssertEqual(
            ProcessOwnership.marker(for: .tunnel, ownerID: "owner-123"),
            "mac-orchestrator-owner=owner-123"
        )
        XCTAssertTrue(
            ProcessOwnership.matches(
                commandLine: "python automac_mcp.py --managed-owner owner-123",
                component: .server,
                ownerID: "owner-123"
            )
        )
        XCTAssertTrue(
            ProcessOwnership.matches(
                commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-123",
                component: .tunnel,
                ownerID: "owner-123"
            )
        )
        XCTAssertFalse(ProcessOwnership.matches(
            commandLine: "python automac_mcp.py --managed-owner owner-456",
            component: .server,
            ownerID: "owner-123"
        ))
        XCTAssertFalse(ProcessOwnership.matches(
            commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-123",
            component: .server,
            ownerID: "owner-123"
        ))
        XCTAssertFalse(ProcessOwnership.matches(
            commandLine: "python automac_mcp.py --managed-owner owner-1234",
            component: .server,
            ownerID: "owner-123"
        ))
        XCTAssertFalse(ProcessOwnership.matches(
            commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-1234",
            component: .tunnel,
            ownerID: "owner-123"
        ))
    }

    func testConnectorURLUsesOnlyHTTPSAndAppendsCapabilityPath() {
        XCTAssertEqual(
            ConnectorURLBuilder.make(
                publicURL: "https://example.ngrok.app",
                capabilityToken: "test-token"
            )?.absoluteString,
            "https://example.ngrok.app/test-token/mcp"
        )
        XCTAssertNil(
            ConnectorURLBuilder.make(
                publicURL: "http://example.ngrok.app",
                capabilityToken: "test-token"
            )
        )
    }

    func testHealthySnapshotRequiresRunningServerAndAllowsStoppedTunnel() {
        var snapshot = ServiceSnapshot(server: .running, tunnel: .stopped)
        XCTAssertTrue(snapshot.isHealthy)

        snapshot.tunnel = .starting
        XCTAssertFalse(snapshot.isHealthy)
    }

    func testOwnedProcessStateRoundTripsWithoutKeychainOrFilesystem() throws {
        let state = OwnedProcessState(ownerID: "owner-123", serverPID: 12, tunnelPID: nil)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(OwnedProcessState.self, from: data)

        XCTAssertEqual(decoded.ownerID, "owner-123")
        XCTAssertEqual(decoded.serverPID, 12)
        XCTAssertNil(decoded.tunnelPID)
    }
}
