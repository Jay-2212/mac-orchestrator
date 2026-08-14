import Foundation
import XCTest
@testable import MacOrchestrator

final class DoctorEngineTests: XCTestCase {
    func testDoctorContinuesWhenOneProviderFails() async {
        let dependencies = DoctorFixture.make(configurationError: .permissionDenied)

        let report = await DoctorEngine(dependencies: dependencies.dependencies).run()

        XCTAssertEqual(report.result(withID: "configuration.read")?.status, .fail)
        XCTAssertEqual(
            report.result(withID: "configuration.read")?.reason,
            "Unable to inspect configuration: permission denied."
        )
        XCTAssertEqual(report.result(withID: "installation.helper")?.status, .pass)
        XCTAssertEqual(report.result(withID: "update.availability")?.status, .skip)
        XCTAssertEqual(report.result(withID: "mcp.liveness")?.status, .skip)
        XCTAssertEqual(report.result(withID: "remote.ngrok")?.status, .skip)
    }

    func testConfigurationUsabilityGatesSchemaRecoveryGenerationAndRepair() {
        let validBackup = DoctorFixture.file(
            state: .valid,
            valid: true,
            schemaVersion: AppConfiguration.currentSchemaVersion,
            generation: 2
        )
        let primaryStates: [ConfigurationFileFacts] = [
            ConfigurationFileFacts(),
            DoctorFixture.file(state: .malformed),
            DoctorFixture.file(state: .invalid),
            DoctorFixture.file(state: .readable, valid: true),
            DoctorFixture.file(state: .valid, valid: true, isSymlink: true),
        ]

        for primary in primaryStates {
            let facts = ConfigurationDiagnosticFacts(primary: primary, backup: validBackup)

            XCTAssertEqual(DiagnosticChecks.configurationRead(facts).status, .fail)
            XCTAssertNil(DiagnosticChecks.configurationRead(facts).repair)
            XCTAssertEqual(DiagnosticChecks.configurationSchema(facts).status, .fail)
            XCTAssertEqual(DiagnosticChecks.configurationRecovery(facts).status, .warn)
            XCTAssertEqual(
                DiagnosticChecks.configurationRecovery(facts).repair?.id,
                .restoreConfigurationBackup
            )
            XCTAssertEqual(DiagnosticChecks.configurationGeneration(facts).status, .fail)
        }
    }

    func testConfigurationBackupRepairRequiresValidNonSymlinkBackup() {
        let primary = DoctorFixture.file(state: .malformed)
        let backups = [
            ConfigurationFileFacts(),
            DoctorFixture.file(state: .malformed),
            DoctorFixture.file(state: .invalid),
            DoctorFixture.file(state: .valid, valid: true, isSymlink: true),
            DoctorFixture.file(state: .valid, valid: true, schemaVersion: 99),
        ]

        for backup in backups {
            let facts = ConfigurationDiagnosticFacts(primary: primary, backup: backup)
            XCTAssertNil(DiagnosticChecks.configurationRecovery(facts).repair)
        }
    }

    func testValidBackupIsReportedWithoutInvokingRestore() {
        let facts = ConfigurationDiagnosticFacts(
            primary: DoctorFixture.file(state: .valid, valid: true, schemaVersion: 1, generation: 1),
            backup: DoctorFixture.file(state: .valid, valid: true, schemaVersion: 1, generation: 1)
        )

        XCTAssertEqual(DiagnosticChecks.configurationBackup(facts).status, .pass)
        XCTAssertNil(DiagnosticChecks.configurationBackup(facts).repair)
        XCTAssertEqual(DiagnosticChecks.configurationRecovery(facts).status, .pass)
        XCTAssertNil(DiagnosticChecks.configurationRecovery(facts).repair)
    }

    func testConfigurationFactsCoverCorruptEvidenceAndNewerGeneration() {
        let primary = DoctorFixture.file(
            state: .valid,
            valid: true,
            schemaVersion: AppConfiguration.currentSchemaVersion,
            generation: 2
        )
        let newerBackup = DoctorFixture.file(
            state: .valid,
            valid: true,
            schemaVersion: AppConfiguration.currentSchemaVersion,
            generation: 3
        )

        let newer = ConfigurationDiagnosticFacts(primary: primary, backup: newerBackup)
        XCTAssertEqual(DiagnosticChecks.configurationGeneration(newer).status, .warn)
        XCTAssertNil(DiagnosticChecks.configurationGeneration(newer).repair)

        let evidence = ConfigurationDiagnosticFacts(
            primary: primary,
            backup: ConfigurationFileFacts(),
            corruptEvidenceCount: 1
        )
        XCTAssertEqual(DiagnosticChecks.configurationRecovery(evidence).status, .warn)
        XCTAssertNil(DiagnosticChecks.configurationRecovery(evidence).repair)

        let unsupported = ConfigurationDiagnosticFacts(
            primary: DoctorFixture.file(state: .unsupported, schemaVersion: 99)
        )
        XCTAssertEqual(DiagnosticChecks.configurationRead(unsupported).status, .fail)
        XCTAssertEqual(DiagnosticChecks.configurationSchema(unsupported).status, .fail)
        XCTAssertEqual(DiagnosticChecks.configurationRecovery(unsupported).status, .fail)
        XCTAssertEqual(DiagnosticChecks.configurationGeneration(unsupported).status, .fail)
    }

    func testConfigurationMigrationAndPermissionsCoverReviewBranches() {
        let healthy = ConfigurationDiagnosticFacts(
            directoryExists: true,
            directoryMode: 0o700,
            primary: DoctorFixture.file(state: .valid, valid: true, schemaVersion: 1, generation: 1),
            backup: DoctorFixture.file(state: .valid, valid: true, schemaVersion: 1, generation: 1)
        )
        XCTAssertEqual(DiagnosticChecks.configurationPermissions(healthy).status, .pass)

        let unsafeCases = [
            ConfigurationDiagnosticFacts(
                directoryExists: true,
                directoryMode: 0o755,
                primary: healthy.primary,
                backup: healthy.backup
            ),
            ConfigurationDiagnosticFacts(
                directoryExists: true,
                directoryMode: 0o700,
                directoryIsSymlink: true,
                primary: healthy.primary,
                backup: healthy.backup
            ),
            ConfigurationDiagnosticFacts(
                directoryExists: true,
                directoryMode: 0o700,
                primary: DoctorFixture.file(state: .valid, valid: true, schemaVersion: 1, generation: 1, mode: 0o644),
                backup: healthy.backup
            ),
            ConfigurationDiagnosticFacts(
                directoryExists: true,
                directoryMode: 0o700,
                primary: healthy.primary,
                backup: DoctorFixture.file(state: .valid, valid: true, schemaVersion: 1, generation: 1, isSymlink: true)
            ),
        ]
        for facts in unsafeCases {
            XCTAssertEqual(DiagnosticChecks.configurationPermissions(facts).status, .fail)
        }

        let configuration = AppConfiguration(ownerID: "owner")
        XCTAssertEqual(DiagnosticChecks.configurationMigration(configuration).status, .pass)

        var marked = configuration
        marked.onboarding.migrationMarkers = ["phase2-keychain"]
        XCTAssertEqual(DiagnosticChecks.configurationMigration(marked).status, .warn)

        var cleanupPending = configuration
        cleanupPending.onboarding.legacyPlaintextCleanupPending = true
        XCTAssertEqual(DiagnosticChecks.configurationMigration(cleanupPending).status, .warn)
    }

