import Foundation
import XCTest
@testable import MacOrchestrator

final class RepairEngineTests: XCTestCase {
    func testRepairOutcomeStatusesUseStableWireValues() throws {
        XCTAssertEqual(RepairOutcomeStatus.repaired.rawValue, "repaired")
        XCTAssertEqual(RepairOutcomeStatus.notNeeded.rawValue, "notNeeded")
        XCTAssertEqual(RepairOutcomeStatus.refused.rawValue, "refused")
        XCTAssertEqual(RepairOutcomeStatus.failed.rawValue, "failed")
        XCTAssertEqual(RepairOutcomeStatus.requiresUserAction.rawValue, "requiresUserAction")

        let outcome = RepairOutcome(
            action: .retryMCPServer,
            status: .repaired,
            reason: "The requested repair completed."
        )
        let encoded = try JSONEncoder().encode(outcome)
        let decoded = try JSONDecoder().decode(RepairOutcome.self, from: encoded)
        XCTAssertEqual(decoded, outcome)
    }

    func testLifecycleAdapterCanReturnEveryOutcomeStatus() async {
        for status in RepairOutcomeStatus.allCases {
            let adapter = RecordingRepairAdapters(result: RepairAdapterResult(status: status))
            let outcome = await RepairEngine(dependencies: RepairDependencies(
                lifecycleRetrying: adapter
            )).execute(.retryMCPServer)

            XCTAssertEqual(outcome.status, status)
        }
    }

    func testEachActionRoutesOnlyToItsMatchingAdapter() async {
        let recorder = RecordingRepairAdapters()
        let engine = RepairEngine(dependencies: RepairDependencies(
            lifecycleRetrying: recorder,
            permissionSettingsOpening: recorder,
            configurationBackupRestoring: recorder,
            localPortReassigning: recorder,
            launchAgentRepairing: recorder,
            verifiedBootstrapHandingOff: recorder
        ))

        for action in RepairActionID.allCases {
            _ = await engine.execute(action)
        }

        let counts = await recorder.counts()
        XCTAssertEqual(counts.lifecycle, 2)
        XCTAssertEqual(counts.permission, 3)
        XCTAssertEqual(counts.backup, 1)
        XCTAssertEqual(counts.port, 1)
        XCTAssertEqual(counts.launchAgent, 1)
        XCTAssertEqual(counts.bootstrap, 1)
    }

    func testMissingAdapterReturnsRefusedWithoutFanout() async {
        let recorder = RecordingRepairAdapters()
        let engine = RepairEngine(dependencies: RepairDependencies(lifecycleRetrying: recorder))

        let outcome = await engine.execute(.repairLaunchAgent)

        XCTAssertEqual(outcome.status, .refused)
        let counts = await recorder.counts()
        XCTAssertEqual(counts.total, 0)
    }

    func testDoctorDoesNotOwnOrInvokeRepairEngine() {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacOrchestrator/DoctorEngine.swift")
        let source = try? String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertNotNil(source)
        XCTAssertFalse(source?.contains("RepairEngine") == true)
        XCTAssertFalse(source?.contains("RepairDependencies") == true)
    }

    func testPermissionRepairRequiresUserActionUntilLaterRecheck() async {
        let recorder = RecordingRepairAdapters()
        let engine = RepairEngine(dependencies: RepairDependencies(permissionSettingsOpening: recorder))

        let outcome = await engine.execute(.openAccessibilitySettings)

        XCTAssertEqual(outcome.status, .requiresUserAction)
        XCTAssertTrue(outcome.reason.contains("System Settings"))
        let counts = await recorder.counts()
        XCTAssertEqual(counts.permission, 1)
    }

    func testInvalidBackupIsRefusedAndPrimaryIsPreserved() async throws {
        let root = try makeTemporaryDirectory()
        let store = ConfigurationStore(directoryURL: root, ownerIDProvider: { "owner-test" })
        _ = try store.loadOrCreate()
        try Data("{not-json".utf8).write(to: store.configurationURL)
        try Data("{also-not-json".utf8).write(to: store.backupURL)

        let restorer = ConfigurationStoreBackupRestorer(store: store)
        let outcome = await RepairEngine(dependencies: RepairDependencies(
            configurationBackupRestoring: restorer
        )).execute(.restoreConfigurationBackup)

        XCTAssertEqual(outcome.status, .refused)
        XCTAssertEqual(try Data(contentsOf: store.configurationURL), Data("{not-json".utf8))
    }

