import CryptoKit
import Foundation
import XCTest
@testable import MacOrchestrator

final class Phase3ManifestAuthenticationTests: XCTestCase {
    func testDetachedSignatureCoversExactRawManifestBytes() throws {
        let privateKey = try fixturePrivateKey()
        let rawManifest = Data("{\n  \"product\": \"exact\"\n}\n".utf8)
        let signature = try privateKey.signature(for: rawManifest)
        let envelope = try ManifestSignatureEnvelope(
            schemaVersion: 1,
            algorithm: "ed25519",
            keyID: "fixture-v1",
            signature: signature.base64EncodedString()
        )
        let verifier = try ManifestSignatureVerifier(rawPublicKeys: [
            "fixture-v1": privateKey.publicKey.rawRepresentation
        ])

        XCTAssertNoThrow(try verifier.verify(manifestBytes: rawManifest, signatureBytes: envelope.encoded()))
        XCTAssertThrowsError(
            try verifier.verify(
                manifestBytes: Data("{\"product\":\"exact\"}".utf8),
                signatureBytes: envelope.encoded()
            )
        ) { error in
            XCTAssertEqual(error as? ManifestAuthenticationError, .invalidSignature)
        }
    }

    func testUnknownKeyAndUnsignedEnvelopeFailClosed() throws {
        let privateKey = try fixturePrivateKey()
        let manifest = Data("{}".utf8)
        let signature = try privateKey.signature(for: manifest)
        let unknown = ManifestSignatureEnvelope(
            schemaVersion: 1,
            algorithm: "ed25519",
            keyID: "unknown",
            signature: signature.base64EncodedString()
        )
        let verifier = try ManifestSignatureVerifier(rawPublicKeys: [
            "fixture-v1": privateKey.publicKey.rawRepresentation
        ])

        XCTAssertThrowsError(try verifier.verify(manifestBytes: manifest, signatureBytes: unknown.encoded())) { error in
            XCTAssertEqual(error as? ManifestAuthenticationError, .unknownKeyID("unknown"))
        }
        XCTAssertThrowsError(try verifier.verify(manifestBytes: manifest, signatureBytes: Data())) { error in
            XCTAssertEqual(error as? ManifestAuthenticationError, .malformedEnvelope)
        }
    }

    func testReleaseManifestRejectsMutableAndIncompatibleMetadata() throws {
        var manifest = try makeManifest(version: "1.2.0")
        manifest.helper.url = URL(string: "https://github.com/Jay-2212/mac-orchestrator/main/helper.zip")!

        XCTAssertThrowsError(
            try manifest.validated(
                expectedVersion: try SemanticVersion("1.2.0"),
                currentVersion: try SemanticVersion("1.1.0"),
                currentConfigurationSchema: 1,
                currentRuntimeSchema: 1,
                architecture: "arm64",
                operatingSystem: try SemanticVersion("14.0.0")
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseManifestValidationError, .mutableAssetURL("helper"))
        }

        manifest = try makeManifest(version: "1.2.0")
        manifest.compatibility.configurationSchema = SchemaRange(minimum: 2, maximum: 2)
        XCTAssertThrowsError(
            try manifest.validated(
                expectedVersion: try SemanticVersion("1.2.0"),
                currentVersion: try SemanticVersion("1.1.0"),
                currentConfigurationSchema: 1,
                currentRuntimeSchema: 1,
                architecture: "arm64",
                operatingSystem: try SemanticVersion("14.0.0")
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseManifestValidationError, .incompatibleConfigurationSchema)
        }
    }

