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

    func testConcreteSystemSettingsOpenerUsesExactURLsAndRequiresUserAction() async {
        let opener = RecordingSettingsURLOpener(result: true)
        let adapter = SystemSettingsPermissionOpener(urlOpening: opener)

        let expected: [(PermissionSettingsPane, URL, RepairActionID)] = [
            (.accessibility, SystemSettingsPaneURLs.accessibility, .openAccessibilitySettings),
            (.screenRecording, SystemSettingsPaneURLs.screenRecording, .openScreenRecordingSettings),
            (.automation, SystemSettingsPaneURLs.automation, .openAutomationSettings),
        ]

        for (pane, url, action) in expected {
            let result = await adapter.open(pane)
            XCTAssertEqual(result.status, .requiresUserAction)
            XCTAssertEqual(await opener.openedURLs.last, url)

            let outcome = await RepairEngine(dependencies: RepairDependencies(
                permissionSettingsOpening: adapter
            )).execute(action)
            XCTAssertEqual(outcome.status, .requiresUserAction)
        }
    }

    func testSystemSettingsOpenFailureIsFailedWithoutTCCMutation() async {
        let opener = RecordingSettingsURLOpener(result: false)
        let result = await SystemSettingsPermissionOpener(urlOpening: opener).open(.automation)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(await opener.openedURLs, [SystemSettingsPaneURLs.automation])
    }

    func testDefaultDependenciesWireOnlyBoundedSettingsAdapter() {
        XCTAssertNotNil(RepairDependencies().permissionSettingsOpening)
        XCTAssertNil(RepairDependencies().lifecycleRetrying)
        XCTAssertNil(RepairDependencies().configurationBackupRestoring)
        XCTAssertNil(RepairDependencies().localPortReassigning)
        XCTAssertNil(RepairDependencies().launchAgentRepairing)
        XCTAssertNil(RepairDependencies().verifiedBootstrapHandingOff)
    }

    func testInvalidBackupIsRefusedAndPrimaryIsPreserved() async throws {
        let root = try makeTemporaryDirectory()
        let store = ConfigurationStore(directoryURL: root, ownerIDProvider: { "owner-test" })
        _ = try store.loadOrCreate()
        try Data("{not-json".utf8).write(to: store.configurationURL)
        try Data("{also-not-json".utf8).write(to: store.backupURL)

        let restorer = ConfigurationStoreBackupRestorer(store: store, expectedOwnerID: "owner-test")
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

        let restorer = ConfigurationStoreBackupRestorer(store: store, expectedOwnerID: "owner-test")
        let outcome = await RepairEngine(dependencies: RepairDependencies(
            configurationBackupRestoring: restorer
        )).execute(.restoreConfigurationBackup)

        XCTAssertEqual(outcome.status, .repaired)
        XCTAssertEqual(try store.load().localMCPPort, 8123)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.configurationURL.path + ".corrupt"))
        XCTAssertEqual(try Data(contentsOf: store.backupURL), knownGoodBackup)
    }

    func testBackupOwnerMismatchRefusesAndPreservesMalformedPrimary() async throws {
        let root = try makeTemporaryDirectory()
        let store = ConfigurationStore(directoryURL: root, ownerIDProvider: { "owner-test" })
        _ = try store.loadOrCreate()
        var foreign = AppConfiguration.fresh(ownerID: "foreign-owner")
        foreign.generation = 2
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(foreign).write(to: store.backupURL)
        let malformedPrimary = Data("{malformed-primary".utf8)
        try malformedPrimary.write(to: store.configurationURL)

        let restorer = ConfigurationStoreBackupRestorer(store: store, expectedOwnerID: "owner-test")
        let outcome = await RepairEngine(dependencies: RepairDependencies(
            configurationBackupRestoring: restorer
        )).execute(.restoreConfigurationBackup)

        XCTAssertEqual(outcome.status, .refused)
        XCTAssertEqual(try Data(contentsOf: store.configurationURL), malformedPrimary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.configurationURL.path + ".corrupt"))
    }

    func testPortReassignmentRequiresFreeCandidateAndReportsClientGuidanceWithoutTermination() async {
        let occupancy = SequencedPortOccupancy(results: [
            .occupiedOwned(ownerID: "owner-1"),
            .free,
            .free,
        ])
        let updater = RecordingPortUpdater()
        let reassigner = SafeLocalPortReassigner(
            request: LocalPortReassignmentRequest(
                currentPort: 8000,
                candidatePort: 8123,
                expectedOwnerID: "owner-1"
            ),
            occupancy: occupancy,
            configuration: updater
        )

        let outcome = await RepairEngine(dependencies: RepairDependencies(
            localPortReassigning: reassigner
        )).execute(.reassignLocalPort)

        XCTAssertEqual(outcome.status, .repaired)
        XCTAssertTrue(outcome.reason.contains("configured clients"))
        XCTAssertEqual(await occupancy.ports, [8000, 8123, 8123])
        XCTAssertEqual(await updater.updatedPorts, [8123])
        XCTAssertEqual(await updater.terminatedListeners, 0)
    }

    func testPortReassignmentRefusesOccupiedCandidateAndOwnershipMismatch() async {
        let occupied = SafeLocalPortReassigner(
            request: LocalPortReassignmentRequest(
                currentPort: 8000,
                candidatePort: 8123,
                expectedOwnerID: "owner-1"
            ),
            occupancy: SequencedPortOccupancy(results: [
                .occupiedOwned(ownerID: "owner-1"),
                .occupiedUnrelated,
            ]),
            configuration: RecordingPortUpdater()
        )
        let mismatch = SafeLocalPortReassigner(
            request: LocalPortReassignmentRequest(
                currentPort: 8000,
                candidatePort: 8124,
                expectedOwnerID: "owner-1"
            ),
            occupancy: SequencedPortOccupancy(results: [
                .occupiedOwned(ownerID: "owner-2"),
            ]),
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

    func testPortReassignmentRefusesCandidateRaceAndUnknownOccupancy() async {
        let raced = SafeLocalPortReassigner(
            request: LocalPortReassignmentRequest(
                currentPort: 8000,
                candidatePort: 8123,
                expectedOwnerID: "owner-1"
            ),
            occupancy: SequencedPortOccupancy(results: [
                .occupiedOwned(ownerID: "owner-1"),
                .free,
                .occupiedUnrelated,
            ]),
            configuration: RecordingPortUpdater()
        )
        let unknownCurrent = SafeLocalPortReassigner(
            request: LocalPortReassignmentRequest(
                currentPort: 8000,
                candidatePort: 8123,
                expectedOwnerID: "owner-1"
            ),
            occupancy: SequencedPortOccupancy(results: [.unknown]),
            configuration: RecordingPortUpdater()
        )

        XCTAssertEqual(
            await RepairEngine(dependencies: RepairDependencies(localPortReassigning: raced))
                .execute(.reassignLocalPort).status,
            .refused
        )
        XCTAssertEqual(
            await RepairEngine(dependencies: RepairDependencies(localPortReassigning: unknownCurrent))
                .execute(.reassignLocalPort).status,
            .refused
        )
    }

    func testLaunchAgentRepairRequiresExactOwnershipLabelPathAndContract() async {
        let writer = RecordingLaunchAgentWriter()
        let contract = ManagedLaunchAgentContract(homeDirectory: makeTemporaryHome())
        let repairer = ManagedLaunchAgentRepairer(
            contract: contract,
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

    func testExactLaunchAgentContractInspectorAndWriterRejectGuardsAndAcceptExactTarget() async throws {
        let home = makeTemporaryHome()
        let contract = ManagedLaunchAgentContract(homeDirectory: home)
        try FileManager.default.createDirectory(
            at: contract.launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let inspector = FileSystemLaunchAgentOwnershipInspector()
        let writer = FileSystemManagedLaunchAgentWriter()

        XCTAssertFalse(inspector.inspect(contract).ownedByMacOrchestrator)
        XCTAssertEqual(await writer.writeExactManagedContract(contract), .repaired)
        let owned = inspector.inspect(contract)
        XCTAssertTrue(owned.exactLabel)
        XCTAssertTrue(owned.exactPath)
        XCTAssertTrue(owned.exactContract)
        XCTAssertTrue(owned.ownedByMacOrchestrator)

        var wrongLabel = contract.propertyList
        wrongLabel["Label"] = "com.example.unrelated"
        try PropertyListSerialization.data(fromPropertyList: wrongLabel, format: .xml, options: 0)
            .write(to: contract.launchAgentURL, options: [.atomic])
        let labelMismatch = inspector.inspect(contract)
        XCTAssertFalse(labelMismatch.exactLabel)
        XCTAssertFalse(labelMismatch.ownedByMacOrchestrator)

        var wrongPath = contract.propertyList
        wrongPath["ProgramArguments"] = ["/Applications/Other.app/Contents/MacOS/Other"]
        try PropertyListSerialization.data(fromPropertyList: wrongPath, format: .xml, options: 0)
            .write(to: contract.launchAgentURL, options: [.atomic])
        XCTAssertFalse(inspector.inspect(contract).exactPath)
        XCTAssertFalse(inspector.inspect(contract).exactContract)

        var extraKeys = contract.propertyList
        extraKeys["Unexpected"] = true
        try PropertyListSerialization.data(fromPropertyList: extraKeys, format: .xml, options: 0)
            .write(to: contract.launchAgentURL, options: [.atomic])
        XCTAssertFalse(inspector.inspect(contract).ownedByMacOrchestrator)

        try FileManager.default.removeItem(at: contract.launchAgentURL)
        let unrelated = home.appendingPathComponent("unrelated.plist")
        try Data("unrelated".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(
            at: contract.launchAgentURL,
            withDestinationURL: unrelated
        )
        XCTAssertEqual(await writer.writeExactManagedContract(contract), .refused)
        XCTAssertFalse(inspector.inspect(contract).exactPath)
    }

    func testLaunchAgentRepairPassesExactContractOnlyAfterOwnershipGuard() async {
        let contract = ManagedLaunchAgentContract(homeDirectory: makeTemporaryHome())
        let writer = RecordingLaunchAgentWriter()
        let repairer = ManagedLaunchAgentRepairer(
            contract: contract,
            ownership: StaticLaunchAgentOwnershipFacts(
                exactLabel: true,
                exactPath: true,
                exactContract: true,
                ownedByMacOrchestrator: true
            ),
            writer: writer
        )

        XCTAssertEqual(await repairer.repairManagedLaunchAgent(), .repaired)
        XCTAssertEqual(await writer.writtenContracts, [contract])
    }

    func testOwnershipFactsDefaultToFalse() {
        let facts = LaunchAgentOwnershipFacts(exactLabel: true, exactPath: true, exactContract: true)
        XCTAssertFalse(facts.ownedByMacOrchestrator)
    }

    func testConcreteLifecycleHandoffIsOwnershipGuarded() async {
        let refused = OwnershipGuardedLifecycleHandoff(
            ownership: LifecycleOwnershipFacts(mcpServerOwned: false, remoteConnectorOwned: true)
        )
        let allowed = OwnershipGuardedLifecycleHandoff(
            ownership: LifecycleOwnershipFacts(mcpServerOwned: true, remoteConnectorOwned: true)
        )

        XCTAssertEqual(await refused.retry(.mcpServer).status, .refused)
        XCTAssertEqual(await refused.retry(.remoteConnector).status, .requiresUserAction)
        XCTAssertEqual(await allowed.retry(.mcpServer).status, .requiresUserAction)
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

    func testUnknownRepairReasonsMapToBoundedFixedText() {
        let outcome = RepairOutcome(
            action: .retryMCPServer,
            status: .failed,
            reason: String(repeating: "provider exploded https://secret.example/token /Users/jay", count: 100)
        )

        XCTAssertEqual(outcome.reason, "The requested repair failed safely; review Doctor diagnostics.")
        XCTAssertLessThanOrEqual(outcome.reason.count, 160)
        XCTAssertFalse(outcome.reason.contains("https://"))
        XCTAssertFalse(outcome.reason.contains("/Users/"))
        XCTAssertFalse(outcome.reason.contains("token"))
    }

    func testEveryActionAndStatusHasOnlyFixedBoundedReason() {
        for action in RepairActionID.allCases {
            for status in RepairOutcomeStatus.allCases {
                let outcome = RepairOutcome(action: action, status: status, reason: "untrusted provider detail")
                XCTAssertLessThanOrEqual(outcome.reason.count, 160)
                XCTAssertFalse(outcome.reason.contains("untrusted provider detail"))
                XCTAssertFalse(outcome.reason.contains("http"))
                XCTAssertFalse(outcome.reason.contains("/Users/"))
            }
        }
    }

    func testRepairEngineContainsNoGenericCommandOrRawReasonLeakage() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacOrchestrator/RepairEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("Process("))
        XCTAssertFalse(source.contains("curl|sh"))
        XCTAssertFalse(source.contains("/bin/sh"))
        XCTAssertFalse(source.contains("provider exploded"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOrchestratorRepairTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeTemporaryHome() -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOrchestratorRepairHome-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
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

private actor RecordingSettingsURLOpener: SystemSettingsURLOpening {
    let result: Bool
    private(set) var openedURLs: [URL] = []

    init(result: Bool) {
        self.result = result
    }

    func open(_ url: URL) async -> Bool {
        openedURLs.append(url)
        return result
    }
}

private actor SequencedPortOccupancy: LocalPortOccupancyChecking {
    private var results: [LocalPortOccupancy]
    private(set) var ports: [Int] = []

    init(results: [LocalPortOccupancy]) {
        self.results = results
    }

    func inspect(port: Int) async -> LocalPortOccupancy {
        ports.append(port)
        return results.isEmpty ? .unknown : results.removeFirst()
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
    private(set) var writtenContracts: [ManagedLaunchAgentContract] = []

    func writeExactManagedContract(_ contract: ManagedLaunchAgentContract) async -> RepairAdapterResult {
        writeCount += 1
        writtenContracts.append(contract)
        return .repaired
    }
}

private struct StaticLaunchAgentOwnershipFacts: LaunchAgentOwnershipInspecting {
    let facts: LaunchAgentOwnershipFacts

    init(
        exactLabel: Bool,
        exactPath: Bool,
        exactContract: Bool,
        ownedByMacOrchestrator: Bool = false
    ) {
        self.facts = LaunchAgentOwnershipFacts(
            exactLabel: exactLabel,
            exactPath: exactPath,
            exactContract: exactContract,
            ownedByMacOrchestrator: ownedByMacOrchestrator
        )
    }

    func inspect(_ contract: ManagedLaunchAgentContract) -> LaunchAgentOwnershipFacts { facts }
}