    func testUnsafeConfigurationAncestorBlocksContextUsabilityAndDesiredState() {
        let primary = DoctorFixture.file(state: .valid, valid: true, schemaVersion: 1, generation: 1)
        let facts = ConfigurationDiagnosticFacts(
            directoryExists: true,
            directoryMode: 0o700,
            directoryPathSafe: false,
            primary: primary
        )

        XCTAssertFalse(DiagnosticChecks.isUsableConfigurationContext(facts))
        XCTAssertEqual(DiagnosticChecks.configurationRead(facts).status, .fail)
        XCTAssertEqual(DiagnosticChecks.configurationRecovery(facts).status, .fail)
    }

    func testReadOnlyConfigurationProviderMarksSymlinkedSupportAncestorUnsafe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let foreign = root.appendingPathComponent("foreign", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: support, withDestinationURL: foreign)
        defer { try? FileManager.default.removeItem(at: root) }

        let facts = try ReadOnlyConfigurationDiagnosticProvider(directoryURL: support).inspect()

        XCTAssertTrue(facts.directoryIsSymlink)
        XCTAssertFalse(facts.directoryPathSafe)
        XCTAssertFalse(DiagnosticChecks.isUsableConfigurationContext(facts))
    }

    func testManagedPermissionAdapterMapsRequesterProbeWithoutTCCClaims() throws {
        let provider = SystemManagedRuntimePermissionFactsProvider(
            runtimeDirectory: URL(fileURLWithPath: "/private/tmp/runtime"),
            checker: FixtureManagedPermissionChecker(facts: ManagedPermissionProbeFacts(
                accessibility: true,
                screenRecording: false,
                automation: true,
                activeConsole: true,
                unlocked: false
            ))
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.requesterIsManagedRuntime)
        XCTAssertTrue(facts.accessibility)
        XCTAssertFalse(facts.screenRecording)
        XCTAssertTrue(facts.activeConsole)
        XCTAssertTrue(facts.sessionLocked)
    }

    func testLogDirectoryPermissionBoundariesAndUpdateInspectionFailureAreStable() {
        XCTAssertEqual(
            DiagnosticChecks.logDirectoryPermissions(LogDirectoryFacts()).status,
            .skip
        )
        XCTAssertEqual(
            DiagnosticChecks.logDirectoryPermissions(LogDirectoryFacts(
                inspectionAvailable: true,
                exists: true,
                isDirectory: true,
                mode: 0o755
            )).status,
            .fail
        )
        XCTAssertEqual(
            DiagnosticChecks.logDirectoryPermissions(LogDirectoryFacts(
                inspectionAvailable: true,
                exists: true,
                isDirectory: true,
                mode: 0o700
            )).status,
            .pass
        )
        XCTAssertEqual(
            DiagnosticChecks.updateAvailability(UpdateAvailabilityFacts(inspectionFailed: true)).status,
            .warn
        )
    }

    func testInstallationVersionMismatchAndUnavailableIntegrityEvidenceAreConservative() {
        let healthy = InstalledReleaseFacts(
            releaseVersion: "1.0.0",
            helper: CodeSignFacts(version: "1.0.0", isSigned: true, developerIDTrusted: true),
            runtime: RuntimeFacts(runtimePresent: true, version: "2.0.0", markerPresent: true, payloadPresent: true, structurallyValid: true),
            helperPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.installationVersionMatch(healthy).status, .fail)
        XCTAssertEqual(DiagnosticChecks.installationVersionMatch(healthy).repair?.id, .rerunVerifiedBootstrap)

        let incomplete = InstalledReleaseFacts(
            helper: CodeSignFacts(isSigned: true),
            helperPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.installationIntegrity(incomplete).status, .warn)
        XCTAssertEqual(DiagnosticChecks.trustCodeSign(incomplete).status, .warn)
    }

    func testInstallationRuntimeIntegrityAndAdHocTrustBranches() {
        let healthy = InstalledReleaseFacts(
            releaseVersion: "1.0.0",
            helper: CodeSignFacts(
                version: "1.0.0",
                isSigned: true,
                developerIDTrusted: true,
                receiptAvailable: true,
                integrityAvailable: true
            ),
            runtime: RuntimeFacts(
                runtimePresent: true,
                version: "1.0.0",
                markerPresent: true,
                payloadPresent: true,
                structurallyValid: true
            ),
            helperPresent: true,
            ownershipMarkerPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.installationRuntime(healthy).status, .pass)
        XCTAssertEqual(DiagnosticChecks.installationIntegrity(healthy).status, .pass)
        XCTAssertEqual(DiagnosticChecks.installationVersionMatch(healthy).status, .pass)
        XCTAssertEqual(DiagnosticChecks.trustCodeSign(healthy).status, .pass)

        let incompleteVersions = InstalledReleaseFacts(
            releaseVersion: "1.0.0",
            helper: healthy.helper,
            runtime: RuntimeFacts(runtimePresent: true, markerPresent: true, payloadPresent: true, structurallyValid: true),
            helperPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.installationVersionMatch(incompleteVersions).status, .warn)

        let adHoc = InstalledReleaseFacts(
            helper: CodeSignFacts(isSigned: true, isAdHoc: true, developerIDTrusted: false),
            helperPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.trustCodeSign(adHoc).status, .warn)

        let unsigned = InstalledReleaseFacts(helper: CodeSignFacts(isSigned: false), helperPresent: true)
        XCTAssertEqual(DiagnosticChecks.trustCodeSign(unsigned).status, .fail)
        XCTAssertEqual(DiagnosticChecks.installationRuntime(InstalledReleaseFacts()).status, .fail)
    }

    func testCurrentCoreArchitectureAndBundleFactsAreReportedConservatively() {
        let healthy = InstalledReleaseFacts(
            helper: CodeSignFacts(
                bundleIdentifier: "com.jay.mac-orchestrator",
                architecture: "arm64",
                isSigned: true
            ),
            runtime: RuntimeFacts(
                runtimePresent: true,
                architecture: "arm64",
                markerPresent: true,
                payloadPresent: true,
                structurallyValid: true
            ),
            helperPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.installationHelperArchitecture(healthy).status, .pass)
        XCTAssertEqual(DiagnosticChecks.installationRuntimeArchitecture(healthy).status, .pass)
        XCTAssertEqual(DiagnosticChecks.installationHelperBundleIdentifier(healthy).status, .pass)

        let wrongArchitecture = InstalledReleaseFacts(
            helper: CodeSignFacts(bundleIdentifier: "com.jay.mac-orchestrator", architecture: "x86_64"),
            runtime: RuntimeFacts(runtimePresent: true, architecture: "x86_64"),
            helperPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.installationHelperArchitecture(wrongArchitecture).status, .fail)
        XCTAssertEqual(DiagnosticChecks.installationRuntimeArchitecture(wrongArchitecture).status, .fail)

        let unknownEvidence = InstalledReleaseFacts(helperPresent: true)
        XCTAssertEqual(DiagnosticChecks.installationHelperArchitecture(unknownEvidence).status, .warn)
        XCTAssertEqual(DiagnosticChecks.installationRuntimeArchitecture(unknownEvidence).status, .warn)
        XCTAssertEqual(DiagnosticChecks.installationHelperBundleIdentifier(unknownEvidence).status, .warn)

        let wrongBundle = InstalledReleaseFacts(
            helper: CodeSignFacts(bundleIdentifier: "com.example.other", architecture: "arm64"),
            helperPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.installationHelperBundleIdentifier(wrongBundle).status, .fail)
    }

    func testNgrokArchitectureAndVendorSigningFactsRemainExplicit() {
        let healthy = RemoteConnectorFacts(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            ownershipMarkerPresent: true,
            binaryArchitecture: "arm64",
            originalVendorSigning: true
        )
        XCTAssertEqual(DiagnosticChecks.remoteNgrokArchitecture(healthy, desired: true).status, .pass)
        XCTAssertEqual(DiagnosticChecks.remoteNgrokSigning(healthy, desired: true).status, .pass)

        let wrongArchitecture = RemoteConnectorFacts(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            ownershipMarkerPresent: true,
            binaryArchitecture: "x86_64",
            originalVendorSigning: false
        )
        XCTAssertEqual(DiagnosticChecks.remoteNgrokArchitecture(wrongArchitecture, desired: true).status, .fail)
        XCTAssertEqual(DiagnosticChecks.remoteNgrokSigning(wrongArchitecture, desired: true).status, .warn)

        let unknown = RemoteConnectorFacts(desired: true, binaryPresent: true)
        XCTAssertEqual(DiagnosticChecks.remoteNgrokArchitecture(unknown, desired: true).status, .warn)
        XCTAssertEqual(DiagnosticChecks.remoteNgrokSigning(unknown, desired: true).status, .warn)
        XCTAssertEqual(DiagnosticChecks.remoteNgrokArchitecture(nil, desired: false).status, .skip)
        XCTAssertEqual(DiagnosticChecks.remoteNgrokSigning(nil, desired: false).status, .skip)
    }

    func testTelegramSendPresenceDistinguishesAbsentAndInaccessibleItems() {
        XCTAssertEqual(
            DiagnosticChecks.keychainTelegramSend(
                KeychainPresenceFacts(states: [
                    .telegramSendBotToken: .absent,
                    .telegramSendChatID: .present,
                ]),
                desired: true
            ).status,
            .fail
        )
        XCTAssertEqual(
            DiagnosticChecks.keychainTelegramSend(
                KeychainPresenceFacts(states: [
                    .telegramSendBotToken: .inaccessible,
                    .telegramSendChatID: .present,
                ]),
                desired: true
            ).status,
            .warn
        )
    }

    func testPermissionFailuresAndLockedNonConsoleSessionsKeepRequesterTruth() {
        var configuration = AppConfiguration(ownerID: "owner")
        configuration.desiredCapabilities["mac.ui"] = true
        configuration.desiredCapabilities["mac.screenOcr"] = true

        let cases: [(PermissionFacts, RepairActionID?)] = [
            (PermissionFacts(accessibility: false, screenRecording: true, automation: true, activeConsole: true, requesterIsManagedRuntime: true), .openAccessibilitySettings),
            (PermissionFacts(accessibility: true, screenRecording: false, automation: true, activeConsole: true, requesterIsManagedRuntime: true), .openScreenRecordingSettings),
            (PermissionFacts(accessibility: true, screenRecording: true, automation: false, activeConsole: true, requesterIsManagedRuntime: true), .openAutomationSettings),
        ]

        for (facts, repair) in cases {
            let result = DiagnosticChecks.permissionsRequester(facts, configuration: configuration)
            XCTAssertEqual(result.status, .fail)
            XCTAssertEqual(result.repair?.id, repair)
        }

        XCTAssertEqual(
            DiagnosticChecks.permissionsRequester(
                PermissionFacts(activeConsole: false, requesterIsManagedRuntime: true),
                configuration: configuration
            ).status,
            .fail
        )
        XCTAssertEqual(
            DiagnosticChecks.permissionsRequester(
                PermissionFacts(activeConsole: true, sessionLocked: true, requesterIsManagedRuntime: true),
                configuration: configuration
            ).status,
            .fail
        )
        XCTAssertEqual(
            DiagnosticChecks.permissionsRequester(
                PermissionFacts(requesterIsManagedRuntime: false),
                configuration: configuration
            ).status,
            .skip
        )
        XCTAssertEqual(DiagnosticChecks.keychainConnector(KeychainPresenceFacts()).status, .skip)
        XCTAssertEqual(
            DiagnosticChecks.keychainConnector(KeychainPresenceFacts(states: [.connectorToken: .inaccessible])).status,
            .warn
        )
    }

    func testMCPLivenessNotReadyAndInventoryMismatchRemainDistinct() {
        let failed = LocalMCPFacts()
        XCTAssertEqual(DiagnosticChecks.mcpLiveness(failed, desired: true).status, .fail)
        XCTAssertEqual(DiagnosticChecks.mcpLiveness(failed, desired: true).repair?.id, .retryMCPServer)

        let notReady = LocalMCPFacts(livenessVerified: true)
        XCTAssertEqual(DiagnosticChecks.mcpReadiness(notReady, desired: true).status, .fail)
        XCTAssertEqual(DiagnosticChecks.mcpReadiness(notReady, desired: true).repair?.id, .retryMCPServer)

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
        XCTAssertEqual(DiagnosticChecks.mcpInventory(mismatch, desired: true).status, .fail)
        XCTAssertEqual(DiagnosticChecks.mcpInventory(mismatch, desired: true).repair?.id, .retryMCPServer)

        let partialReadiness = LocalMCPFacts(
            livenessVerified: true,
            readinessVerified: true,
            sessionEstablished: false,
            safeCallSucceeded: true,
            expectedTools: ["describe"],
            exposedTools: ["describe"],
            expectedCapabilityGroups: ["core.session"],
            exposedCapabilityGroups: ["core.session"]
        )
        XCTAssertEqual(DiagnosticChecks.mcpInventory(partialReadiness, desired: true).status, .skip)
    }

    func testOwnedAndMalformedPortsAreDistinguished() {
        XCTAssertEqual(
            DiagnosticChecks.portSelected(PortFacts(port: 8000), configuredPort: 8000).status,
            .pass
        )
        XCTAssertEqual(
            DiagnosticChecks.portSelected(
                PortFacts(port: 8000, listenerPresent: true, listenerOwned: true),
                configuredPort: 8000
            ).status,
            .pass
        )

        for malformedPort in [0, 65_536] {
            let result = DiagnosticChecks.portSelected(PortFacts(port: malformedPort), configuredPort: malformedPort)
            XCTAssertEqual(result.status, .fail)
            XCTAssertEqual(result.repair?.id, .reassignLocalPort)
        }

        let occupied = DiagnosticChecks.portSelected(
            PortFacts(port: 8000, listenerPresent: true, listenerOwned: false),
            configuredPort: 8000
        )
        XCTAssertEqual(occupied.status, .fail)
        XCTAssertEqual(occupied.repair?.id, .reassignLocalPort)
    }

    func testLifecycleRemoteDiskUpdateAndFutureBranches() {
        let malformedLaunchAgent = LifecycleFacts(launchAgentPresent: true, launchAgentValid: false)
        XCTAssertEqual(DiagnosticChecks.lifecycleLaunchAgent(malformedLaunchAgent, desired: true).status, .fail)
        XCTAssertEqual(DiagnosticChecks.lifecycleLaunchAgent(malformedLaunchAgent, desired: true).repair?.id, .repairLaunchAgent)

        let staleLaunchAgent = LifecycleFacts(launchAgentPresent: true, launchAgentValid: false, serviceRunning: true)
        XCTAssertEqual(DiagnosticChecks.lifecycleLaunchAgent(staleLaunchAgent, desired: true).status, .fail)

        let reusedPID = LifecycleFacts(ownershipMarkerPresent: true, pidReuseDetected: true)
        XCTAssertEqual(DiagnosticChecks.lifecycleProcessOwnership(reusedPID, desired: true).status, .fail)
        XCTAssertEqual(DiagnosticChecks.lifecycleProcessOwnership(reusedPID, desired: true).repair?.id, .retryMCPServer)

        let stoppedService = LifecycleFacts(
            launchAgentPresent: true,
            launchAgentValid: true,
            serviceRunning: false,
            ownedProcessCount: 1,
            ownershipMarkerPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.lifecycleLaunchAgent(stoppedService, desired: true).status, .pass)
        XCTAssertEqual(DiagnosticChecks.lifecycleProcessOwnership(stoppedService, desired: true).status, .fail)
        XCTAssertEqual(DiagnosticChecks.lifecycleProcessOwnership(stoppedService, desired: true).repair?.id, .retryMCPServer)

        let noOwnedProcesses = LifecycleFacts(
            launchAgentPresent: true,
            launchAgentValid: true,
            serviceRunning: true,
            ownedProcessCount: 0,
            ownershipMarkerPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.lifecycleProcessOwnership(noOwnedProcesses, desired: true).status, .fail)
        XCTAssertEqual(DiagnosticChecks.lifecycleProcessOwnership(noOwnedProcesses, desired: true).repair?.id, .retryMCPServer)

        let remote = RemoteConnectorFacts(desired: true, binaryPresent: true, configurationPresent: false)
        XCTAssertEqual(DiagnosticChecks.remoteNgrok(remote, auth: .present, desired: true).status, .fail)
        XCTAssertEqual(DiagnosticChecks.remoteNgrok(remote, auth: .absent, desired: true).repair?.id, .replaceNgrokCredential)
        XCTAssertEqual(DiagnosticChecks.remoteEndpoint(remote, desired: true).status, .fail)

        let healthyRemote = RemoteConnectorFacts(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            endpointAvailable: true,
            endpointCount: 1,
            ownershipMarkerPresent: true
        )
        XCTAssertEqual(DiagnosticChecks.remoteNgrok(healthyRemote, auth: .present, desired: true).status, .pass)
        XCTAssertEqual(DiagnosticChecks.remoteEndpoint(healthyRemote, desired: true).status, .pass)

        XCTAssertEqual(DiagnosticChecks.remoteNgrok(nil, auth: nil, desired: false).status, .skip)
        XCTAssertEqual(DiagnosticChecks.remoteEndpoint(nil, desired: false).status, .skip)
        XCTAssertEqual(DiagnosticChecks.updateAvailability(nil).status, .skip)
        XCTAssertEqual(DiagnosticChecks.updateAvailability(UpdateAvailabilityFacts(status: .current)).status, .pass)
        XCTAssertEqual(DiagnosticChecks.updateAvailability(UpdateAvailabilityFacts(status: .available)).status, .warn)
        XCTAssertEqual(DiagnosticChecks.futureCapability("capability.future", title: "Future").status, .skip)

        XCTAssertEqual(DiagnosticChecks.diskFreeSpace(nil, thresholdBytes: 1).status, .fail)
        XCTAssertEqual(DiagnosticChecks.diskFreeSpace(DiskSpaceFacts(filesystemAccessible: false), thresholdBytes: 1).status, .fail)
        XCTAssertEqual(DiagnosticChecks.diskFreeSpace(DiskSpaceFacts(filesystemAccessible: true, availableBytes: nil), thresholdBytes: 1).status, .skip)
        XCTAssertEqual(DiagnosticChecks.diskFreeSpace(DiskSpaceFacts(filesystemAccessible: true, availableBytes: 100), thresholdBytes: nil).status, .skip)
        XCTAssertEqual(DiagnosticChecks.diskFreeSpace(DiskSpaceFacts(filesystemAccessible: true, availableBytes: 100), thresholdBytes: 100).status, .pass)
        XCTAssertEqual(DiagnosticChecks.diskFreeSpace(DiskSpaceFacts(filesystemAccessible: true, availableBytes: 99), thresholdBytes: 100).status, .warn)
        XCTAssertEqual(DiagnosticChecks.criticalPaths(DiskSpaceFacts(filesystemAccessible: true, criticalPathSymlinkCount: 0)).status, .pass)
        XCTAssertEqual(DiagnosticChecks.criticalPaths(DiskSpaceFacts(filesystemAccessible: true, criticalPathSymlinkCount: 1)).status, .fail)
    }

    func testRemoteChecksDistinguishPrerequisitesProviderStatesAndAuthenticatedReadiness() {
        let invalidNgrok = RemoteConnectorFacts(
            desired: true,
            binaryPresent: false,
            configurationPresent: true,
            localMCPPrerequisite: .available
        )
        XCTAssertEqual(
            DiagnosticChecks.remoteNgrok(invalidNgrok, auth: .present, desired: true).status,
            .fail
        )

        let credentialAbsent = RemoteConnectorFacts(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            ownershipMarkerPresent: true,
            localMCPPrerequisite: .available
        )
        let absent = DiagnosticChecks.remoteNgrok(credentialAbsent, auth: .absent, desired: true)
        XCTAssertEqual(absent.status, .fail)
        XCTAssertEqual(absent.repair?.id, .replaceNgrokCredential)
        XCTAssertTrue(absent.reason.localizedCaseInsensitiveContains("absent"))

        let inaccessible = DiagnosticChecks.remoteNgrok(credentialAbsent, auth: .inaccessible, desired: true)
        XCTAssertEqual(inaccessible.status, .warn)
        XCTAssertEqual(inaccessible.repair?.id, .replaceNgrokCredential)
        XCTAssertTrue(inaccessible.reason.localizedCaseInsensitiveContains("inaccessible"))

        let rejectedCredential = RemoteConnectorFacts(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            ownershipMarkerPresent: true,
            providerCredentialState: .rejected,
            localMCPPrerequisite: .available
        )
        let rejected = DiagnosticChecks.remoteNgrok(rejectedCredential, auth: .present, desired: true)
        XCTAssertEqual(rejected.status, .fail)
        XCTAssertEqual(rejected.repair?.id, .replaceNgrokCredential)
        XCTAssertTrue(rejected.reason.localizedCaseInsensitiveContains("provider credential"))

        for processState in [RemoteManagedProcessState.missing, .ambiguous] {
            let processFacts = RemoteConnectorFacts(
                desired: true,
                binaryPresent: true,
                configurationPresent: true,
                ownershipMarkerPresent: processState == .owned,
                managedProcessState: processState,
                localMCPPrerequisite: .available
            )
            XCTAssertEqual(
                DiagnosticChecks.remoteNgrok(processFacts, auth: .present, desired: true).status,
                .fail
            )
        }

        for agentState in [RemoteAgentAPIState.unavailable, .malformed] {
            let agentFacts = RemoteConnectorFacts(
                desired: true,
                binaryPresent: true,
                configurationPresent: true,
                endpointState: .notObserved,
                agentAPIState: agentState,
                localMCPPrerequisite: .available
            )
            let endpoint = DiagnosticChecks.remoteEndpoint(agentFacts, desired: true)
            XCTAssertEqual(endpoint.status, .fail)
            XCTAssertTrue(endpoint.reason.localizedCaseInsensitiveContains(agentState == .unavailable ? "unavailable" : "malformed"))
        }

        for endpointState in [
            RemoteEndpointState.noExpectedUpstream,
            .foreignOnly,
            .ambiguous
        ] {
            let endpointFacts = RemoteConnectorFacts(
                desired: true,
                binaryPresent: true,
                configurationPresent: true,
                endpointState: endpointState,
                agentAPIState: .available,
                localMCPPrerequisite: .available
            )
            XCTAssertEqual(DiagnosticChecks.remoteEndpoint(endpointFacts, desired: true).status, .fail)
        }

        let endpointOnly = RemoteConnectorFacts(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            endpointAvailable: true,
            endpointCount: 1,
            ownershipMarkerPresent: true,
            localMCPPrerequisite: .available
        )
        XCTAssertEqual(DiagnosticChecks.remoteEndpoint(endpointOnly, desired: true).status, .pass)
        XCTAssertEqual(DiagnosticChecks.remoteAuthenticatedReadiness(endpointOnly, desired: true).status, .warn)

        let authenticatedCases: [(RemoteAuthenticatedMCPFacts, DiagnosticStatus)] = [
            (RemoteAuthenticatedMCPFacts(probeAvailable: true, probeRun: true, authenticationSucceeded: false), .fail),
            (RemoteAuthenticatedMCPFacts(probeAvailable: true, probeRun: true, authenticationSucceeded: true), .fail),
            (RemoteAuthenticatedMCPFacts(
                probeAvailable: true,
                probeRun: true,
                authenticationSucceeded: true,
                initializeSucceeded: true,
                sessionEstablished: true,
                inventoryChecked: true,
                expectedTools: ["describe"],
                exposedTools: ["other"]
            ), .fail),
            (RemoteAuthenticatedMCPFacts(
                probeAvailable: true,
                probeRun: true,
                authenticationSucceeded: true,
                initializeSucceeded: true,
                sessionEstablished: true,
                inventoryChecked: true,
                expectedTools: ["describe"],
                exposedTools: ["describe"],
                safeCallChecked: true,
                safeCallSucceeded: false
            ), .fail),
        ]
        for (authenticated, expectedStatus) in authenticatedCases {
            let facts = RemoteConnectorFacts(
                desired: true,
                binaryPresent: true,
                configurationPresent: true,
                endpointState: .established,
                agentAPIState: .available,
                authenticatedReadiness: authenticated,
                localMCPPrerequisite: .available
            )
            XCTAssertEqual(DiagnosticChecks.remoteAuthenticatedReadiness(facts, desired: true).status, expectedStatus)
        }

        let mismatch = RemoteConnectorFacts(
            desired: true,
            endpointState: .established,
            agentAPIState: .available,
            authenticatedReadiness: authenticatedCases[2].0,
            localMCPPrerequisite: .available
        )
        XCTAssertEqual(DiagnosticChecks.remoteInventory(mismatch, desired: true).status, .fail)

        let readyChanged = RemoteConnectorFacts(
            desired: true,
            endpointAvailable: true,
            endpointState: .established,
            agentAPIState: .available,
            authenticatedReadiness: RemoteAuthenticatedMCPFacts(
                probeAvailable: true,
                probeRun: true,
                authenticationSucceeded: true,
                initializeSucceeded: true,
                sessionEstablished: true,
                inventoryChecked: true,
                expectedTools: ["describe"],
                exposedTools: ["describe"],
                safeCallChecked: true,
                safeCallSucceeded: true,
                clientHandoff: .changed
            ),
            localMCPPrerequisite: .available
        )
        XCTAssertEqual(DiagnosticChecks.remoteAuthenticatedReadiness(readyChanged, desired: true).status, .pass)
        XCTAssertEqual(DiagnosticChecks.remoteInventory(readyChanged, desired: true).status, .pass)
        let handoff = DiagnosticChecks.remoteClientHandoff(readyChanged, desired: true)
        XCTAssertEqual(handoff.status, .warn)
        XCTAssertEqual(handoff.repair?.id, .reconfigureRemoteClients)

        let unchanged = RemoteConnectorFacts(
            desired: true,
            endpointAvailable: true,
            endpointState: .established,
            agentAPIState: .available,
            authenticatedReadiness: RemoteAuthenticatedMCPFacts(
                probeAvailable: true,
                probeRun: true,
                authenticationSucceeded: true,
                initializeSucceeded: true,
                sessionEstablished: true,
                inventoryChecked: true,
                expectedTools: ["describe"],
                exposedTools: ["describe"],
                safeCallChecked: true,
                safeCallSucceeded: true,
                clientHandoff: .unchanged
            ),
            localMCPPrerequisite: .available
        )
        XCTAssertEqual(DiagnosticChecks.remoteClientHandoff(unchanged, desired: true).status, .pass)

        let noReceipt = RemoteConnectorFacts(
            desired: true,
            endpointAvailable: true,
            endpointState: .established,
            agentAPIState: .available,
            authenticatedReadiness: RemoteAuthenticatedMCPFacts(
                probeAvailable: true,
                probeRun: true,
                authenticationSucceeded: true,
                initializeSucceeded: true,
                sessionEstablished: true,
                inventoryChecked: true,
                expectedTools: ["describe"],
                exposedTools: ["describe"],
                safeCallChecked: true,
                safeCallSucceeded: true
            ),
            localMCPPrerequisite: .available
        )
        let noReceiptResult = DiagnosticChecks.remoteClientHandoff(noReceipt, desired: true)
        XCTAssertEqual(noReceiptResult.status, .skip)
        XCTAssertTrue(noReceiptResult.reason.localizedCaseInsensitiveContains("no client"))

        let localUnavailable = RemoteConnectorFacts(
            desired: true,
            endpointState: .established,
            agentAPIState: .available,
            localMCPPrerequisite: .unavailable
        )
        for result in [
            DiagnosticChecks.remoteNgrok(localUnavailable, auth: .absent, desired: true),
            DiagnosticChecks.remoteEndpoint(localUnavailable, desired: true),
            DiagnosticChecks.remoteAuthenticatedReadiness(localUnavailable, desired: true),
            DiagnosticChecks.remoteInventory(localUnavailable, desired: true),
            DiagnosticChecks.remoteClientHandoff(localUnavailable, desired: true),
        ] {
            XCTAssertEqual(result.status, .skip)
            XCTAssertTrue(result.reason.localizedCaseInsensitiveContains("local MCP"))
        }
    }

    func testContradictoryEndpointFactsFailClosedAndAuthPathMismatchRecommendsRetry() {
        let contradictory = RemoteConnectorFacts(
            desired: true,
            endpointAvailable: true,
            endpointState: .notObserved,
            localMCPPrerequisite: .available
        )
        XCTAssertEqual(
            DiagnosticChecks.remoteEndpoint(contradictory, desired: true).status,
            .fail
        )

        let authRejected = RemoteConnectorFacts(
            desired: true,
            endpointAvailable: true,
            endpointState: .established,
            agentAPIState: .available,
            localMCPPrerequisite: .available,
            authenticatedReadiness: RemoteAuthenticatedMCPFacts(
                probeAvailable: true,
                probeRun: true,
                authenticationSucceeded: false
            )
        )
        let result = DiagnosticChecks.remoteAuthenticatedReadiness(authRejected, desired: true)
        XCTAssertEqual(result.status, .fail)
        XCTAssertEqual(result.repair?.id, .retryRemoteConnector)
        XCTAssertNotEqual(result.repair?.id, .rotateConnectorCredential)
    }

    func testRemoteAuthenticatedProbeIsOnlyRunAfterLocalAndEndpointPrerequisites() async {
        let readyProvider = RecordingRemoteAuthenticatedProvider(facts: .readyFixture)
        let readyFixture = DoctorFixture.make(
            remoteDesired: true,
            remoteAuthenticatedProvider: readyProvider
        )
        let readyReport = await DoctorEngine(dependencies: readyFixture.dependencies).run()

        XCTAssertEqual(readyProvider.calls, 1)
        XCTAssertEqual(readyReport.result(withID: "remote.endpoint")?.status, .pass)
        XCTAssertEqual(readyReport.result(withID: "remote.authenticated-readiness")?.status, .pass)
        XCTAssertEqual(readyReport.result(withID: "remote.inventory")?.status, .pass)
        XCTAssertEqual(readyReport.result(withID: "capability.meridian")?.status, .skip)
        XCTAssertEqual(readyReport.result(withID: "capability.cloudflare")?.status, .skip)

        let blockedProvider = RecordingRemoteAuthenticatedProvider(facts: .readyFixture)
        let blockedFixture = DoctorFixture.make(
            remoteDesired: true,
            asyncLocalMCPProvider: RecordingAsyncLocalProvider(facts: LocalMCPFacts()),
            remoteAuthenticatedProvider: blockedProvider
        )
        let blockedReport = await DoctorEngine(dependencies: blockedFixture.dependencies).run()

        XCTAssertEqual(blockedProvider.calls, 0)
        for id in ["remote.ngrok", "remote.endpoint", "remote.authenticated-readiness", "remote.inventory", "remote.client-handoff"] {
            XCTAssertEqual(blockedReport.result(withID: id)?.status, .skip, id)
        }
    }

    func testDoctorGathersContextBeforeProvidersAndSkipsDisabledDependencies() async throws {
        let fixture = DoctorFixture.make(serverDesired: false, remoteDesired: false)
        let report = await DoctorEngine(dependencies: fixture.dependencies).run()

        XCTAssertEqual(report.result(withID: "mcp.liveness")?.status, .skip)
        XCTAssertEqual(report.result(withID: "remote.ngrok")?.status, .skip)
        XCTAssertEqual(report.result(withID: "lifecycle.launch-agent")?.status, .skip)
        XCTAssertEqual(report.result(withID: "keychain.connector")?.status, .skip)
        XCTAssertTrue(fixture.local.calls.isEmpty)
        XCTAssertTrue(fixture.remote.calls.isEmpty)
        XCTAssertTrue(fixture.lifecycle.calls.isEmpty)
        XCTAssertTrue(fixture.keychain.requests.isEmpty)
        XCTAssertTrue(fixture.keychain.valueRetrievalCalls.isEmpty)
    }

    func testNoValidatedContextMakesDependentResultsPrerequisiteSafe() async {
        let fixture = DoctorFixture.make(validatedContext: false, serverDesired: true, remoteDesired: true)
        let report = await DoctorEngine(dependencies: fixture.dependencies).run()

        XCTAssertEqual(report.result(withID: "mcp.liveness")?.status, .skip)
        XCTAssertEqual(report.result(withID: "remote.ngrok")?.status, .skip)
        XCTAssertEqual(report.result(withID: "lifecycle.launch-agent")?.status, .skip)
        XCTAssertEqual(report.result(withID: "keychain.connector")?.status, .skip)
        XCTAssertEqual(report.result(withID: "port.selected")?.status, .skip)
        XCTAssertTrue(fixture.local.calls.isEmpty)
        XCTAssertTrue(fixture.remote.calls.isEmpty)
        XCTAssertTrue(fixture.lifecycle.calls.isEmpty)
        XCTAssertTrue(fixture.keychain.requests.isEmpty)
    }

    func testRemoteFactsCannotEnableRemoteDiagnosis() async {
        let fixture = DoctorFixture.make(serverDesired: false, remoteDesired: false)
        fixture.remote.facts = RemoteConnectorFacts(desired: true, binaryPresent: true, configurationPresent: true, endpointAvailable: true, endpointCount: 1, ownershipMarkerPresent: true)

        let report = await DoctorEngine(dependencies: fixture.dependencies).run()

        XCTAssertEqual(report.result(withID: "remote.ngrok")?.status, .skip)
        XCTAssertEqual(report.result(withID: "remote.endpoint")?.status, .skip)
        XCTAssertTrue(fixture.remote.calls.isEmpty)
    }

    func testDisabledLocalDoesNotFetchConnectorTokenWhileRemoteChecksOnlyNgrok() async {
        let asyncProvider = RecordingAsyncLocalProvider()
        let fixture = DoctorFixture.make(
            serverDesired: false,
            remoteDesired: true,
            asyncLocalMCPProvider: asyncProvider
        )

        let report = await DoctorEngine(dependencies: fixture.dependencies).run()

        XCTAssertEqual(report.result(withID: "mcp.liveness")?.status, .skip)
        XCTAssertEqual(report.result(withID: "keychain.connector")?.status, .skip)
        XCTAssertTrue(fixture.keychain.requests.contains([.ngrokAuthtoken]))
        XCTAssertFalse(fixture.keychain.requests.contains(.init([.connectorToken, .ngrokAuthtoken])))
        XCTAssertTrue(fixture.local.calls.isEmpty)
        XCTAssertEqual(asyncProvider.calls, 0)
    }

    func testTelegramSendPresenceIsQueriedOnlyWhenDesired() async {
        var configuration = AppConfiguration(
            process: ProcessConfiguration(serverDesired: false, tunnelDesired: false),
            ownerID: "telegram-owner"
        )
        configuration.desiredCapabilities["telegram.send"] = true
        let fixture = DoctorFixture.make(
            validatedConfiguration: configuration,
            serverDesired: false,
            remoteDesired: false
        )

        let report = await DoctorEngine(dependencies: fixture.dependencies).run()

        XCTAssertEqual(
            fixture.keychain.requests,
            [Set([.telegramSendBotToken, .telegramSendChatID])]
        )
        XCTAssertEqual(report.result(withID: "keychain.telegram-send")?.status, .pass)
    }

    func testDisabledTelegramSendIsSkippedWithoutAKeychainQuery() async {
        let fixture = DoctorFixture.make(serverDesired: false, remoteDesired: false)

        let report = await DoctorEngine(dependencies: fixture.dependencies).run()

        XCTAssertEqual(report.result(withID: "keychain.telegram-send")?.status, .skip)
        XCTAssertTrue(fixture.keychain.requests.isEmpty)
    }

    func testSystemDoctorKeychainProviderSelectsRequestedCurrentCorePresenceOnly() throws {
        let querying = RecordingKeychainPresenceQuery()
        let dependencies = DoctorDependencies(
            keychainPresenceProvider: SystemDoctorKeychainPresenceProvider(querying: querying)
        )
        let requested: Set<KeychainPresenceItem> = [
            .connectorToken,
            .ngrokAuthtoken,
            .meridianTelegramBotToken,
        ]

        let facts = try dependencies.keychainPresenceProvider.inspect(items: requested)

        XCTAssertEqual(
            Set(querying.requests.map(\.item)),
            Set<KeychainPresenceItem>([.connectorToken, .ngrokAuthtoken])
        )
        XCTAssertEqual(querying.requests.count, 2)
        XCTAssertTrue(querying.requests.allSatisfy { !$0.requestsData })
        XCTAssertEqual(
            Set(facts.states.keys),
            Set<KeychainPresenceItem>([.connectorToken, .ngrokAuthtoken])
        )
        XCTAssertEqual(
            facts,
            KeychainPresenceFacts(states: [
                .connectorToken: .present,
                .ngrokAuthtoken: .present,
            ])
        )
        XCTAssertTrue(facts.states.values.allSatisfy { $0 == .present })
    }

    func testPermissionProviderRequiresAConfiguredLocalProtectedConsumer() async {
        let disabled = DoctorFixture.make(serverDesired: false, remoteDesired: false)
        let disabledReport = await DoctorEngine(dependencies: disabled.dependencies).run()
        XCTAssertEqual(disabledReport.result(withID: "permissions.requester")?.status, .skip)
        XCTAssertTrue(disabled.permission.calls.isEmpty)

        let remoteOnly = DoctorFixture.make(serverDesired: false, remoteDesired: true)
        let remoteReport = await DoctorEngine(dependencies: remoteOnly.dependencies).run()
        XCTAssertEqual(remoteReport.result(withID: "permissions.requester")?.status, .skip)
        XCTAssertTrue(remoteOnly.permission.calls.isEmpty)

        let local = DoctorFixture.make(serverDesired: true, remoteDesired: false)
        _ = await DoctorEngine(dependencies: local.dependencies).run()
        XCTAssertEqual(local.permission.calls.count, 1)
    }

    func testSuccessfulAsyncCanonicalMCPProviderWinsOverSyncProvider() async {
        let asyncProvider = RecordingAsyncLocalProvider(facts: LocalMCPFacts(
            livenessVerified: true,
            readinessVerified: true,
            sessionEstablished: true,
            safeCallSucceeded: true,
            expectedTools: ["describe"],
            exposedTools: ["describe"],
            expectedCapabilityGroups: ["core.session"],
            exposedCapabilityGroups: ["core.session"]
        ))
        let fixture = DoctorFixture.make(asyncLocalMCPProvider: asyncProvider)

        let report = await DoctorEngine(dependencies: fixture.dependencies).run()

        XCTAssertEqual(asyncProvider.calls, 1)
        XCTAssertTrue(fixture.local.calls.isEmpty)
        XCTAssertEqual(report.result(withID: "mcp.inventory")?.status, .pass)
    }

    func testMutationFreeNegativeControlSnapshotsExistingConfigAndAllProviderCalls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("config.json")
        var configuration = AppConfiguration(
            process: ProcessConfiguration(serverDesired: false, tunnelDesired: false),
            ownerID: "fixture"
        )
        configuration.desiredCapabilities["mac.ui"] = false
        configuration.desiredCapabilities["mac.screenOcr"] = false
        configuration.desiredCapabilities["remote.connector"] = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(configuration)
        try bytes.write(to: primary)
        let beforeEntries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let beforeBytes = try Data(contentsOf: primary)
        let beforeGeneration = try JSONDecoder().decode(AppConfiguration.self, from: beforeBytes).generation

        let fixture = DoctorFixture.make(
            serverDesired: false,
            remoteDesired: false,
            configurationContextProvider: ReadOnlyDoctorConfigurationContextProvider(directoryURL: root)
        )
        let beforeCalls = fixture.mutationSnapshot
        let report = await DoctorEngine(dependencies: fixture.dependencies).run()
        let afterBytes = try Data(contentsOf: primary)
        let afterGeneration = try JSONDecoder().decode(AppConfiguration.self, from: afterBytes).generation
        let afterEntries = try FileManager.default.contentsOfDirectory(atPath: root.path)

        XCTAssertEqual(afterBytes, beforeBytes)
        XCTAssertEqual(afterGeneration, beforeGeneration)
        XCTAssertEqual(afterEntries, beforeEntries)
        XCTAssertEqual(fixture.mutationSnapshot, beforeCalls)
        XCTAssertTrue(fixture.keychain.createCalls.isEmpty)
        XCTAssertTrue(fixture.keychain.updateCalls.isEmpty)
        XCTAssertTrue(fixture.keychain.tokenGenerationCalls.isEmpty)
        XCTAssertTrue(fixture.keychain.valueRetrievalCalls.isEmpty)
        XCTAssertTrue(fixture.permission.calls.isEmpty)
        XCTAssertTrue(fixture.local.calls.isEmpty)
        XCTAssertTrue(fixture.remote.calls.isEmpty)
        XCTAssertTrue(fixture.lifecycle.calls.isEmpty)
        XCTAssertTrue(fixture.keychain.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("archive").path))
        XCTAssertEqual(report.results.compactMap(\.repair), [])
    }

    func testDoctorReportIsSortedAndUsesInjectedClock() async {
        let fixture = DoctorFixture.make()
        let report = await DoctorEngine(dependencies: fixture.dependencies).run()

        XCTAssertEqual(report.generatedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(report.results.map(\.id), report.results.map(\.id).sorted())
    }
}