    func testUpdateDiscoveryVerifiesSignatureBeforeManifestInterpretation() throws {
        let manifest = try makeManifest(version: "1.2.0")
        let rawManifest = try JSONEncoder().encode(manifest)
        let privateKey = try fixturePrivateKey()
        let signature = try privateKey.signature(for: rawManifest)
        let signatureEnvelope = ManifestSignatureEnvelope(
            schemaVersion: 1,
            algorithm: "ed25519",
            keyID: "fixture-v1",
            signature: signature.base64EncodedString()
        )
        let manifestURL = URL(string: "https://github.com/Jay-2212/mac-orchestrator/releases/download/v1.2.0/manifest.json")!
        let signatureURL = URL(string: "https://github.com/Jay-2212/mac-orchestrator/releases/download/v1.2.0/manifest.sig")!
        let fetcher = StaticUpdateAssetFetcher(values: [
            manifestURL: rawManifest,
            signatureURL: try signatureEnvelope.encoded(),
        ])
        let discoverer = StaticReleaseDiscoverer(record: ReleaseDiscoveryRecord(
            version: "1.2.0",
            tag: "v1.2.0",
            manifestURL: manifestURL,
            signatureURL: signatureURL,
            draft: false,
            prerelease: false
        ))
        let ledgerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("phase3-update-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ledgerDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ledgerDirectory) }
        let engine = UpdateEngine(
            currentVersion: try SemanticVersion("1.1.0"),
            operatingSystem: try SemanticVersion("14.0.0"),
            discoverer: discoverer,
            fetcher: fetcher,
            verifier: try ManifestSignatureVerifier(rawPublicKeys: ["fixture-v1": privateKey.publicKey.rawRepresentation]),
            ledger: MaintenanceTransactionLedger(directoryURL: ledgerDirectory),
            driver: TestUpdateDriver(),
            lifecycle: TestUpdateLifecycle()
        )

        let candidate = try engine.checkForUpdate()
        XCTAssertEqual(candidate.trust, .detachedSignature)
        let tamperedCandidate = UpdateCandidate(
            discovery: candidate.discovery,
            rawManifest: Data("{}".utf8),
            rawSignature: candidate.rawSignature,
            manifest: candidate.manifest,
            manifestSHA256: candidate.manifestSHA256,
            trust: candidate.trust
        )
        XCTAssertThrowsError(try engine.apply(tamperedCandidate)) { error in
            XCTAssertEqual(error as? UpdateEngineError, .manifestDigestMismatch)
        }
        fetcher.values[manifestURL] = Data("{}".utf8)
        XCTAssertThrowsError(try engine.checkForUpdate()) { error in
            XCTAssertEqual(error as? ManifestAuthenticationError, .invalidSignature)
        }
    }

    private func fixturePrivateKey() throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: Data(1...32))
    }

    private func makeManifest(version: String) throws -> ReleaseManifestV1 {
        let digest = String(repeating: "a", count: 64)
        return ReleaseManifestV1(
            schemaVersion: 1,
            product: .init(name: "Mac Orchestrator", version: version),
            bootstrap: .init(
                version: "1.0.0",
                url: URL(string: "https://github.com/Jay-2212/mac-orchestrator/releases/download/v\(version)/bootstrap.sh")!,
                sha256: digest
            ),
            platform: .init(architecture: "arm64", minimumMacOS: "13.0"),
            helper: .init(
                url: URL(string: "https://github.com/Jay-2212/mac-orchestrator/releases/download/v\(version)/Mac-Orchestrator-arm64.zip")!,
                sha256: digest,
                architecture: "arm64",
                bundleIdentifier: "com.jay.mac-orchestrator",
                version: version,
                signing: .init(mode: "adhoc")
            ),
            runtime: .init(
                schemaVersion: 1,
                uv: .init(
                    version: "0.12.3",
                    url: URL(string: "https://github.com/Jay-2212/mac-orchestrator/releases/download/v\(version)/uv-arm64")!,
                    sha256: digest
                ),
                python: .init(managedVersion: "3.13.14"),
                lockSha256: digest,
                corePayload: .init(
                    url: URL(string: "https://github.com/Jay-2212/mac-orchestrator/releases/download/v\(version)/core-payload.tar.gz")!,
                    sha256: digest,
                    format: "tar.gz",
                    files: ["automac_mcp.py", "pyproject.toml", "uv.lock"]
                )
            ),
            ngrok: .init(
                version: "3.20.0",
                archiveUrl: URL(string: "https://bin.equinox.io/a/ngrok-v3.zip")!,
                archiveSha256: digest,
                archiveFormat: "zip",
                executableName: "ngrok",
                developerIdAuthority: "Developer ID Application: ngrok, Inc.",
                developerIdTeam: "ABCDEFGHIJ",
                agentApiVersion: "v3"
            ),
            compatibility: .init(
                runtimeSchema: SchemaRange(minimum: 1, maximum: 1),
                configurationSchema: SchemaRange(minimum: 1, maximum: 1)
            )
        )
    }
}

