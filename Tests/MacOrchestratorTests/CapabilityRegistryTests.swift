import Foundation
import XCTest
@testable import MacOrchestrator

final class CapabilityRegistryTests: XCTestCase {
    func testRegistryPublishesTheRequiredCapabilityIDs() {
        let snapshot = CapabilityRegistry(
            configuration: AppConfiguration.fresh(ownerID: "owner-1"),
            facts: readyFacts()
        ).snapshot()

        XCTAssertEqual(Set(snapshot.capabilities.keys), Set([
            "core.session",
            "mac.ui",
            "mac.screenOcr",
            "mac.files.read",
            "mac.files.write",
            "mac.shell",
            "mac.clipboard.write",
            "telegram.send",
            "meridian.search",
            "meridian.telegram",
            "remote.connector",
        ]))
    }

    func testGuidedControlBlocksShellAndFileWritesEvenWhenDesired() {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.approvedFileRoots = ["/tmp/approved"]
        configuration.desiredCapabilities["mac.shell"] = true
        configuration.desiredCapabilities["mac.files.read"] = true
        configuration.desiredCapabilities["mac.files.write"] = true

        let snapshot = CapabilityRegistry(configuration: configuration, facts: readyFacts()).snapshot()

        XCTAssertFalse(snapshot.capabilities["mac.shell"]!.ready)
        XCTAssertFalse(snapshot.capabilities["mac.files.write"]!.ready)
        XCTAssertEqual(
            snapshot.capabilities["mac.shell"]!.reason,
            "Full Control must be explicitly selected."
        )
    }

    func testGuidedClipboardMutationRequiresExplicitPolicy() {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.desiredCapabilities["mac.clipboard.write"] = true
        let denied = CapabilityRegistry(configuration: configuration, facts: readyFacts()).snapshot()
        XCTAssertFalse(denied.capabilities["mac.clipboard.write"]!.ready)

        configuration.policy.clipboardMutation = true
        let allowed = CapabilityRegistry(configuration: configuration, facts: readyFacts()).snapshot()
        XCTAssertTrue(allowed.capabilities["mac.clipboard.write"]!.ready)
    }

    func testFullControlRequiresExplicitDesiredStateButNotApprovedRoots() {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.controlProfile = .full
        configuration.desiredCapabilities["mac.shell"] = true
        configuration.desiredCapabilities["mac.files.read"] = true
        configuration.desiredCapabilities["mac.files.write"] = true

        let withoutRoots = CapabilityRegistry(configuration: configuration, facts: readyFacts()).snapshot()
        XCTAssertTrue(withoutRoots.capabilities["mac.shell"]!.ready)
        XCTAssertTrue(withoutRoots.capabilities["mac.files.read"]!.ready)
        XCTAssertTrue(withoutRoots.capabilities["mac.files.write"]!.ready)
    }

    func testGuidedFileReadRequiresAnApprovedRoot() {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.desiredCapabilities["mac.files.read"] = true

        let withoutRoots = CapabilityRegistry(configuration: configuration, facts: readyFacts()).snapshot()
        XCTAssertFalse(withoutRoots.capabilities["mac.files.read"]!.configured)
        XCTAssertFalse(withoutRoots.capabilities["mac.files.read"]!.ready)

        configuration.approvedFileRoots = ["/tmp/approved"]
        let withRoots = CapabilityRegistry(configuration: configuration, facts: readyFacts()).snapshot()
        XCTAssertTrue(withRoots.capabilities["mac.files.read"]!.ready)
    }

    func testSnapshotPolicyEmitsOnlyCanonicalDeduplicatedRoots() {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.approvedFileRoots = [
            "/tmp/mac-orchestrator/approved",
            "/tmp/mac-orchestrator/nested/../approved/",
        ]

        let snapshot = CapabilityRegistry(configuration: configuration, facts: readyFacts()).snapshot()

        XCTAssertEqual(snapshot.policy.approvedFileRoots, ["/tmp/mac-orchestrator/approved"])
    }

    func testInvalidRawRootCannotReachSnapshotOrEnableGuidedRead() {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.desiredCapabilities["mac.files.read"] = true
        configuration.approvedFileRoots = ["relative/path"]

        let snapshot = CapabilityRegistry(configuration: configuration, facts: readyFacts()).snapshot()

        XCTAssertTrue(snapshot.policy.approvedFileRoots.isEmpty)
        XCTAssertFalse(snapshot.capabilities["mac.files.read"]!.configured)
        XCTAssertFalse(snapshot.capabilities["mac.files.read"]!.ready)
    }

    func testMeridianTelegramCannotOutrunMeridianSearch() {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.controlProfile = .full
        configuration.integration.meridianDeploymentURL = "https://meridian.example"
        configuration.desiredCapabilities["meridian.search"] = true
        configuration.desiredCapabilities["meridian.telegram"] = true
        let facts = readyFacts(meridianSearchReady: false, meridianTelegramReady: true)

        let snapshot = CapabilityRegistry(configuration: configuration, facts: facts).snapshot()

        XCTAssertFalse(snapshot.capabilities["meridian.search"]!.ready)
        XCTAssertFalse(snapshot.capabilities["meridian.telegram"]!.ready)
        XCTAssertEqual(snapshot.capabilities["meridian.telegram"]!.dependencies, ["meridian.search"])
    }