private struct DoctorFixture {
    let dependencies: DoctorDependencies
    let local: RecordingLocalProvider
    let remote: RecordingRemoteProvider
    let lifecycle: RecordingLifecycleProvider
    let keychain: RecordingDoctorKeychainProvider
    let permission: RecordingPermissionProvider

    var mutationSnapshot: MutationSnapshot {
        MutationSnapshot(
            createCalls: keychain.createCalls,
            updateCalls: keychain.updateCalls,
            tokenGenerationCalls: keychain.tokenGenerationCalls,
            valueRetrievalCalls: keychain.valueRetrievalCalls
        )
    }

    static func make(
        configurationError: DiagnosticProviderError? = nil,
        validatedConfiguration: AppConfiguration? = nil,
        validatedContext: Bool = true,
        serverDesired: Bool = true,
        remoteDesired: Bool = false,
        asyncLocalMCPProvider: (any DoctorAsyncLocalMCPDiagnosticProviding)? = nil,
        remoteAuthenticatedProvider: (any RemoteAuthenticatedMCPDiagnosticProviding)? = nil,
        configurationContextProvider: (any DoctorConfigurationContextProviding)? = nil
    ) -> DoctorFixture {
        var configuration = validatedConfiguration ?? AppConfiguration(
            process: ProcessConfiguration(serverDesired: serverDesired, tunnelDesired: remoteDesired),
            ownerID: "fixture-owner"
        )
        configuration.process.serverDesired = serverDesired
        configuration.process.tunnelDesired = remoteDesired
        configuration.desiredCapabilities["remote.connector"] = remoteDesired

        let facts = ConfigurationDiagnosticFacts(
            directoryExists: true,
            directoryMode: 0o700,
            primary: file(state: .valid, valid: true, schemaVersion: configuration.schemaVersion, generation: configuration.generation),
            backup: file(state: .valid, valid: true, schemaVersion: configuration.schemaVersion, generation: configuration.generation)
        )
        let context: any DoctorConfigurationContextProviding
        if let configurationContextProvider {
            context = configurationContextProvider
        } else {
            context = FixtureConfigurationContextProvider(
                snapshot: DoctorConfigurationSnapshot(
                    facts: facts,
                    validatedConfiguration: validatedContext ? (validatedConfiguration ?? configuration) : nil
                ),
                error: configurationError
            )
        }
        let local = RecordingLocalProvider(facts: LocalMCPFacts(
            livenessVerified: true,
            readinessVerified: true,
            sessionEstablished: true,
            safeCallSucceeded: true,
            expectedTools: ["describe"],
            exposedTools: ["describe"],
            expectedCapabilityGroups: ["core.session"],
            exposedCapabilityGroups: ["core.session"]
        ))
        let remote = RecordingRemoteProvider(facts: RemoteConnectorFacts(
            desired: remoteDesired,
            binaryPresent: remoteDesired,
            configurationPresent: remoteDesired,
            endpointAvailable: remoteDesired,
            endpointCount: remoteDesired ? 1 : 0,
            ownershipMarkerPresent: remoteDesired
        ))
        let lifecycle = RecordingLifecycleProvider(facts: LifecycleFacts(
            launchAgentPresent: true,
            launchAgentValid: true,
            serviceRunning: true,
            ownedProcessCount: 1,
            ownershipMarkerPresent: true
        ))
        let keychain = RecordingDoctorKeychainProvider()
        let permission = RecordingPermissionProvider(facts: PermissionFacts(
            accessibility: true,
            screenRecording: true,
            automation: true,
            activeConsole: true,
            requesterIsManagedRuntime: true
        ))

        let dependencies = DoctorDependencies(
            configurationContextProvider: context,
            installedReleaseProvider: FixtureInstalledProvider(),
            permissionProvider: permission,
            keychainPresenceProvider: keychain,
            portProvider: FixturePortProvider(facts: PortFacts(port: configuration.localMCPPort)),
            localMCPProvider: local,
            asyncLocalMCPProvider: asyncLocalMCPProvider,
            remoteAuthenticatedMCPProvider: remoteAuthenticatedProvider,
            lifecycleProvider: lifecycle,
            remoteConnectorProvider: remote,
            diskSpaceProvider: FixtureDiskProvider(facts: DiskSpaceFacts(filesystemAccessible: true, availableBytes: 10_000)),
            updateProvider: FixtureUpdateProvider(facts: UpdateAvailabilityFacts()),
            thresholds: DoctorThresholds(lowDiskBytes: 1_000),
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        return DoctorFixture(
            dependencies: dependencies,
            local: local,
            remote: remote,
            lifecycle: lifecycle,
            keychain: keychain,
            permission: permission
        )
    }

    static func file(
        state: ConfigurationFileObservationState,
        valid: Bool = false,
        schemaVersion: Int? = nil,
        generation: Int? = nil,
        isSymlink: Bool = false,
        mode: UInt16? = 0o600
    ) -> ConfigurationFileFacts {
        ConfigurationFileFacts(
            exists: true,
            readable: state != .inaccessible,
            valid: valid,
            state: state,
            schemaVersion: schemaVersion,
            generation: generation,
            mode: mode,
            isSymlink: isSymlink,
            byteCount: 1
        )
    }
}

private struct MutationSnapshot: Equatable {
    let createCalls: [String]
    let updateCalls: [String]
    let tokenGenerationCalls: [String]
    let valueRetrievalCalls: [String]
}

private struct FixtureConfigurationContextProvider: DoctorConfigurationContextProviding {
    let snapshot: DoctorConfigurationSnapshot
    let error: DiagnosticProviderError?