private final class StaticUpdateAssetFetcher: UpdateAssetFetcher {
    var values: [URL: Data]

    init(values: [URL: Data]) { self.values = values }

    func fetch(url: URL) throws -> Data {
        guard let value = values[url] else { throw UpdateNetworkError.requestFailed("missing fixture") }
        return value
    }
}

private struct StaticReleaseDiscoverer: UpdateReleaseDiscoverer {
    let record: ReleaseDiscoveryRecord

    func discover() throws -> [ReleaseDiscoveryRecord] { [record] }
}

private struct TestUpdateDriver: UpdateTransactionDriver {
    func stage(candidate: UpdateCandidate, transactionID: UUID) throws -> StagedUpdate {
        StagedUpdate(transactionID: transactionID, rootURL: URL(fileURLWithPath: "/tmp/phase3-test"), candidateHelperURL: URL(fileURLWithPath: "/tmp/helper.zip"))
    }

    func validateCandidate(_ candidate: UpdateCandidate, staged: StagedUpdate) throws {}

    func prepareMigration(candidate: UpdateCandidate, staged: StagedUpdate, registry: ConfigurationMigrationRegistry) throws -> PreparedConfigurationMigration? { nil }

    func backupCurrentState(transactionID: UUID) throws {}

    func promote(candidate: UpdateCandidate, staged: StagedUpdate, preparedMigration: PreparedConfigurationMigration?, transactionID: UUID) throws {}

    func validateStructuralState(candidate: UpdateCandidate, transactionID: UUID) throws {}

    func installLaunchAgent(candidate: UpdateCandidate, transactionID: UUID) throws {}

    func commit(candidate: UpdateCandidate, staged: StagedUpdate, transactionID: UUID) throws -> InstallationReceiptV1 {
        try InstallationReceiptV1(
            productVersion: candidate.manifest.product.version,
            manifestSHA256: candidate.manifestSHA256,
            helperPayloadSHA256: candidate.manifest.helper.sha256,
            coreRuntimePayloadSHA256: candidate.manifest.runtime.corePayload.sha256,
            runtimeLockSHA256: candidate.manifest.runtime.lockSha256,
            runtimeSchemaVersion: 1,
            configurationSchemaVersion: 1,
            installedAt: Date()
        )
    }

    func postflight(candidate: UpdateCandidate, transactionID: UUID) throws {}

    func rollback(transactionID: UUID) throws {}
}

private struct TestUpdateLifecycle: MaintenanceLifecycleAdapter {
    func quiesce() throws -> MaintenanceQuiesceReceipt {
        MaintenanceQuiesceReceipt(ownerID: "test", remoteStopped: true, localServerStopped: true)
    }

    func restore() throws {}
}

final class Phase3MaintenanceLifecycleIntegrationTests: XCTestCase {
    func testQuiesceStopsRemoteIngressBeforeLocalServerAndRestoresBoth() throws {
        let controller = RecordingMaintenanceController()
        let adapter = ExternalMaintenanceLifecycleAdapter(ownerID: "test-owner", controller: controller)

        _ = try adapter.quiesce()
        try adapter.restore()

        XCTAssertEqual(controller.events, ["verify", "remote", "local", "restore"])
    }

