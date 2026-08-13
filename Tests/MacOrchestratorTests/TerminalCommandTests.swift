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
}
