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

        XCTAssertEqual(report.summary.pass, 1)
        XCTAssertEqual(report.summary.fail, 1)
        XCTAssertEqual(report.summary.skip, 1)
        XCTAssertEqual(report.summary.warn, 0)
        XCTAssertEqual(
            try report.encodedJSON(),
            try DoctorReport(generatedAt: date, results: results).encodedJSON()
        )
    }
}