    func testMeridianURLAndCredentialFactsDoNotAloneMarkSearchReady() {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.integration.meridianDeploymentURL = "https://meridian.example"
        configuration.desiredCapabilities["meridian.search"] = true
        let facts = readyFacts(meridianCredentialsPresent: true, meridianSearchReady: false)

        let state = CapabilityRegistry(configuration: configuration, facts: facts)
            .snapshot()
            .capabilities["meridian.search"]!

        XCTAssertTrue(state.configured)
        XCTAssertFalse(state.ready)
        XCTAssertEqual(
            state.reason,
            "Meridian Search compatibility and index readiness have not been verified."
        )
    }

    func testRemoteConnectorProcessPresenceCannotAloneMarkReadiness() {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.desiredCapabilities["remote.connector"] = true
        let facts = readyFacts(remoteConnectorConfigured: true, remoteConnectorReady: false)

        let state = CapabilityRegistry(configuration: configuration, facts: facts)
            .snapshot()
            .capabilities["remote.connector"]!

        XCTAssertTrue(state.configured)
        XCTAssertFalse(state.ready)
    }

    func testSnapshotEncodingIsDeterministicAndContainsNoSecretsOrProviderIDs() throws {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.integration.meridianDeploymentURL = "https://meridian.example"
        configuration.integration.aliases["provider"] = "provider-account"
        let snapshot = CapabilityRegistry(configuration: configuration, facts: readyFacts()).snapshot()

        let first = try CapabilitySnapshotCodec.encode(snapshot)
        let second = try CapabilitySnapshotCodec.encode(snapshot)
        let json = String(decoding: first, as: UTF8.self)

        XCTAssertEqual(first, second)
        XCTAssertTrue(json.contains("\"snapshotSchemaVersion\":1"))
        XCTAssertTrue(json.contains("\"configGeneration\":1"))
        XCTAssertTrue(json.contains("\"controlProfile\":\"guided\""))
        XCTAssertTrue(json.contains("\"reason\":null"))
        XCTAssertFalse(json.contains("connector-secret"))
        XCTAssertFalse(json.contains("provider-account"))
        XCTAssertFalse(json.contains("meridian.example"))

        let decoded = try CapabilitySnapshotCodec.decode(first)
        XCTAssertEqual(decoded, snapshot)
    }

    func testFutureSnapshotSchemaIsRejected() throws {
        let data = Data("{\"snapshotSchemaVersion\":99}".utf8)
        XCTAssertThrowsError(try CapabilitySnapshotCodec.decode(data)) { error in
            XCTAssertEqual(error as? CapabilitySnapshotError, .unsupportedSchema(99))
        }
    }

    func testSharedSchemaV1FixtureDecodesAndRoundTripsWithCanonicalHealthVocabulary() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/capability_snapshot_v1.json")
        let fixture = try Data(contentsOf: fixtureURL)

        let decoded = try CapabilitySnapshotCodec.decode(fixture)

        XCTAssertEqual(decoded.snapshotSchemaVersion, 1)
        XCTAssertEqual(decoded.configGeneration, 7)
        XCTAssertEqual(decoded.controlProfile, .guided)
        XCTAssertEqual(Set(decoded.capabilities.keys), Set(CapabilityRegistry.capabilityIDs))
        XCTAssertEqual(
            Set(decoded.capabilities.values.map { $0.health.rawValue }),
            Set(["ready", "disabled", "degraded", "unavailable"])
        )
        XCTAssertEqual(decoded.policy.approvedFileRoots, ["/tmp/mac-orchestrator-fixture/approved"])
        XCTAssertEqual(
            try CapabilitySnapshotCodec.decode(CapabilitySnapshotCodec.encode(decoded)),
            decoded
        )
    }

    func testUnknownSchemaV1HealthValueIsRejected() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/capability_snapshot_v1.json")
        let fixture = String(decoding: try Data(contentsOf: fixtureURL), as: UTF8.self)
        let unknown = fixture.replacingOccurrences(
            of: "\"health\": \"ready\"",
            with: "\"health\": \"future-health\"",
            options: [],
            range: fixture.range(of: "\"health\": \"ready\"")
        )

        XCTAssertThrowsError(try CapabilitySnapshotCodec.decode(Data(unknown.utf8)))
    }

    private func readyFacts(
        meridianCredentialsPresent: Bool = false,
        meridianSearchReady: Bool = false,
        meridianTelegramReady: Bool = false,
        remoteConnectorConfigured: Bool = true,
        remoteConnectorReady: Bool = true
    ) -> CapabilityReadinessFacts {
        CapabilityReadinessFacts(
            coreSessionReady: true,
            localUIReady: true,
            screenOcrReady: true,
            fileReadReady: true,
            fileWriteReady: true,
            shellReady: true,
            clipboardReady: true,
            telegramCredentialsPresent: true,
            telegramReady: true,
            meridianCredentialsPresent: meridianCredentialsPresent,
            meridianSearchReady: meridianSearchReady,
            meridianTelegramConfigured: true,
            meridianTelegramReady: meridianTelegramReady,
            remoteConnectorConfigured: remoteConnectorConfigured,
            remoteConnectorReady: remoteConnectorReady
        )
    }
}