    func testPartialQuiesceAttemptsRecoveryWithoutClaimingSuccess() {
        let controller = RecordingMaintenanceController(failLocal: true)
        let adapter = ExternalMaintenanceLifecycleAdapter(ownerID: "test-owner", controller: controller)

        XCTAssertThrowsError(try adapter.quiesce()) { error in
            XCTAssertEqual(error as? MaintenanceLifecycleError, .localQuiesceFailed)
        }
        XCTAssertEqual(controller.events, ["verify", "remote", "local", "restore"])
    }

    func testLaunchAgentRemovalIsExplicitAndDoesNotRestoreByItself() throws {
        let controller = RecordingMaintenanceController()
        let adapter = ExternalMaintenanceLifecycleAdapter(ownerID: "test-owner", controller: controller)

        try adapter.removeManagedLaunchAgent()

        XCTAssertEqual(controller.events, ["unload"])
    }
}

private final class RecordingMaintenanceController: MaintenanceServiceController {
    private(set) var events: [String] = []
    let failLocal: Bool

    init(failLocal: Bool = false) {
        self.failLocal = failLocal
    }

    func verifyOwnership(ownerID: String) throws -> Bool {
        events.append("verify")
        return ownerID == "test-owner"
    }

    func stopRemote() throws {
        events.append("remote")
    }

    func stopLocalServer() throws {
        events.append("local")
        if failLocal { throw MaintenanceLifecycleError.localQuiesceFailed }
    }

    func unloadManagedService() throws {
        events.append("unload")
    }

    func restore() throws {
        events.append("restore")
    }
}

final class Phase3MaintenanceStorageTests: XCTestCase {
    func testInstallationReceiptRoundTripsWithoutSecretsOrPersonalPaths() throws {
        let receipt = try InstallationReceiptV1(
            productVersion: "1.2.0",
            manifestSHA256: String(repeating: "a", count: 64),
            helperPayloadSHA256: String(repeating: "b", count: 64),
            coreRuntimePayloadSHA256: String(repeating: "c", count: 64),
            runtimeLockSHA256: String(repeating: "d", count: 64),
            runtimeSchemaVersion: 1,
            configurationSchemaVersion: 1,
            installedAt: Date(timeIntervalSince1970: 1234),
            manifestURL: URL(string: "https://github.com/Jay-2212/mac-orchestrator/releases/download/v1.2.0/manifest.json")!
        )
        let data = try receipt.encoded()
        let decoded = try InstallationReceiptV1.decode(data)

        XCTAssertEqual(decoded, receipt)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(json.contains("/Users/"))
    }

    func testTransactionLedgerPersistsDurableStatesAndRejectsBackwardTransition() throws {
        let directory = try temporaryDirectory()
        let ledger = MaintenanceTransactionLedger(directoryURL: directory)
        let transaction = try ledger.begin(
            targetVersion: "1.2.0",
            manifestSHA256: String(repeating: "a", count: 64),
            manifestURL: URL(string: "https://github.com/Jay-2212/mac-orchestrator/releases/download/v1.2.0/manifest.json")!
        )

        try ledger.advance(transaction.id, to: .manifestAuthenticated)
        try ledger.advance(transaction.id, to: .candidateStaged)
        XCTAssertEqual(try ledger.load(transaction.id)?.state, .candidateStaged)
        XCTAssertThrowsError(try ledger.advance(transaction.id, to: .discovered)) { error in
            XCTAssertEqual(error as? MaintenanceTransactionError, .invalidTransition(.candidateStaged, .discovered))
        }
    }

    func testMigrationPreparationLeavesActiveSnapshotUntouchedWhenStepThrows() throws {
        let original = Data("{\"schemaVersion\":1,\"value\":\"before\"}".utf8)
        let registry = ConfigurationMigrationRegistry(steps: [
            ConfigurationMigrationStep(
                identifier: "throwing-step",
                sourceSchema: 1,
                targetSchema: 2,
                apply: { _ in throw ConfigurationMigrationError.stepFailed("throwing-step") }
            )
        ])
        let plan = try registry.plan(sourceSchema: 1, targetSchema: 2)

        XCTAssertThrowsError(
            try ConfigurationMigrationEngine.prepare(
                rawConfiguration: original,
                plan: plan,
                candidateValidator: { _ in }
            )
        )
        XCTAssertEqual(original, Data("{\"schemaVersion\":1,\"value\":\"before\"}".utf8))
    }

