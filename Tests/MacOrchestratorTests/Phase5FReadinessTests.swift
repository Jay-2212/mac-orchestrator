import Foundation
import XCTest
@testable import MacOrchestrator

final class Phase5FReadinessTests: XCTestCase {
    func testFrozenControlInvocationUsesExplicitActionAndNoSecretFields() throws {
        let invocation = try MeridianIndexerInvocation(
            baseURL: URL(string: "https://core.example.test")!,
            stateURL: URL(fileURLWithPath: "/private/state/index.json"),
            scopes: [
                MeridianSourceScope(
                    scopeID: "scope-001",
                    rootPath: "/private/selected",
                    paths: ["notes"]
                )
            ],
            action: .index
        )

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: invocation.encoded()) as? [String: Any]
        )
        XCTAssertEqual(object["control_version"] as? String, "1.0.0")
        XCTAssertEqual(object["action"] as? String, "index")
        XCTAssertEqual(object["baseUrl"] as? String, "https://core.example.test")
        XCTAssertNotNil(object["statePath"] as? String)
        XCTAssertFalse(String(decoding: try invocation.encoded(), as: UTF8.self).contains("MERIDIAN_CORE_TOKEN"))
        XCTAssertFalse(String(decoding: try invocation.encoded(), as: UTF8.self).contains("Bearer"))
    }

    func testControlResultRejectsExitZeroWithoutTrustedFinalResult() {
        XCTAssertNil(
            MeridianIndexerControlResult.parse(
                line: #"{"control_version":"1.0.0","action":"index","status":"completed","exit_code":0,"counts":{"discovered":1,"committed":1}}"#
            )
        )

        let result = MeridianIndexerControlResult.parse(
            line: #"{"control_version":"1.0.0","action":"index","status":"completed","exit_code":0,"counts":{"discovered":1,"unchanged":0,"committed":1,"skipped":0,"failed":0,"cancelled":0,"reconciliation_required":0}}"#
        )
        XCTAssertEqual(result?.action, .index)
        XCTAssertTrue(result?.isSuccessful == true)
    }

    func testFrozenPreviewResultIsAcceptedWithoutRetainingPrivateScanFields() {
        let result = MeridianIndexerControlResult.parse(
            line: #"{"control_version":"1.0.0","action":"preview","status":"ready","counts":{"discovered":4,"supported":3,"skipped":1,"bytes":1200,"truncated":false},"skipped":{"unsupported":1},"scan":{"complete":true,"uncertain":false,"truncated":false},"exit_code":0}"#
        )

        XCTAssertEqual(result?.preview, MeridianPreviewSummary(
            discovered: 4,
            supported: 3,
            skipped: 1,
            bytes: 1200,
            truncated: false,
            complete: true,
            uncertain: false
        ))
        XCTAssertNil(MeridianIndexerControlResult.parse(
            line: #"{"control_version":"1.0.0","action":"preview","status":"ready","counts":{"discovered":1,"supported":1,"skipped":0,"bytes":4,"truncated":false},"scan":{"complete":true,"uncertain":false,"truncated":false},"document_content":"private"}"#
        ))
        let uncertain = MeridianIndexerControlResult.parse(
            line: #"{"control_version":"1.0.0","action":"preview","status":"uncertain","counts":{"discovered":1,"supported":0,"skipped":1,"bytes":0,"truncated":true},"scan":{"complete":false,"uncertain":true,"truncated":true},"exit_code":2}"#
        )
        XCTAssertEqual(uncertain?.status, "uncertain")
        XCTAssertFalse(uncertain?.isSuccessful == true)
    }

    func testControlResultRequiresActionSpecificShapes() {
        XCTAssertNil(MeridianIndexerControlResult.parse(
            line: #"{"control_version":"1.0.0","action":"delete-source","status":"completed","counts":{"matched":1,"deleted":1},"exit_code":0}"#
        ))
        XCTAssertNotNil(MeridianIndexerControlResult.parse(
            line: #"{"control_version":"1.0.0","action":"delete-source","status":"completed","counts":{"matched":1,"deleted":1,"failed":0},"exit_code":0}"#
        ))
        XCTAssertNil(MeridianIndexerControlResult.parse(
            line: #"{"control_version":"1.0.0","action":"delete-all","status":"completed","exit_code":0}"#
        ))
        XCTAssertNil(MeridianIndexerControlResult.parse(
            line: #"{"control_version":"1.0.0","action":"index","status":"completed","exit_code":true,"counts":{"discovered":0,"unchanged":0,"committed":0,"skipped":0,"failed":0,"cancelled":0,"reconciliation_required":0}}"#
        ))
        XCTAssertNotNil(MeridianIndexerControlResult.parse(
            line: #"{"control_version":"1.0.0","action":"delete-all","status":"completed","purged":true,"exit_code":0}"#
        ))
    }

    func testInvocationRejectsCredentialBearingOrQueryDeploymentURL() {
        XCTAssertThrowsError(try MeridianIndexerInvocation(
            baseURL: URL(string: "https://user:secret@core.example.test")!,
            stateURL: URL(fileURLWithPath: "/private/state/index.json"),
            scopes: [],
            action: .probe
        ))
        XCTAssertThrowsError(try MeridianIndexerInvocation(
            baseURL: URL(string: "https://core.example.test?token=secret")!,
            stateURL: URL(fileURLWithPath: "/private/state/index.json"),
            scopes: [],
            action: .probe
        ))
    }

    @MainActor
    func testSystemProbeParsesBoundedFinalResultWithTrailingNewline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase5f-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let toolURL = root.appendingPathComponent("indexer")
        try Data("tool".utf8).write(to: toolURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: toolURL.path)
        let digest = MaintenanceDigest.sha256(data: Data("tool".utf8))
        let launcher = ProbeLauncher(output: "{\"control_version\":\"1.0.0\",\"action\":\"probe\",\"status\":\"passed\",\"readiness\":{\"version\":\"ok\",\"diagnostics\":\"ok\",\"ingest\":\"ok\",\"search\":\"ok\",\"cleanup\":\"ok\"},\"exit_code\":0}\n")
        let probe = SystemMeridianReadinessProbe(launcher: launcher, timeout: 5)

        let receipt = await probe.probe(
            baseURL: URL(string: "https://core.example.test")!,
            stateURL: root.appendingPathComponent("state.json"),
            toolURL: toolURL,
            token: "core-token",
            currentToolDigest: digest
        )

        XCTAssertEqual(receipt.status, .passed)
        XCTAssertEqual(launcher.lastEnvironment["MERIDIAN_CORE_TOKEN"], "core-token")
        XCTAssertFalse(String(decoding: launcher.lastInput, as: UTF8.self).contains("core-token"))
    }

    func testReadinessRequiresEveryIndependentProof() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let digest = String(repeating: "a", count: 64)
        let complete = MeridianReadinessEvaluationInput(
            desired: true,
            enabled: true,
            deploymentURL: "https://core.example.test",
            tokenPresent: true,
            tool: MeridianToolReceipt(
                digest: digest,
                controlVersion: "1.0.0",
                trusted: true,
                installedAt: now
            ),
            currentToolDigest: digest,
            lastSuccessfulIndexAt: now,
            lastSuccessfulIndexDeploymentFingerprint: MeridianReadinessEvaluator.fingerprint(for: "https://core.example.test"),
            lastSuccessfulIndexToolDigest: digest,
            lastProbe: MeridianProbeReceipt(
                status: .passed,
                at: now,
                deploymentFingerprint: MeridianReadinessEvaluator.fingerprint(for: "https://core.example.test"),
                toolDigest: digest,
                apiVersion: "1.0.0",
                schemaVersion: 2
            ),
            now: now
        )

        XCTAssertTrue(MeridianReadinessEvaluator.evaluate(complete).ready)

        for changed in [
            complete.with(tokenPresent: false),
            complete.with(currentToolDigest: String(repeating: "b", count: 64)),
            complete.with(lastSuccessfulIndexAt: .some(nil)),
            complete.with(lastProbe: MeridianProbeReceipt(status: .failed, at: now, apiVersion: nil, schemaVersion: nil)),
            complete.with(deploymentURL: "https://other.example.test"),
        ] {
            XCTAssertFalse(MeridianReadinessEvaluator.evaluate(changed).ready)
        }
    }

    func testMeridianScheduleModesHaveRoadmapIntervalsAndManualHasNoCallback() {
        XCTAssertEqual(MeridianScheduleMode.manual.intervalMinutes, nil)
        XCTAssertEqual(MeridianScheduleMode.everySixHours.intervalMinutes, 360)
        XCTAssertEqual(MeridianScheduleMode.daily.intervalMinutes, 1_440)
        XCTAssertEqual(MeridianIndexerConfiguration().scheduleMode, .everySixHours)
    }
}

