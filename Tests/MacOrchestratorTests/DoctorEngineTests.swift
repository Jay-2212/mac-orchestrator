import Foundation
import XCTest
@testable import MacOrchestrator

final class DoctorEngineTests: XCTestCase {
    func testDoctorContinuesWhenOneProviderFails() async {
        let dependencies = DoctorDependencies.fixture(
            configurationError: .permissionDenied,
            installed: .healthy,
            update: .unavailable
        )

        let report = await DoctorEngine(dependencies: dependencies).run()

        XCTAssertEqual(report.result(withID: "configuration.read")?.status, .fail)
        XCTAssertEqual(report.result(withID: "installation.helper")?.status, .pass)
        XCTAssertEqual(report.result(withID: "update.availability")?.status, .skip)
    }

    func testDisabledRemoteAndFutureCapabilitiesAreSkipped() async {
        let report = await DoctorEngine(dependencies: .fixture(remoteDesired: false)).run()

        XCTAssertEqual(report.result(withID: "remote.ngrok")?.status, .skip)
        XCTAssertEqual(report.result(withID: "capability.meridian")?.status, .skip)
        XCTAssertEqual(report.result(withID: "capability.cloudflare")?.status, .skip)
        XCTAssertEqual(report.result(withID: "capability.telegram-assistant")?.status, .skip)
    }

    func testPureChecksExposeAllFourStatusesAndBoundedRepairs() {
        let valid = DoctorDependencies.configurationFacts(for: AppConfiguration(ownerID: "owner"))
        let unusableBackup = ConfigurationDiagnosticFacts(
            directoryExists: true,
            directoryMode: 0o700,
            primary: valid.primary,
            backup: ConfigurationFileFacts(exists: true, readable: true, state: .malformed)
        )

        XCTAssertEqual(DiagnosticChecks.configurationRead(valid).status, .pass)
        XCTAssertEqual(DiagnosticChecks.configurationBackup(unusableBackup).status, .warn)
        XCTAssertEqual(DiagnosticChecks.installationHelper(InstalledReleaseFacts()).status, .fail)
        XCTAssertEqual(DiagnosticChecks.installationHelper(InstalledReleaseFacts()).repair?.id, .rerunVerifiedBootstrap)
        XCTAssertEqual(DiagnosticChecks.remoteNgrok(nil, auth: nil, desired: false).status, .skip)
        XCTAssertLessThanOrEqual(
            [DiagnosticChecks.installationHelper(InstalledReleaseFacts())].compactMap(\.repair).count,
            1
        )
    }

    func testConfigurationBranchesCoverSchemaGenerationRecoveryAndPermissions() {
        var configuration = AppConfiguration(ownerID: "owner")
        configuration.generation = 4
        let facts = DoctorDependencies.configurationFacts(for: configuration)

        XCTAssertEqual(DiagnosticChecks.configurationGeneration(facts).status, .pass)
        XCTAssertEqual(DiagnosticChecks.configurationPermissions(facts).status, .pass)
        XCTAssertEqual(DiagnosticChecks.configurationSchema(facts).status, .pass)
        XCTAssertEqual(DiagnosticChecks.configurationMigration(configuration).status, .pass)

        var migrated = configuration
        migrated.onboarding.migrationMarkers = ["phase2"]
        XCTAssertEqual(DiagnosticChecks.configurationMigration(migrated).status, .warn)

        let unsupported = ConfigurationDiagnosticFacts(
            directoryExists: true,
            directoryMode: 0o700,
            primary: ConfigurationFileFacts(exists: true, readable: true, state: .unsupported, schemaVersion: 99, mode: 0o600)
        )
        XCTAssertEqual(DiagnosticChecks.configurationRead(unsupported).status, .fail)
        XCTAssertEqual(DiagnosticChecks.configurationSchema(unsupported).status, .fail)
        XCTAssertEqual(DiagnosticChecks.configurationRecovery(unsupported).status, .fail)

        let backup = ConfigurationFileFacts(
            exists: true,
            readable: true,
            valid: true,
            state: .valid,
            generation: 4,
            mode: 0o600
        )
        let recovery = ConfigurationDiagnosticFacts(
            directoryExists: true,
            directoryMode: 0o700,
            primary: ConfigurationFileFacts(exists: true, readable: true, state: .malformed, mode: 0o600),
            backup: backup
        )
        XCTAssertEqual(DiagnosticChecks.configurationRecovery(recovery).status, .warn)
        XCTAssertEqual(DiagnosticChecks.configurationRecovery(recovery).repair?.id, .restoreConfigurationBackup)

        let unsafePermissions = ConfigurationDiagnosticFacts(
            directoryExists: true,
            directoryMode: 0o755,
            primary: facts.primary
        )
        XCTAssertEqual(DiagnosticChecks.configurationPermissions(unsafePermissions).status, .fail)
    }