    func inspect() throws -> DoctorConfigurationSnapshot {
        if let error { throw error }
        return snapshot
    }
}

private struct FixtureInstalledProvider: InstalledReleaseFactsProviding {
    func inspect() throws -> InstalledReleaseFacts {
        InstalledReleaseFacts(
            releaseVersion: "1.0.0",
            helper: CodeSignFacts(version: "1.0.0", isSigned: true, developerIDTrusted: true, receiptAvailable: true, integrityAvailable: true),
            runtime: RuntimeFacts(runtimePresent: true, version: "1.0.0", markerPresent: true, payloadPresent: true, structurallyValid: true),
            helperPresent: true,
            ownershipMarkerPresent: true
        )
    }
}

private struct FixturePermissionProvider: PermissionFactsProviding {
    let facts: PermissionFacts
    func inspect() throws -> PermissionFacts { facts }
}

private struct FixtureManagedPermissionChecker: ManagedPermissionChecking {
    let facts: ManagedPermissionProbeFacts?

    func probe(runtimeDirectory: URL) -> ManagedPermissionProbeFacts? { facts }
}

private final class RecordingPermissionProvider: PermissionFactsProviding, @unchecked Sendable {
    let facts: PermissionFacts
    var calls: [Void] = []

    init(facts: PermissionFacts) { self.facts = facts }