    func testDeterministicFaultInjectorCoversEveryUpdateAndUninstallBoundary() {
        for point in MaintenanceFaultPoint.allCases {
            let injector = DeterministicMaintenanceFaultInjector(failAt: [point])
            XCTAssertThrowsError(try injector.check(point)) { error in
                XCTAssertEqual(error as? MaintenanceInjectedFailure, MaintenanceInjectedFailure(point: point))
            }
            XCTAssertNoThrow(try injector.check(point))
        }
    }

    func testPersistentDowngradeRequiresExplicitCompatibleAuthenticatedTarget() throws {
        let current = try receipt(version: "2.0.0", schema: 1)
        let target = try receipt(version: "1.9.0", schema: 1)
        let proof = try UpdateRollbackPolicy.provePersistentDowngrade(
            from: current,
            to: target,
            targetManifestAuthenticated: true,
            explicitlyRequested: true
        )
        XCTAssertEqual(proof.mode, .explicitlyAuthorizedPersistentDowngrade)
        XCTAssertThrowsError(
            try UpdateRollbackPolicy.provePersistentDowngrade(
                from: current,
                to: target,
                targetManifestAuthenticated: true,
                explicitlyRequested: false
            )
        ) { error in
            XCTAssertEqual(error as? PersistentDowngradeError, .notExplicitlyRequested)
        }
    }