    func testInstallationVersionIntegrityAndAdHocTrustBranches() {
        let healthy = InstalledFixture.healthy.facts
        XCTAssertEqual(DiagnosticChecks.installationRuntime(healthy).status, .pass)
        XCTAssertEqual(DiagnosticChecks.installationIntegrity(healthy).status, .pass)
        XCTAssertEqual(DiagnosticChecks.installationVersionMatch(healthy).status, .pass)
        XCTAssertEqual(DiagnosticChecks.trustCodeSign(healthy).status, .pass)

        let incompleteVersions = InstalledReleaseFacts(
            releaseVersion: "1.0.0",
            helper: healthy.helper,
            runtime: RuntimeFacts(runtimePresent: true, markerPresent: true, payloadPresent: true, structurallyValid: true),
            helperPresent: true,
            ownershipMarkerPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.installationVersionMatch(incompleteVersions).status, .warn)

        let adHoc = InstalledReleaseFacts(helper: CodeSignFacts(isSigned: true, isAdHoc: true, developerIDTrusted: false), helperPresent: true)
        XCTAssertEqual(DiagnosticChecks.trustCodeSign(adHoc).status, .warn)

        let unsigned = InstalledReleaseFacts(helper: CodeSignFacts(isSigned: false), helperPresent: true)
        XCTAssertEqual(DiagnosticChecks.trustCodeSign(unsigned).status, .fail)
        XCTAssertEqual(DiagnosticChecks.installationRuntime(InstalledReleaseFacts()).status, .fail)
    }

    func testPermissionSessionAndKeychainChecksAreConservative() {
        var configuration = AppConfiguration(ownerID: "owner")
        configuration.desiredCapabilities["mac.screenOcr"] = true
        let managed = PermissionFacts(
            accessibility: true,
            screenRecording: false,
            automation: true,
            activeConsole: true,
            requesterIsManagedRuntime: true
        )
        XCTAssertEqual(DiagnosticChecks.permissionsRequester(managed, configuration: configuration).status, .fail)
        XCTAssertEqual(
            DiagnosticChecks.permissionsRequester(
                PermissionFacts(activeConsole: false, requesterIsManagedRuntime: true),
                configuration: configuration
            ).status,
            .fail
        )
        XCTAssertEqual(
            DiagnosticChecks.permissionsRequester(PermissionFacts(requesterIsManagedRuntime: false), configuration: configuration).status,
            .skip
        )
        XCTAssertEqual(DiagnosticChecks.keychainConnector(KeychainPresenceFacts()).status, .skip)
        XCTAssertEqual(
            DiagnosticChecks.keychainConnector(KeychainPresenceFacts(states: [.connectorToken: .inaccessible])).status,
            .warn
        )
    }

