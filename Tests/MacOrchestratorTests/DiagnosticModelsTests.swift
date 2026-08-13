import Foundation
import XCTest
@testable import MacOrchestrator

final class DiagnosticModelsTests: XCTestCase {
    func testDiagnosticStatusUsesStableLowercaseWireValues() throws {
        XCTAssertEqual(DiagnosticStatus.pass.rawValue, "pass")
        XCTAssertEqual(DiagnosticStatus.warn.rawValue, "warn")
        XCTAssertEqual(DiagnosticStatus.fail.rawValue, "fail")
        XCTAssertEqual(DiagnosticStatus.skip.rawValue, "skip")
    }

    func testDiagnosticResultRoundTripsOneBoundedRepair() throws {
        let result = DiagnosticResult(
            id: "config.primary",
            title: "Configuration",
            status: .warn,
            reason: "The primary is malformed; a valid backup is available.",
            repair: RepairActionDescriptor(
                id: .restoreConfigurationBackup,
                title: "Restore configuration backup",
                guidance: "Review and explicitly restore the validated backup."
            )
        )

        let decoded = try JSONDecoder().decode(
            DiagnosticResult.self,
            from: JSONEncoder().encode(result)
        )

        XCTAssertEqual(decoded, result)
    }

    func testDoctorReportSummaryAndEncodingAreDeterministic() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let results = [
            DiagnosticResult(id: "z", title: "Z", status: .skip, reason: "not applicable"),
            DiagnosticResult(id: "a", title: "A", status: .pass, reason: "verified"),
            DiagnosticResult(id: "b", title: "B", status: .fail, reason: "missing")
        ]
        let report = DoctorReport(generatedAt: date, results: results)

        XCTAssertEqual(report.reportSchemaVersion, 1)
        XCTAssertEqual(report.generatedAt, date)
        XCTAssertEqual(report.results, results)
        XCTAssertEqual(report.summary.pass, 1)
        XCTAssertEqual(report.summary.fail, 1)
        XCTAssertEqual(report.summary.skip, 1)
        XCTAssertEqual(report.summary.warn, 0)

        let encoded = try report.encodedJSON()
        XCTAssertEqual(
            String(data: encoded, encoding: .utf8),
            "{\"generatedAt\":\"2023-11-14T22:13:20Z\",\"reportSchemaVersion\":1,\"results\":[{\"id\":\"z\",\"reason\":\"not applicable\",\"repair\":null,\"status\":\"skip\",\"title\":\"Z\"},{\"id\":\"a\",\"reason\":\"verified\",\"repair\":null,\"status\":\"pass\",\"title\":\"A\"},{\"id\":\"b\",\"reason\":\"missing\",\"repair\":null,\"status\":\"fail\",\"title\":\"B\"}],\"summary\":{\"fail\":1,\"pass\":1,\"skip\":1,\"warn\":0}}"
        )

