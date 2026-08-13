import XCTest
@testable import MacOrchestrator

final class TerminalCommandTests: XCTestCase {
    func testDoctorParserSupportsReadOnlyJSONAndOneExplicitRepair() throws {
        XCTAssertEqual(
            try TerminalCommand.parseMaintenanceCommand(arguments: ["doctor"]),
            .doctor(json: false, repair: nil)
        )
        XCTAssertEqual(
            try TerminalCommand.parseMaintenanceCommand(arguments: ["doctor", "--json"]),
            .doctor(json: true, repair: nil)
        )
        XCTAssertEqual(
            try TerminalCommand.parseMaintenanceCommand(arguments: ["doctor", "--repair", "repairLaunchAgent"]),
            .doctor(json: false, repair: .repairLaunchAgent)
        )
    }

    func testDoctorParserRejectsAmbiguousOrUnknownMutationSyntax() {
        XCTAssertThrowsError(try TerminalCommand.parseMaintenanceCommand(arguments: ["doctor", "--json", "--repair", "retryMCPServer"]))
        XCTAssertThrowsError(try TerminalCommand.parseMaintenanceCommand(arguments: ["doctor", "retryMCPServer"]))
        XCTAssertThrowsError(try TerminalCommand.parseMaintenanceCommand(arguments: ["doctor", "--repair"]))
    }

    func testSupportBundleParserRequiresPreviewOrCreateAndBindsOutputToCreate() throws {
        XCTAssertEqual(
            try TerminalCommand.parseMaintenanceCommand(arguments: ["support-bundle", "--preview"]),
            .supportBundle(preview: true, output: nil)
        )
        XCTAssertEqual(
            try TerminalCommand.parseMaintenanceCommand(arguments: ["support-bundle", "--create", "--output", "/tmp/support.zip"]),
            .supportBundle(preview: false, output: "/tmp/support.zip")
        )
        XCTAssertThrowsError(try TerminalCommand.parseMaintenanceCommand(arguments: ["support-bundle"]))
        XCTAssertThrowsError(try TerminalCommand.parseMaintenanceCommand(arguments: ["support-bundle", "--preview", "--output", "/tmp/support.zip"]))
        XCTAssertThrowsError(try TerminalCommand.parseMaintenanceCommand(arguments: ["support-bundle", "--create", "--output"]))
    }

    func testUpdateCheckMapsNoStableUpdateToSuccessfulCurrentState() {
        let result = Phase3OperationCoordinator.mapUpdateCheckError(
            UpdateEngineError.noStableUpdate,
            currentVersion: "3.0.0"
        )

        XCTAssertEqual(result.state, .current(version: "3.0.0"))
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.message.contains("up to date"))
        XCTAssertFalse(result.message.contains("manifest"))
    }

    func testUpdateCheckStillFailsSafelyForAuthenticationOrNetworkErrors() {
        let result = Phase3OperationCoordinator.mapUpdateCheckError(
            UpdateEngineError.signatureRequired,
            currentVersion: "3.0.0"
        )

        XCTAssertEqual(result.state, .failed)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("failed safely"))
    }
}