    func testPortChecksRejectMalformedOccupiedAndPIDReusePorts() {
        XCTAssertEqual(DiagnosticChecks.portSelected(PortFacts(port: 0), configuredPort: 0).status, .fail)
        XCTAssertEqual(
            DiagnosticChecks.portSelected(PortFacts(port: 8000, listenerPresent: true), configuredPort: 8000).status,
            .fail
        )
        XCTAssertEqual(
            DiagnosticChecks.portSelected(PortFacts(port: 8000, listenerPresent: true, listenerOwned: true), configuredPort: 8000).status,
            .pass
        )
        XCTAssertEqual(
            DiagnosticChecks.portSelected(PortFacts(port: 8000, pidReuseDetected: true), configuredPort: 8000).status,
            .fail
        )
        XCTAssertEqual(DiagnosticChecks.portSelected(nil, configuredPort: 8000).repair?.id, .reassignLocalPort)
    }

    func testMCPChecksKeepLivenessReadinessInventoryAndSafeCallDistinct() {
        let live = LocalMCPFacts(livenessVerified: true)
        XCTAssertEqual(DiagnosticChecks.mcpLiveness(live, desired: true).status, .pass)
        XCTAssertEqual(DiagnosticChecks.mcpReadiness(live, desired: true).status, .fail)
        XCTAssertEqual(DiagnosticChecks.mcpInventory(live, desired: true).status, .skip)
        XCTAssertEqual(DiagnosticChecks.mcpLiveness(nil, desired: false).status, .skip)

        let mismatch = LocalMCPFacts(
            livenessVerified: true,
            readinessVerified: true,
            sessionEstablished: true,
            safeCallSucceeded: true,
            expectedTools: ["describe", "get_session_state"],
            exposedTools: ["describe"],
            expectedCapabilityGroups: ["core.session"],
            exposedCapabilityGroups: []
        )
        XCTAssertEqual(DiagnosticChecks.mcpReadiness(mismatch, desired: true).status, .pass)
        XCTAssertEqual(DiagnosticChecks.mcpInventory(mismatch, desired: true).status, .fail)
    }

    func testLifecycleRemoteUpdateAndDiskChecks() {
        XCTAssertEqual(DiagnosticChecks.lifecycleLaunchAgent(LifecycleFacts(), desired: true).status, .fail)
        XCTAssertEqual(
            DiagnosticChecks.lifecycleProcessOwnership(
                LifecycleFacts(ownershipMarkerPresent: true, duplicateOwnedProcesses: false, pidReuseDetected: false),
                desired: true
            ).status,
            .pass
        )
        XCTAssertEqual(
            DiagnosticChecks.lifecycleProcessOwnership(LifecycleFacts(pidReuseDetected: true), desired: true).status,
            .fail
        )

        let remote = RemoteConnectorFacts(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            endpointAvailable: true,
            endpointCount: 1,
            ownershipMarkerPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.remoteNgrok(remote, auth: .present, desired: true).status, .pass)
        XCTAssertEqual(DiagnosticChecks.remoteEndpoint(remote, desired: true).status, .pass)
        XCTAssertEqual(DiagnosticChecks.remoteEndpoint(remote, desired: false).status, .skip)
        XCTAssertEqual(DiagnosticChecks.updateAvailability(nil).status, .skip)
        XCTAssertEqual(DiagnosticChecks.updateAvailability(UpdateAvailabilityFacts(status: .available)).status, .warn)
        XCTAssertEqual(DiagnosticChecks.diskFreeSpace(DiskSpaceFacts(filesystemAccessible: true, availableBytes: 100, thresholdBytes: 100), thresholdBytes: 100).status, .pass)
        XCTAssertEqual(DiagnosticChecks.diskFreeSpace(DiskSpaceFacts(filesystemAccessible: true, availableBytes: 99), thresholdBytes: 100).status, .warn)
        XCTAssertEqual(DiagnosticChecks.criticalPaths(DiskSpaceFacts(criticalPathSymlinkCount: 1)).status, .fail)
    }

    func testDoctorSortsResultsUsesInjectedClockAndIsMutationFree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let dependencies = DoctorDependencies.fixture(remoteDesired: true)

        let report = await DoctorEngine(dependencies: dependencies).run()