        let decoded = try decodeReport(encoded)
        XCTAssertEqual(decoded.reportSchemaVersion, report.reportSchemaVersion)
        XCTAssertEqual(decoded.generatedAt, report.generatedAt)
        XCTAssertEqual(decoded.results, report.results)
        XCTAssertEqual(decoded.summary, report.summary)
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(try decoded.encodedJSON(), encoded)
    }

    func testDoctorReportDecodingRejectsSummaryThatContradictsResults() throws {
        let report = DoctorReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            results: [
                DiagnosticResult(id: "a", title: "A", status: .pass, reason: "verified")
            ]
        )
        var payload = try jsonObject(for: report)
        payload["summary"] = ["fail": 0, "pass": 0, "skip": 0, "warn": 1]

        XCTAssertThrowsError(try decodeReport(try JSONSerialization.data(withJSONObject: payload)))
    }

    func testDoctorReportDecodingRejectsUnsupportedSchemaVersion() throws {
        let report = DoctorReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            results: []
        )
        var payload = try jsonObject(for: report)
        payload["reportSchemaVersion"] = 2

        XCTAssertThrowsError(try decodeReport(try JSONSerialization.data(withJSONObject: payload)))
    }

    func testRemoteAuthenticatedFactsClassifyEachProbeOutcome() {
        let rejected = RemoteAuthenticatedMCPFacts(
            probeAvailable: true,
            probeRun: true,
            authenticationSucceeded: false
        )
        XCTAssertEqual(rejected.state, .authenticationRejected)

        let initializeFailed = RemoteAuthenticatedMCPFacts(
            probeAvailable: true,
            probeRun: true,
            authenticationSucceeded: true,
            initializeSucceeded: false,
            sessionEstablished: false
        )
        XCTAssertEqual(initializeFailed.state, .initializeSessionFailed)

        let inventoryMismatch = RemoteAuthenticatedMCPFacts(
            probeAvailable: true,
            probeRun: true,
            authenticationSucceeded: true,
            initializeSucceeded: true,
            sessionEstablished: true,
            inventoryChecked: true,
            expectedTools: ["get_session_state"],
            exposedTools: ["describe"]
        )
        XCTAssertEqual(inventoryMismatch.state, .inventoryMismatch)

        let safeCallFailed = RemoteAuthenticatedMCPFacts(
            probeAvailable: true,
            probeRun: true,
            authenticationSucceeded: true,
            initializeSucceeded: true,
            sessionEstablished: true,
            inventoryChecked: true,
            expectedTools: ["describe"],
            exposedTools: ["describe"],
            safeCallChecked: true,
            safeCallSucceeded: false
        )
        XCTAssertEqual(safeCallFailed.state, .safeCallFailed)

        let ready = RemoteAuthenticatedMCPFacts(
            probeAvailable: true,
            probeRun: true,
            authenticationSucceeded: true,
            initializeSucceeded: true,
            sessionEstablished: true,
            inventoryChecked: true,
            expectedTools: ["describe"],
            exposedTools: ["describe"],
            safeCallChecked: true,
            safeCallSucceeded: true,
            clientHandoff: .changed
        )
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.clientHandoff, .changed)

        XCTAssertEqual(RemoteAuthenticatedMCPFacts().state, .notRun)
    }

    func testRemoteFactsSerializeOnlyTypedNonsecretEvidence() throws {
        let token = "capability-secret-123456789"
        let url = "https://assigned.ngrok-free.app/capability-secret-123456789/mcp"
        let facts = RemoteConnectorFacts(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            endpointAvailable: true,
            endpointCount: 1,
            ownershipMarkerPresent: true,
            endpointState: .established,
            authenticatedReadiness: RemoteAuthenticatedMCPFacts(
                probeAvailable: true,
                probeRun: true,
                authenticationSucceeded: true,
                initializeSucceeded: true,
                sessionEstablished: true,
                inventoryChecked: true,
                expectedTools: ["describe"],
                exposedTools: ["describe"],
                safeCallChecked: true,
                safeCallSucceeded: true
            )
        )

        let serialized = String(decoding: try JSONEncoder().encode(facts), as: UTF8.self)
        XCTAssertFalse(serialized.contains(token))
        XCTAssertFalse(serialized.contains(url))
        XCTAssertFalse(serialized.contains("https://"))
        XCTAssertTrue(serialized.contains("established"))
        XCTAssertTrue(serialized.contains("ready"))
    }

    func testDoctorReportSerializationRedactsTokenBearingConnectorURLs() throws {
        let token = "capability-secret-123456789"
        let url = "https://assigned.ngrok-free.app/capability-secret-123456789/mcp"
        let report = DoctorReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            results: [DiagnosticResult(
                id: "remote.endpoint",
                title: "Remote endpoint",
                status: .pass,
                reason: "observed \(url)",
                repair: RepairActionDescriptor(
                    id: .reconfigureRemoteClients,
                    title: "Use \(url)",
                    guidance: "Paste \(url) into the client."
                )
            )]
        )

        let serialized = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(serialized.contains(token))
        XCTAssertFalse(serialized.contains(url))
        XCTAssertTrue(serialized.contains("<redacted>"))
    }

    private func decodeReport(_ data: Data) throws -> DoctorReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DoctorReport.self, from: data)
    }

    private func jsonObject(for report: DoctorReport) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: report.encodedJSON()) as? [String: Any]
        )
    }
}