    func inspect() throws -> PermissionFacts {
        calls.append(())
        return facts
    }
}

private struct FixturePortProvider: PortFactsProviding {
    let facts: PortFacts
    func inspect() throws -> PortFacts { facts }
}

private struct FixtureDiskProvider: DiskSpaceProviding {
    let facts: DiskSpaceFacts
    func inspect() throws -> DiskSpaceFacts { facts }
}

private struct FixtureUpdateProvider: UpdateAvailabilityProviding {
    let facts: UpdateAvailabilityFacts
    func inspect() throws -> UpdateAvailabilityFacts { facts }
}

private final class RecordingLocalProvider: LocalMCPDiagnosticProviding, @unchecked Sendable {
    let facts: LocalMCPFacts
    var calls: [Void] = []

    init(facts: LocalMCPFacts) { self.facts = facts }
    func inspect() throws -> LocalMCPFacts { calls.append(()); return facts }
}

private final class RecordingAsyncLocalProvider: DoctorAsyncLocalMCPDiagnosticProviding, @unchecked Sendable {
    let facts: LocalMCPFacts
    var calls = 0

    init(facts: LocalMCPFacts = LocalMCPFacts(livenessVerified: true)) {
        self.facts = facts
    }

    func inspect() async throws -> LocalMCPFacts {
        calls += 1
        return facts
    }
}

private final class RecordingRemoteProvider: RemoteConnectorFactsProviding, @unchecked Sendable {
    var facts: RemoteConnectorFacts
    var calls: [Void] = []