private extension MeridianReadinessEvaluationInput {
    func with(
        desired: Bool? = nil,
        enabled: Bool? = nil,
        deploymentURL: String? = nil,
        tokenPresent: Bool? = nil,
        tool: MeridianToolReceipt? = nil,
        currentToolDigest: String? = nil,
        lastSuccessfulIndexAt: Date?? = nil,
        lastProbe: MeridianProbeReceipt? = nil
    ) -> MeridianReadinessEvaluationInput {
        MeridianReadinessEvaluationInput(
            desired: desired ?? self.desired,
            enabled: enabled ?? self.enabled,
            deploymentURL: deploymentURL ?? self.deploymentURL,
            tokenPresent: tokenPresent ?? self.tokenPresent,
            tool: tool ?? self.tool,
            currentToolDigest: currentToolDigest ?? self.currentToolDigest,
            lastSuccessfulIndexAt: lastSuccessfulIndexAt ?? self.lastSuccessfulIndexAt,
            lastSuccessfulIndexDeploymentFingerprint: self.lastSuccessfulIndexDeploymentFingerprint,
            lastSuccessfulIndexToolDigest: self.lastSuccessfulIndexToolDigest,
            lastProbe: lastProbe ?? self.lastProbe,
            now: now
        )
    }
}

@MainActor
private final class ProbeLauncher: MeridianIndexerProcessLaunching {
    let output: String
    var lastEnvironment: [String: String] = [:]
    var lastInput = Data()

    init(output: String) {
        self.output = output
    }

    func launch(
        executableURL: URL,
        environment: [String: String],
        input: Data,
        output: @escaping (Data) -> Void,
        termination: @escaping (Int32) -> Void
    ) throws -> any MeridianIndexerProcessHandle {
        lastEnvironment = environment
        lastInput = input
        output(Data(self.output.utf8))
        termination(0)
        return ProbeHandle()
    }
}

@MainActor
private final class ProbeHandle: MeridianIndexerProcessHandle {
    var isRunning = false
    func terminate() {}
}