    func testValidBackupRestoresAndPreservesBadPrimary() async throws {
        let root = try makeTemporaryDirectory()
        let store = ConfigurationStore(directoryURL: root, ownerIDProvider: { "owner-test" })
        var configuration = try store.loadOrCreate()
        configuration.localMCPPort = 8123
        _ = try store.save(configuration)
        configuration.localMCPPort = 9123
        _ = try store.save(configuration)
        let knownGoodBackup = try Data(contentsOf: store.backupURL)
        try Data("{not-json".utf8).write(to: store.configurationURL)

        let restorer = ConfigurationStoreBackupRestorer(store: store)
        let outcome = await RepairEngine(dependencies: RepairDependencies(
            configurationBackupRestoring: restorer
        )).execute(.restoreConfigurationBackup)

        XCTAssertEqual(outcome.status, .repaired)
        XCTAssertEqual(try store.load().localMCPPort, 8123)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.configurationURL.path + ".corrupt"))
        XCTAssertEqual(try Data(contentsOf: store.backupURL), knownGoodBackup)
    }

    func testPortReassignmentRequiresFreeCandidateAndReportsClientGuidanceWithoutTermination() async {
        let occupancy = RecordingPortOccupancy(result: .free)
        let updater = RecordingPortUpdater()
        let reassigner = SafeLocalPortReassigner(
            request: LocalPortReassignmentRequest(
                currentPort: 8000,
                candidatePort: 8123,
                expectedOwnerID: "owner-1",
                observedOwnerID: "owner-1"
            ),
            occupancy: occupancy,
            configuration: updater
        )

        let outcome = await RepairEngine(dependencies: RepairDependencies(
            localPortReassigning: reassigner
        )).execute(.reassignLocalPort)

        XCTAssertEqual(outcome.status, .repaired)
        XCTAssertTrue(outcome.reason.contains("configured clients"))
        XCTAssertEqual(await occupancy.ports, [8123])
        XCTAssertEqual(await updater.updatedPorts, [8123])
        XCTAssertEqual(await updater.terminatedListeners, 0)
    }

    func testPortReassignmentRefusesOccupiedCandidateAndOwnershipMismatch() async {
        let occupied = SafeLocalPortReassigner(
            request: LocalPortReassignmentRequest(
                currentPort: 8000,
                candidatePort: 8123,
                expectedOwnerID: "owner-1",
                observedOwnerID: "owner-1"
            ),
            occupancy: RecordingPortOccupancy(result: .occupiedUnrelated),
            configuration: RecordingPortUpdater()
        )
        let mismatch = SafeLocalPortReassigner(
            request: LocalPortReassignmentRequest(
                currentPort: 8000,
                candidatePort: 8124,
                expectedOwnerID: "owner-1",
                observedOwnerID: "owner-2"
            ),
            occupancy: RecordingPortOccupancy(result: .free),
            configuration: RecordingPortUpdater()
        )

        XCTAssertEqual(
            await RepairEngine(dependencies: RepairDependencies(localPortReassigning: occupied))
                .execute(.reassignLocalPort).status,
            .refused
        )
        XCTAssertEqual(
            await RepairEngine(dependencies: RepairDependencies(localPortReassigning: mismatch))
                .execute(.reassignLocalPort).status,
            .refused
        )
    }

    func testLaunchAgentRepairRequiresExactOwnershipLabelPathAndContract() async {
        let writer = RecordingLaunchAgentWriter()
        let repairer = ManagedLaunchAgentRepairer(
            ownership: StaticLaunchAgentOwnershipFacts(
                exactLabel: false,
                exactPath: true,
                exactContract: true
            ),
            writer: writer
        )

        let outcome = await RepairEngine(dependencies: RepairDependencies(
            launchAgentRepairing: repairer
        )).execute(.repairLaunchAgent)

        XCTAssertEqual(outcome.status, .refused)
        XCTAssertEqual(await writer.writeCount, 0)
    }

    func testVerifiedBootstrapOnlyHandsOffPinnedVerifiedContext() async {
        let unverified = PinnedVerifiedBootstrapHandoff(
            context: VerifiedBootstrapContext(releasePinned: false, artifactVerified: true, helperOwned: true)
        )
        let verified = PinnedVerifiedBootstrapHandoff(
            context: VerifiedBootstrapContext(releasePinned: true, artifactVerified: true, helperOwned: true)
        )

        XCTAssertEqual(
            await RepairEngine(dependencies: RepairDependencies(verifiedBootstrapHandingOff: unverified))
                .execute(.rerunVerifiedBootstrap).status,
            .refused
        )
        let outcome = await RepairEngine(dependencies: RepairDependencies(
            verifiedBootstrapHandingOff: verified
        )).execute(.rerunVerifiedBootstrap)
        XCTAssertEqual(outcome.status, .requiresUserAction)
        XCTAssertTrue(outcome.reason.contains("verified"))
        XCTAssertFalse(outcome.reason.contains("http"))
    }

    func testOutcomesNeverExposeProviderErrorsSecretsURLsOrHomePaths() async {
        let engine = RepairEngine(dependencies: RepairDependencies(
            lifecycleRetrying: RecordingRepairAdapters(result: .failed),
            permissionSettingsOpening: RecordingRepairAdapters(result: .failed),
            configurationBackupRestoring: RecordingRepairAdapters(result: .failed),
            localPortReassigning: RecordingRepairAdapters(result: .failed),
            launchAgentRepairing: RecordingRepairAdapters(result: .failed),
            verifiedBootstrapHandingOff: RecordingRepairAdapters(result: .failed)
        ))

        for action in RepairActionID.allCases {
            let outcome = await engine.execute(action)
            XCTAssertFalse(outcome.reason.contains("secret-value"))
            XCTAssertFalse(outcome.reason.contains("https://"))
            XCTAssertFalse(outcome.reason.contains("/Users/"))
            XCTAssertFalse(outcome.reason.contains("provider exploded"))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOrchestratorRepairTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private actor RecordingRepairAdapters:
    LifecycleRetrying,
    PermissionSettingsOpening,
    ConfigurationBackupRestoring,
    LocalPortReassigning,
    LaunchAgentRepairing,
    VerifiedBootstrapHandingOff {
    private let result: RepairAdapterResult
    private var lifecycleCount = 0
    private var permissionCount = 0
    private var backupCount = 0
    private var portCount = 0
    private var launchAgentCount = 0
    private var bootstrapCount = 0

    init(result: RepairAdapterResult = .repaired) {
        self.result = result
    }

    func retry(_ target: LifecycleRepairTarget) async -> RepairAdapterResult {
        lifecycleCount += 1
        return result
    }

    func open(_ pane: PermissionSettingsPane) async -> RepairAdapterResult {
        permissionCount += 1
        return result
    }

    func restoreValidatedBackup() async -> RepairAdapterResult {
        backupCount += 1
        return result
    }

    func reassignLocalPort() async -> RepairAdapterResult {
        portCount += 1
        return result
    }

    func repairManagedLaunchAgent() async -> RepairAdapterResult {
        launchAgentCount += 1
        return result
    }

    func handoffVerifiedBootstrap() async -> RepairAdapterResult {
        bootstrapCount += 1
        return result
    }

    func counts() -> (lifecycle: Int, permission: Int, backup: Int, port: Int, launchAgent: Int, bootstrap: Int, total: Int) {
        let values = [lifecycleCount, permissionCount, backupCount, portCount, launchAgentCount, bootstrapCount]
        return (lifecycleCount, permissionCount, backupCount, portCount, launchAgentCount, bootstrapCount, values.reduce(0, +))
    }
}

private actor RecordingPortOccupancy: LocalPortOccupancyChecking {
    let result: LocalPortOccupancy
    private(set) var ports: [Int] = []

    init(result: LocalPortOccupancy) {
        self.result = result
    }

    func inspect(port: Int) async -> LocalPortOccupancy {
        ports.append(port)
        return result
    }
}

private actor RecordingPortUpdater: CanonicalLocalPortUpdating {
    private(set) var updatedPorts: [Int] = []
    private(set) var terminatedListeners = 0

    func updateLocalMCPPort(_ port: Int) async throws {
        updatedPorts.append(port)
    }
}

private actor RecordingLaunchAgentWriter: ExactLaunchAgentContractWriting {
    private(set) var writeCount = 0

    func writeExactManagedContract() async -> RepairAdapterResult {
        writeCount += 1
        return .repaired
    }
}

private struct StaticLaunchAgentOwnershipFacts: LaunchAgentOwnershipInspecting {
    let facts: LaunchAgentOwnershipFacts

    init(exactLabel: Bool, exactPath: Bool, exactContract: Bool) {
        self.facts = LaunchAgentOwnershipFacts(
            exactLabel: exactLabel,
            exactPath: exactPath,
            exactContract: exactContract
        )
    }

    func inspect() -> LaunchAgentOwnershipFacts { facts }
}
