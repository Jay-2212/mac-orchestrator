import XCTest
@testable import MacOrchestrator

final class MenuControllerTests: XCTestCase {
    @MainActor
    func testRuntimeStatusTitlesExposeProfileReadinessErrorAndClientRefresh() {
        let snapshot = ServiceSnapshot(
            server: .running,
            tunnel: .stopped,
            connectorURL: nil,
            error: "Configuration could not be loaded",
            controlProfile: .full,
            readyCapabilityCount: 7,
            totalCapabilityCount: 11,
            clientRefreshRequired: true
        )

        XCTAssertEqual(MenuController.runtimeStatusTitles(for: snapshot), [
            "Readiness: Needs attention",
            "Local automation: Running",
            "Optional remote access: Optional and disabled",
            "Profile: Full Control",
            "Capabilities ready: 7/11",
            "Error: Configuration could not be loaded",
            "MCP client refresh/reconnection required",
        ])
    }

    @MainActor
    func testRuntimeStatusTitlesUseNontechnicalReadinessAndRemoteLanguage() {
        let snapshot = ServiceSnapshot(
            server: .running,
            tunnel: .running,
            productReadiness: .ready
        )

        XCTAssertEqual(
            MenuController.runtimeStatusTitles(for: snapshot).prefix(3),
            ["Readiness: Ready", "Local automation: Running", "Optional remote access: Ready"]
        )
    }

    @MainActor
    func testRuntimeStatusTitlesExplainPendingPermissionGuidance() {
        var snapshot = ServiceSnapshot(
            server: .running,
            tunnel: .stopped,
            connectorURL: nil,
            error: nil,
            controlProfile: .guided,
            readyCapabilityCount: 2,
            totalCapabilityCount: 11,
            clientRefreshRequired: false
        )
        snapshot.pendingPermissions = ["Accessibility", "Screen Recording or OCR payload"]

        XCTAssertTrue(
            MenuController.runtimeStatusTitles(for: snapshot).contains(
                "Permissions pending: Accessibility, Screen Recording or OCR payload"
            )
        )
    }
}