    init(facts: RemoteConnectorFacts) { self.facts = facts }
    func inspect() throws -> RemoteConnectorFacts { calls.append(()); return facts }
}

private final class RecordingRemoteAuthenticatedProvider: RemoteAuthenticatedMCPDiagnosticProviding, @unchecked Sendable {
    let facts: RemoteAuthenticatedMCPFacts
    var calls = 0

    init(facts: RemoteAuthenticatedMCPFacts) {
        self.facts = facts
    }

    func inspect() async throws -> RemoteAuthenticatedMCPFacts {
        calls += 1
        return facts
    }
}

private extension RemoteAuthenticatedMCPFacts {
    static let readyFixture = RemoteAuthenticatedMCPFacts(
        probeAvailable: true,
        probeRun: true,
        authenticationSucceeded: true,
        initializeSucceeded: true,
        sessionEstablished: true,
        inventoryChecked: true,
        expectedTools: ["describe"],
        exposedTools: ["describe"],
        safeCallChecked: true,
        safeCallSucceeded: true
    )
}

private final class RecordingLifecycleProvider: LifecycleFactsProviding, @unchecked Sendable {
    let facts: LifecycleFacts
    var calls: [Void] = []

    init(facts: LifecycleFacts) { self.facts = facts }
    func inspect() throws -> LifecycleFacts { calls.append(()); return facts }
}

private final class RecordingDoctorKeychainProvider: DoctorKeychainPresenceProviding, @unchecked Sendable {
    var requests: [Set<KeychainPresenceItem>] = []
    var createCalls: [String] = []
    var updateCalls: [String] = []
    var tokenGenerationCalls: [String] = []
    var valueRetrievalCalls: [String] = []

    func inspect(items: Set<KeychainPresenceItem>) throws -> KeychainPresenceFacts {
        requests.append(items)
        return KeychainPresenceFacts(states: Dictionary(uniqueKeysWithValues: items.map { ($0, .present) }))
    }
}

private final class RecordingKeychainPresenceQuery: KeychainPresenceQuerying, @unchecked Sendable {
    var requests: [KeychainPresenceQuery] = []

    func query(_ request: KeychainPresenceQuery) -> KeychainPresence {
        requests.append(request)
        return .present
    }
}