        XCTAssertEqual(report.generatedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(report.results.map(\.id), report.results.map(\.id).sorted())
        XCTAssertEqual(try report.encodedJSON(), try DoctorReport(generatedAt: report.generatedAt, results: report.results).encodedJSON())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), before)
        XCTAssertTrue(report.results.compactMap(\.repair).allSatisfy { _ in true })
    }

    func testAsyncCanonicalAdapterDependencyIsUsedWithoutSynchronousFallback() async {
        let facts = LocalMCPFacts(livenessVerified: true, readinessVerified: true, sessionEstablished: true, safeCallSucceeded: true)
        let asyncProvider = AsyncFixtureProvider(facts: facts)
        var dependencies = DoctorDependencies.fixture()
        dependencies = DoctorDependencies(
            configurationProvider: dependencies.configurationProvider,
            configuration: dependencies.configuration,
            installedReleaseProvider: dependencies.installedReleaseProvider,
            permissionProvider: dependencies.permissionProvider,
            keychainPresenceProvider: dependencies.keychainPresenceProvider,
            portProvider: dependencies.portProvider,
            localMCPProvider: ThrowingLocalMCPProvider(),
            asyncLocalMCPProvider: asyncProvider,
            lifecycleProvider: dependencies.lifecycleProvider,
            remoteConnectorProvider: dependencies.remoteConnectorProvider,
            diskSpaceProvider: dependencies.diskSpaceProvider,
            updateProvider: dependencies.updateProvider,
            thresholds: dependencies.thresholds,
            clock: dependencies.clock
        )

        let report = await DoctorEngine(dependencies: dependencies).run()

        XCTAssertEqual(report.result(withID: "mcp.readiness")?.status, .pass)
        XCTAssertEqual(asyncProvider.calls, 1)
    }
}

