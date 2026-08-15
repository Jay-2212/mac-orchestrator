import Foundation
import XCTest
@testable import MacOrchestrator

final class MeridianIndexerTests: XCTestCase {
    func testConfigurationRequiresExplicitSafeScopesAndRoundTrips() throws {
        let configuration = MeridianIndexerConfiguration(
            enabled: true,
            intervalMinutes: 30,
            scopes: [
                MeridianSourceScope(
                    scopeID: "scope-notes",
                    rootPath: "/Users/example/Notes",
                    paths: ["work", "notes.md"]
                )
            ]
        )

        let validated = try configuration.validated()
        let data = try JSONEncoder().encode(validated)
        let decoded = try JSONDecoder().decode(MeridianIndexerConfiguration.self, from: data)

        XCTAssertEqual(decoded, validated)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("scope-notes"))
    }

    func testConfigurationRejectsDefaultScanAndUnsafeSelections() {
        let invalidScopes = [
            MeridianSourceScope(scopeID: "scope", rootPath: "/Users/example", paths: []),
            MeridianSourceScope(scopeID: "scope", rootPath: "~/Documents", paths: ["notes"]),
            MeridianSourceScope(scopeID: "scope", rootPath: "/Users/example", paths: ["../notes"]),
            MeridianSourceScope(scopeID: "scope", rootPath: "/Users/example", paths: ["file:///Users/example/notes"]),
            MeridianSourceScope(scopeID: "scope", rootPath: "/Users/example", paths: ["notes\\private"]),
        ]

        for scope in invalidScopes {
            let configuration = MeridianIndexerConfiguration(
                enabled: true,
                intervalMinutes: 30,
                scopes: [scope]
            )
            XCTAssertThrowsError(try configuration.validated())
        }
    }

    func testInvocationUsesMeridianShapeAndKeepsMacRootLocalToInvocation() throws {
        let invocation = try MeridianIndexerInvocation(
            baseURL: URL(string: "https://meridian.example")!,
            stateURL: URL(fileURLWithPath: "/Users/example/Library/Application Support/Mac Orchestrator/meridian/state.json"),
            scopes: [
                MeridianSourceScope(scopeID: "scope", rootPath: "/Users/example/Notes", paths: ["notes.md"])
            ],
            action: .rebuild
        )

        let data = try invocation.encoded()
        let json = String(decoding: data, as: UTF8.self)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["baseUrl"] as? String, "https://meridian.example")
        let source = try XCTUnwrap((object["sources"] as? [[String: Any]])?.first)
        XCTAssertEqual(source["sourceId"] as? String, "scope")
        XCTAssertEqual(source["rootPath"] as? String, "/Users/example/Notes")
        XCTAssertEqual(object["action"] as? String, "rebuild")
        XCTAssertFalse(json.contains("MERIDIAN_CORE_TOKEN"))
        XCTAssertFalse(json.contains("Bearer"))
    }

    func testProgressParserDropsPathsUnknownFieldsAndOversizedLines() throws {
        let allowed = try XCTUnwrap(
            MeridianIndexerProgressEvent.parse(
                line: #"{"protocol_version":"1.0.0","type":"source_committed","source_id":"s-1","relative_path":"notes.md","generation":"g-1"}"#
            )
        )
        XCTAssertEqual(allowed.type, "source_committed")

        XCTAssertNil(
            MeridianIndexerProgressEvent.parse(
                line: #"{"protocol_version":"1.0.0","type":"source_failed","source_id":"s-1","relative_path":"/Users/example/private.txt","generation":"g-1","code":"remote_failed"}"#
            )
        )
        XCTAssertNil(
            MeridianIndexerProgressEvent.parse(
                line: #"{"protocol_version":"1.0.0","type":"source_committed","source_id":"s-1","relative_path":"notes.md","generation":"g-1","raw_body":"secret"}"#
            )
        )
        XCTAssertNil(MeridianIndexerProgressEvent.parse(line: String(repeating: "x", count: 17_000)))
        XCTAssertEqual(
            MeridianIndexerProgressEvent.parse(
                line: #"{"protocol_version":"1.0.0","type":"run_finished","status":"partial_failure","counts":{"discovered":2,"unchanged":0,"committed":1,"skipped":0,"failed":1,"cancelled":0,"reconciliation_required":0}}"#
            )?.status,
            "partial_failure"
        )
        XCTAssertNil(MeridianIndexerProgressEvent.parse(line: #"{"type":"error","code":"remote_url_invalid"}"#))
        XCTAssertNil(MeridianIndexerProgressEvent.parse(line: #"{"protocol_version":"1.0.0","type":"run_finished","status":"unknown","counts":{"discovered":0,"unchanged":0,"committed":0,"skipped":0,"failed":0,"cancelled":0,"reconciliation_required":0}}"#))
        XCTAssertNil(MeridianIndexerProgressEvent.parse(line: #"{"protocol_version":"1.0.0","type":"run_finished","status":"completed","counts":{"discovered":1,"unchanged":1,"committed":1,"skipped":0,"failed":0,"cancelled":0,"reconciliation_required":0}}"#))
        XCTAssertNil(MeridianIndexerProgressEvent.parse(line: #"{"protocol_version":"1.0.0","type":"run_finished","status":null,"counts":{"discovered":0,"unchanged":0,"committed":0,"skipped":0,"failed":0,"cancelled":0,"reconciliation_required":0}}"#))
        XCTAssertNil(MeridianIndexerProgressEvent.parse(line: #"{"protocol_version":"1.0.0","type":"run_finished","status":"completed","counts":{"discovered":0,"unchanged":0,"committed":0,"skipped":0,"failed":0,"cancelled":0,"reconciliation_required":0,"extra":0}}"#))
    }

    func testOptionalToolInstallRejectsBadDigestWithoutReplacingKnownGood() throws {
        let directory = try temporaryDirectory()
        let installer = MeridianIndexerToolInstaller(rootURL: directory)
        let current = directory.appendingPathComponent("indexer")
        try Data("known-good".utf8).write(to: current)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
        let candidate = directory.appendingPathComponent("candidate")
        try Data("candidate".utf8).write(to: candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)

        XCTAssertThrowsError(
            try installer.install(candidateURL: candidate, expectedSHA256: String(repeating: "a", count: 64))
        )
        XCTAssertEqual(try Data(contentsOf: current), Data("known-good".utf8))
    }

    func testRunControllerRejectsOverlapAndSeparatesCancellationFromFailure() throws {
        let controller = MeridianIndexerRunController()

        XCTAssertEqual(controller.beginRun(), .started)
        XCTAssertEqual(controller.beginRun(), .alreadyRunning)
        controller.cancelRequested()
        XCTAssertTrue(controller.isCancellationRequested)
        controller.finish(status: .cancelled, exitCode: 0)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.lastStatus, .cancelled)
    }

    @MainActor
    func testRoadmapSchedulerUsesSixHoursAndRejectsStaleCallbacks() throws {
        let directory = try temporaryDirectory()
        let toolURL = directory.appendingPathComponent("meridian/indexer")
        try FileManager.default.createDirectory(at: toolURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: toolURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: toolURL.path)

        let start = Date(timeIntervalSince1970: 100)
        let scheduler = TestLifecycleScheduler(start: start)
        let launcher = FakeMeridianIndexerLauncher()
        let coordinator = MeridianIndexerCoordinator(scheduler: scheduler, launcher: launcher, supportDirectory: directory)
        var configuration = AppConfiguration.fresh(ownerID: "owner")
        configuration.desiredCapabilities["meridian.search"] = true
        configuration.integration.meridianDeploymentURL = "https://meridian.example"
        configuration.integration.meridianIndexer = MeridianIndexerConfiguration(
            enabled: true,
            scheduleMode: .everySixHours,
            scopes: [MeridianSourceScope(scopeID: "scope", rootPath: "/Users/example/Notes", paths: ["notes.md"])]
        )
        let contract = try makeContract(configuration: configuration, token: "core-token")

        coordinator.reconcile(configuration: configuration, contract: contract)
        XCTAssertEqual(coordinator.snapshot.nextRunAt, start.addingTimeInterval(6 * 60 * 60))
        XCTAssertEqual(launcher.launchCount, 0)

        let stale = try XCTUnwrap(scheduler.pendingHandles.first)
        coordinator.stop()
        scheduler.fireIgnoringCancellation(stale)
        XCTAssertEqual(launcher.launchCount, 0)
    }

    @MainActor
    func testWakeRunsOneMissedScheduledExecutionWithoutCatchUpStorm() throws {
        let directory = try temporaryDirectory()
        let toolURL = directory.appendingPathComponent("meridian/indexer")
        try FileManager.default.createDirectory(at: toolURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: toolURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: toolURL.path)

        let start = Date(timeIntervalSince1970: 100)
        let scheduler = TestLifecycleScheduler(start: start)
        let launcher = FakeMeridianIndexerLauncher()
        let coordinator = MeridianIndexerCoordinator(scheduler: scheduler, launcher: launcher, supportDirectory: directory)
        var configuration = AppConfiguration.fresh(ownerID: "owner")
        configuration.desiredCapabilities["meridian.search"] = true
        configuration.integration.meridianDeploymentURL = "https://meridian.example"
        configuration.integration.meridianIndexer = MeridianIndexerConfiguration(
            enabled: true,
            scheduleMode: .everySixHours,
            scopes: [MeridianSourceScope(scopeID: "scope", rootPath: "/Users/example/Notes", paths: ["notes.md"])]
        )
        let contract = try makeContract(configuration: configuration, token: "core-token")

        coordinator.reconcile(configuration: configuration, contract: contract)
        let scheduled = try XCTUnwrap(scheduler.pendingHandles.first)
        scheduler.cancel(scheduled)
        scheduler.advance(to: start.addingTimeInterval(7 * 60 * 60))
        coordinator.handleWake()
        scheduler.fire(try XCTUnwrap(scheduler.pendingHandles.first))
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(coordinator.snapshot.status, .running)
    }

    @MainActor
    func testCoordinatorOwnsOneRunAndCancellationDoesNotOverlap() throws {
        let directory = try temporaryDirectory()
        let toolURL = directory.appendingPathComponent("meridian/indexer")
        try FileManager.default.createDirectory(at: toolURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: toolURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: toolURL.path)

        let scheduler = TestLifecycleScheduler(start: Date(timeIntervalSince1970: 100))
        let launcher = FakeMeridianIndexerLauncher()
        let coordinator = MeridianIndexerCoordinator(
            scheduler: scheduler,
            launcher: launcher,
            supportDirectory: directory
        )
        var configuration = AppConfiguration.fresh(ownerID: "owner")
        configuration.integration.meridianDeploymentURL = "https://meridian.example"
        configuration.desiredCapabilities["meridian.search"] = true
        configuration.integration.meridianIndexer = MeridianIndexerConfiguration(
            enabled: true,
            scheduleMode: .manual,
            scopes: [MeridianSourceScope(scopeID: "scope", rootPath: "/Users/example/Notes", paths: ["notes.md"])]
        )
        let contract = try makeContract(configuration: configuration, token: "core-token")

        coordinator.reconcile(configuration: configuration, contract: contract)
        coordinator.scanNow()
        scheduler.fire(try XCTUnwrap(scheduler.pendingHandles.first))
        XCTAssertEqual(launcher.launchCount, 1)

        coordinator.cancel()
        XCTAssertTrue(launcher.handle?.terminateCalled == true)
        coordinator.retry(rebuild: true)
        XCTAssertEqual(launcher.launchCount, 1)
        launcher.finish(status: "cancelled", exitCode: 0)
        XCTAssertEqual(coordinator.snapshot.status, .cancelled)
        XCTAssertTrue(coordinator.snapshot.nextRunAt != nil)

        scheduler.fire(try XCTUnwrap(scheduler.pendingHandles.first))
        XCTAssertEqual(launcher.launchCount, 2)
        XCTAssertTrue(String(decoding: try XCTUnwrap(launcher.lastInput), as: UTF8.self).contains("\"action\":\"rebuild\""))
    }

    @MainActor
    private func makeContract(configuration: AppConfiguration, token: String) throws -> ManagedRuntimeLaunchContract {
        let snapshot = CapabilityRegistry(
            configuration: configuration,
            facts: CapabilityReadinessFacts(coreSessionReady: true)
        ).snapshot()
        return ManagedRuntimeLaunchContract(
            port: configuration.localMCPPort,
            configuration: configuration,
            capabilitySnapshot: snapshot,
            environment: [:],
            redactedSecrets: [token],
            ngrokAuthtoken: nil,
            meridianIndexerToken: token
        )
    }

    private func temporaryDirectory(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meridian-indexer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

@MainActor
private final class FakeMeridianIndexerLauncher: MeridianIndexerProcessLaunching {
    private(set) var launchCount = 0
    private(set) var lastInput: Data?
    private(set) var handle: FakeMeridianIndexerProcess?
    private var termination: ((Int32) -> Void)?
    private var output: ((Data) -> Void)?

    func launch(
        executableURL: URL,
        environment: [String: String],
        input: Data,
        output: @escaping (Data) -> Void,
        termination: @escaping (Int32) -> Void
    ) throws -> any MeridianIndexerProcessHandle {
        _ = executableURL
        XCTAssertEqual(environment["MERIDIAN_CORE_TOKEN"], "core-token")
        self.output = output
        launchCount += 1
        lastInput = input
        self.termination = termination
        let handle = FakeMeridianIndexerProcess()
        self.handle = handle
        return handle
    }

    func finish(status: String, exitCode: Int32) {
        let action = status == "cancelled" ? "index" : "rebuild"
        let result = "{\"control_version\":\"1.0.0\",\"action\":\"\(action)\",\"status\":\"\(status)\",\"exit_code\":\(exitCode),\"counts\":{\"discovered\":0,\"unchanged\":0,\"committed\":0,\"skipped\":0,\"failed\":0,\"cancelled\":0,\"reconciliation_required\":0}}\n"
        output?(Data(result.utf8))
        termination?(exitCode)
    }
}

@MainActor
private final class FakeMeridianIndexerProcess: MeridianIndexerProcessHandle {
    private(set) var terminateCalled = false
    var isRunning: Bool { !terminateCalled }

    func terminate() {
        terminateCalled = true
    }
}
