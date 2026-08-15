import XCTest
@testable import MacOrchestrator

final class MenuControllerTests: XCTestCase {
    @MainActor
    func testRuntimeStatusTitlesExposeProfileReadinessErrorAndClientRefresh() {
        let snapshot = ServiceSnapshot(
            server: .running,
            tunnel: .stopped,
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
            "Meridian indexing: Disabled",
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

    @MainActor
    func testPrimaryRepairSelectionUsesDoctorDescriptorAndDeterministicPriority() {
        let local = RepairActionDescriptor(
            id: .retryMCPServer,
            title: "Retry local MCP server",
            guidance: "Retry local"
        )
        let remote = RepairActionDescriptor(
            id: .retryRemoteConnector,
            title: "Retry remote connector",
            guidance: "Retry remote"
        )
        let report = DoctorReport(generatedAt: Date(timeIntervalSince1970: 1), results: [
            DiagnosticResult(
                id: "remote.endpoint",
                title: "Remote endpoint",
                status: .fail,
                reason: "remote failed",
                repair: remote
            ),
            DiagnosticResult(
                id: "mcp.liveness",
                title: "Local MCP liveness",
                status: .fail,
                reason: "local failed",
                repair: local
            ),
            DiagnosticResult(
                id: "configuration.backup",
                title: "Configuration backup",
                status: .warn,
                reason: "backup warning",
                repair: remote
            ),
        ])

        XCTAssertEqual(report.primaryRepairDescriptor(), local)
    }

    @MainActor
    func testDoctorFeedbackMapsTypedResultToCompactNativeSummary() {
        let report = DoctorReport(generatedAt: Date(timeIntervalSince1970: 1), results: [
            DiagnosticResult(id: "one", title: "One", status: .pass, reason: "verified"),
            DiagnosticResult(id: "two", title: "Two", status: .warn, reason: "needs attention"),
            DiagnosticResult(id: "three", title: "Three", status: .fail, reason: "failed"),
            DiagnosticResult(id: "four", title: "Four", status: .skip, reason: "not applicable"),
        ])
        let result = Phase3DoctorOperationResult(
            report: report,
            primaryRepair: RepairActionDescriptor(
                id: .retryMCPServer,
                title: "Retry local MCP server",
                guidance: "Retry the managed local MCP lifecycle."
            )
        )

        let feedback = MenuController.doctorFeedback(for: result)

        XCTAssertTrue(feedback.contains("Overall: FAIL"))
        XCTAssertTrue(feedback.contains("PASS 1  WARN 1  FAIL 1  SKIP 1"))
        XCTAssertTrue(feedback.contains("Primary bounded repair: Retry local MCP server"))
        XCTAssertFalse(feedback.contains("connector-secret"))
    }

    @MainActor
    func testUpdateAndRemovalFeedbackExposeSafeUserStates() {
        let update = Phase3UpdateOperationResult(
            state: .current(version: "3.0.0"),
            message: "Mac Orchestrator is up to date (version 3.0.0)."
        )
        XCTAssertEqual(MenuController.updateFeedback(for: update), "Mac Orchestrator is up to date (version 3.0.0).")

        let plan = RemovalPlan(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            entries: [
                RemovalPlanEntry(kind: .configuration, relativePath: "config.json", intent: .retain, reason: nil),
                RemovalPlanEntry(kind: .logsAndSupport, relativePath: "~/Library/Logs/Mac Orchestrator", intent: .remove, reason: nil),
            ],
            keychainItemsToDelete: [],
            providerResourcesUntouched: true,
            servicesRemainQuiesced: false
        )
        let feedback = MenuController.removalPlanFeedback(
            for: Phase3RemovalPlanOperationResult(plan: plan)
        )
        XCTAssertTrue(feedback.contains("Items to remove:"))
        XCTAssertTrue(feedback.contains("Items retained:"))
        XCTAssertTrue(feedback.contains("Credentials: preserved by default"))
        XCTAssertTrue(feedback.contains("Provider-side resources: untouched"))
        XCTAssertTrue(feedback.contains("Viewing this plan performs no uninstall."))
    }

    @MainActor
    func testSupportPreviewFeedbackStatesCategoriesExclusionsRedactionAndNoCollection() {
        let plan = SupportBundlePlan(
            planIdentifier: "support-v1-test",
            generatedAt: Date(timeIntervalSince1970: 1),
            entries: [SupportBundleEntryPlan(
                sourceID: "phase3",
                logicalID: "logs",
                archivePath: "logs/bounded.log",
                category: "logs",
                reason: "bounded product log",
                expectedRedaction: "canonical redaction"
            )],
            excludedSensitiveCategories: ["credentials", "connector-url"],
            redactionSummary: SupportBundleRedactionSummary()
        )

        let feedback = MenuController.supportPreviewFeedback(
            for: Phase3SupportBundlePreviewResult(plan: plan, collectedFileCount: 0)
        )

        XCTAssertTrue(feedback.contains("Included categories: logs"))
        XCTAssertTrue(feedback.contains("Explicitly excluded: connector-url, credentials"))
        XCTAssertTrue(feedback.contains("exact-secret-replacement"))
        XCTAssertTrue(feedback.contains("Preview collected files: 0"))
    }
}