private extension DoctorDependencies {
    static func fixture(
        configurationError: DiagnosticProviderError? = nil,
        installed: InstalledFixture = .healthy,
        update: UpdateAvailability = .unavailable,
        remoteDesired: Bool = false
    ) -> DoctorDependencies {
        var configuration = AppConfiguration(ownerID: "fixture-owner")
        configuration.process.tunnelDesired = remoteDesired
        configuration.desiredCapabilities["remote.connector"] = remoteDesired
        return DoctorDependencies(
            configurationProvider: FixtureConfigurationProvider(
                facts: configurationFacts(for: configuration),
                error: configurationError
            ),
            configuration: configuration,
            installedReleaseProvider: FixtureInstalledProvider(facts: installed.facts),
            permissionProvider: FixtureProvider(facts: PermissionFacts(
                accessibility: true,
                screenRecording: true,
                automation: true,
                activeConsole: true,
                requesterIsManagedRuntime: true
            )),
            keychainPresenceProvider: FixtureProvider(facts: KeychainPresenceFacts(states: [
                .connectorToken: .present,
                .ngrokAuthtoken: remoteDesired ? .present : .absent
            ])),
            portProvider: FixtureProvider(facts: PortFacts(port: configuration.localMCPPort)),
            localMCPProvider: FixtureProvider(facts: LocalMCPFacts(
                livenessVerified: true,
                readinessVerified: true,
                sessionEstablished: true,
                safeCallSucceeded: true,
                expectedTools: ["describe"],
                exposedTools: ["describe"],
                expectedCapabilityGroups: ["core.session"],
                exposedCapabilityGroups: ["core.session"]
            )),
            lifecycleProvider: FixtureProvider(facts: LifecycleFacts(
                launchAgentPresent: true,
                launchAgentValid: true,
                serviceRunning: true,
                ownedProcessCount: 1,
                serverPID: 10,
                tunnelPID: remoteDesired ? 11 : nil,
                ownershipMarkerPresent: true
            )),
            remoteConnectorProvider: FixtureProvider(facts: RemoteConnectorFacts(
                desired: remoteDesired,
                binaryPresent: remoteDesired,
                configurationPresent: remoteDesired,
                endpointAvailable: remoteDesired,
                endpointCount: remoteDesired ? 1 : 0,
                ownershipMarkerPresent: remoteDesired
            )),
            diskSpaceProvider: FixtureProvider(facts: DiskSpaceFacts(
                filesystemAccessible: true,
                availableBytes: 10_000,
                thresholdBytes: 1_000
            )),
            updateProvider: FixtureProvider(facts: UpdateAvailabilityFacts(status: update)),
            thresholds: DoctorThresholds(lowDiskBytes: 1_000),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private static func configurationFacts(for configuration: AppConfiguration) -> ConfigurationDiagnosticFacts {
        let file = ConfigurationFileFacts(
            exists: true,
            readable: true,
            valid: true,
            state: .valid,
            schemaVersion: configuration.schemaVersion,
            generation: configuration.generation,
            mode: 0o600,
            byteCount: 1
        )
        return ConfigurationDiagnosticFacts(
            directoryExists: true,
            directoryMode: 0o700,
            primary: file,
            backup: file
        )
    }
}

private enum InstalledFixture {
    case healthy

    var facts: InstalledReleaseFacts {
        InstalledReleaseFacts(
            releaseVersion: "1.0.0",
            helper: CodeSignFacts(
                bundleIdentifier: "com.jay.mac-orchestrator",
                version: "1.0.0",
                architecture: "arm64",
                isSigned: true,
                developerIDTrusted: true,
                receiptAvailable: true,
                integrityAvailable: true
            ),
            runtime: RuntimeFacts(
                runtimePresent: true,
                architecture: "arm64",
                version: "1.0.0",
                markerPresent: true,
                payloadPresent: true,
                structurallyValid: true
            ),
            helperPresent: true,
            ownershipMarkerPresent: true
        )
    }
}

private struct FixtureConfigurationProvider: ConfigurationDiagnosticProviding {
    let facts: ConfigurationDiagnosticFacts
    let error: DiagnosticProviderError?

    func inspect() throws -> ConfigurationDiagnosticFacts {
        if let error { throw error }
        return facts
    }
}

private struct FixtureInstalledProvider: InstalledReleaseFactsProviding {
    let facts: InstalledReleaseFacts
    func inspect() throws -> InstalledReleaseFacts { facts }
}

private struct ThrowingLocalMCPProvider: LocalMCPDiagnosticProviding {
    func inspect() throws -> LocalMCPFacts { throw DiagnosticProviderError.unavailable }
}

private final class AsyncFixtureProvider: DoctorAsyncLocalMCPDiagnosticProviding, @unchecked Sendable {
    let facts: LocalMCPFacts
    private(set) var calls = 0

    init(facts: LocalMCPFacts) {
        self.facts = facts
    }

    func inspect() async throws -> LocalMCPFacts {
        calls += 1
        return facts
    }
}

private struct FixtureProvider<Facts>: @unchecked Sendable {
    let facts: Facts
}

extension FixtureProvider: PermissionFactsProviding where Facts == PermissionFacts {
    func inspect() throws -> PermissionFacts { facts }
}

extension FixtureProvider: KeychainPresenceProviding where Facts == KeychainPresenceFacts {
    func inspect() throws -> KeychainPresenceFacts { facts }
}

extension FixtureProvider: PortFactsProviding where Facts == PortFacts {
    func inspect() throws -> PortFacts { facts }
}

extension FixtureProvider: LocalMCPDiagnosticProviding where Facts == LocalMCPFacts {
    func inspect() throws -> LocalMCPFacts { facts }
}

extension FixtureProvider: LifecycleFactsProviding where Facts == LifecycleFacts {
    func inspect() throws -> LifecycleFacts { facts }
}

extension FixtureProvider: RemoteConnectorFactsProviding where Facts == RemoteConnectorFacts {
    func inspect() throws -> RemoteConnectorFacts { facts }
}

extension FixtureProvider: DiskSpaceProviding where Facts == DiskSpaceFacts {
    func inspect() throws -> DiskSpaceFacts { facts }
}

extension FixtureProvider: UpdateAvailabilityProviding where Facts == UpdateAvailabilityFacts {
    func inspect() throws -> UpdateAvailabilityFacts { facts }
}