    private func receipt(version: String, schema: Int) throws -> InstallationReceiptV1 {
        try InstallationReceiptV1(
            productVersion: version,
            manifestSHA256: String(repeating: "a", count: 64),
            helperPayloadSHA256: String(repeating: "b", count: 64),
            coreRuntimePayloadSHA256: String(repeating: "c", count: 64),
            runtimeLockSHA256: String(repeating: "d", count: 64),
            runtimeSchemaVersion: schema,
            configurationSchemaVersion: schema,
            installedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase3-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

final class Phase3KeychainAndUninstallTests: XCTestCase {
    func testExplicitKeychainDeletionLeavesUnrelatedItemUntouched() throws {
        let client = DeletingKeychainClient(values: [
            KeychainItem.connectorToken.key: "connector",
            KeychainItem.ngrokAuthtoken.key: "ngrok",
            "unrelated-service\u{001f}unrelated-account": "keep"
        ])
        let store = KeychainStore(client: client)

        try store.delete(.ngrokAuthtoken)

        XCTAssertNil(try store.value(for: .ngrokAuthtoken))
        XCTAssertEqual(client.values[KeychainItem.connectorToken.key], "connector")
        XCTAssertEqual(client.values["unrelated-service\u{001f}unrelated-account"], "keep")
    }

    func testUninstallPlanPreservesConfigurationAndKeychainByDefault() throws {
        let layout = try uninstallLayout()
        let plan = try UninstallEngine(
            supportDirectory: layout.support,
            logsDirectory: layout.logs,
            keychain: KeychainStore(client: DeletingKeychainClient()),
            lifecycle: FakeMaintenanceLifecycle(),
            homeDirectory: layout.home
        ).plan(options: RemovalOptions())

        XCTAssertTrue(plan.entries.contains { $0.kind == .configuration && $0.intent == .retain })
        XCTAssertTrue(plan.keychainItemsToDelete.isEmpty)
        XCTAssertTrue(plan.providerResourcesUntouched)
    }

    func testUninstallRejectsBroadApplicationSupportRoot() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let validator = UninstallPathValidator()

        XCTAssertThrowsError(
            try validator.validateRoot(
                home.appendingPathComponent("Library/Application Support", isDirectory: true)
            )
        )
    }

    func testUninstallRejectsSymlinkedRemovalRootAndStillReturnsReceipt() throws {
        let layout = try uninstallLayout()
        let support = layout.support
        let target = support.appendingPathComponent("runtime", isDirectory: true)
        let outside = support.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let engine = try UninstallEngine(
            supportDirectory: support,
            logsDirectory: layout.logs,
            keychain: KeychainStore(client: DeletingKeychainClient()),
            lifecycle: FakeMaintenanceLifecycle(),
            homeDirectory: layout.home
        )
        let plan = try engine.plan(options: RemovalOptions(removeManagedRuntime: true))
        let receipt = engine.apply(plan)

        XCTAssertTrue(receipt.outcomes.contains { $0.status == .failedManualActionRequired })
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testPartialNonTerminalUninstallRestoresServices() throws {
        let layout = try uninstallLayout()
        let caches = layout.support.appendingPathComponent("caches", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let lifecycle = FakeMaintenanceLifecycle()
        let engine = try UninstallEngine(
            supportDirectory: layout.support,
            logsDirectory: layout.logs,
            keychain: KeychainStore(client: DeletingKeychainClient()),
            lifecycle: lifecycle,
            homeDirectory: layout.home
        )

        let receipt = engine.apply(try engine.plan(options: RemovalOptions(removeCaches: true)))

        XCTAssertEqual(lifecycle.quiesceCalls, 1)
        XCTAssertEqual(lifecycle.restoreCalls, 1)
        XCTAssertTrue(receipt.outcomes.contains { $0.kind == .caches && $0.status == .removed })
    }

    func testDestructiveUninstallRemainsQuiescedAndDoesNotRestoreServices() throws {
        let layout = try uninstallLayout()
        let app = layout.support.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("managed".utf8).write(to: app.appendingPathComponent("marker"))
        let lifecycle = FakeMaintenanceLifecycle()
        let engine = try UninstallEngine(
            supportDirectory: layout.support,
            logsDirectory: layout.logs,
            keychain: KeychainStore(client: DeletingKeychainClient()),
            lifecycle: lifecycle,
            homeDirectory: layout.home
        )

        let plan = try engine.plan(options: RemovalOptions(removeApplication: true))
        XCTAssertTrue(plan.servicesRemainQuiesced)
        _ = engine.apply(plan)

        XCTAssertEqual(lifecycle.quiesceCalls, 1)
        XCTAssertEqual(lifecycle.restoreCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
    }

    private struct UninstallLayout {
        let root: URL
        let support: URL
        let home: URL
        let logs: URL
    }

    private func uninstallLayout() throws -> UninstallLayout {
        let root = try temporaryDirectory()
        let support = root.appendingPathComponent("support", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs/Mac Orchestrator", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return UninstallLayout(root: root, support: support, home: home, logs: logs)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase3-uninstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private final class DeletingKeychainClient: KeychainClient {
        var values: [String: String]

        init(values: [String: String] = [:]) {
            self.values = values
        }

        func read(service: String, account: String) throws -> String? {
            values[KeychainItem.key(service: service, account: account)]
        }

        func create(value: String, service: String, account: String) throws {
            values[KeychainItem.key(service: service, account: account)] = value
        }

        func update(value: String, service: String, account: String) throws {
            values[KeychainItem.key(service: service, account: account)] = value
        }

        func delete(service: String, account: String) throws {
            values.removeValue(forKey: KeychainItem.key(service: service, account: account))
        }
    }

    private final class FakeMaintenanceLifecycle: MaintenanceLifecycleAdapter {
        private(set) var quiesceCalls = 0
        private(set) var restoreCalls = 0

        func quiesce() throws -> MaintenanceQuiesceReceipt {
            quiesceCalls += 1
            return MaintenanceQuiesceReceipt(ownerID: "test-owner", remoteStopped: true, localServerStopped: true)
        }

        func restore() throws { restoreCalls += 1 }
    }
}
