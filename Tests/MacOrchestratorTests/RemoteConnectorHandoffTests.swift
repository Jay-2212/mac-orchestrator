import Foundation
import XCTest
@testable import MacOrchestrator

final class RemoteConnectorHandoffTests: XCTestCase {
    func testExplicitHandoffBuildsURLOnlyForTheActionAndRecordsCurrentIdentity() async throws {
        let directory = try makeTemporaryDirectory()
        let stateStore = RemoteConnectorStateStore(directoryURL: directory)
        let origin = try RemotePublicOrigin("https://remote.example")
        var state = try stateStore.loadOrCreate(provider: .ngrok)
        state.connectorCredentialGeneration = 4
        state.lastVerifiedPublicOrigin = origin
        state.lastSuccessfulRemoteProbeAt = Date(timeIntervalSince1970: 1_700_000_000)
        state.lastRemoteResult = .ready
        try stateStore.save(state)

        let configuration = configuredRemoteConfiguration()
        let coordinator = RemoteProbeCoordinator(
            adapter: HandoffFakeAdapter(),
            probeRunner: { _, _ in
                RemoteActivationProbeOutcome(
                    phase: .safeCall,
                    details: RemoteActivationProbeDetails(
                        exposedTools: ["get_session_state"],
                        sessionEstablished: true,
                        safeCallSucceeded: true
                    )
                )
            }
        )
        let service = RemoteConnectorHandoffService(
            configuration: configuration,
            keychain: KeychainStore(client: HandoffKeychainClient(value: "connector-secret")),
            adapter: HandoffFakeAdapter(),
            stateStore: stateStore,
            probeCoordinator: coordinator
        )

        let handoff = try await service.prepare()
        XCTAssertEqual(handoff.url.absoluteString, "https://remote.example/connector-secret/mcp")
        XCTAssertEqual(handoff.classificationBeforeHandoff, .notAvailable)
        XCTAssertNil(try stateStore.load()?.handoffReceipt)

        let recorded = try service.record(handoff, at: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(recorded, .unchanged)
        XCTAssertEqual(try stateStore.load()?.clientHandoffClassification, .unchanged)
    }

    func testHandoffRequiresCurrentAuthenticatedStateAndDoesNotGuessFromEndpoint() async throws {
        let directory = try makeTemporaryDirectory()
        let stateStore = RemoteConnectorStateStore(directoryURL: directory)
        var state = try stateStore.loadOrCreate(provider: .ngrok)
        state.lastRemoteResult = .degraded
        try stateStore.save(state)

        let service = RemoteConnectorHandoffService(
            configuration: configuredRemoteConfiguration(),
            keychain: KeychainStore(client: HandoffKeychainClient(value: "connector-secret")),
            adapter: HandoffFakeAdapter(),
            stateStore: stateStore
        )

        do {
            _ = try await service.prepare()
            XCTFail("a degraded state must not produce a handoff URL")
        } catch let error as RemoteConnectorHandoffError {
            XCTAssertEqual(error, .remoteNotReady)
        }
    }

    private func configuredRemoteConfiguration() -> AppConfiguration {
        var configuration = AppConfiguration.fresh(ownerID: "handoff-test")
        configuration.process.serverDesired = true
        configuration.process.tunnelDesired = true
        configuration.desiredCapabilities["remote.connector"] = true
        return configuration
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-handoff-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private struct HandoffFakeAdapter: RemoteConnectorAdapter {
    var provider: RemoteConnectorProvider { .ngrok }

    func validatePrerequisites(
        _ input: RemoteConnectorPrerequisiteInput
    ) -> RemoteConnectorPrerequisiteReport {
        RemoteConnectorPrerequisiteReport(
            executableAvailable: true,
            configurationAvailable: true,
            authenticationConfigured: input.authenticationToken != nil,
            agentAPIBaseURLValid: true
        )
    }

    func makeLaunchSpecification(
        for input: RemoteConnectorLaunchInput
    ) throws -> RemoteConnectorLaunchSpecification {
        RemoteConnectorLaunchSpecification(
            executableURL: input.executableURL,
            arguments: ["http", input.tunnelTarget],
            environment: input.environment
        )
    }

    func inspectAgentAPI() async -> RemoteConnectorAgentAPIInspection {
        .available(endpoints: [
            NgrokEndpoint(
                url: "https://remote.example",
                upstream: NgrokEndpointUpstream(url: "http://127.0.0.1:8000")
            ),
        ])
    }

    func reconcileEndpoint(
        from inspection: RemoteConnectorAgentAPIInspection,
        matching expectedUpstream: String
    ) -> RemoteEndpointReconciliation {
        guard case let .available(endpoints) = inspection else { return .agentAPIUnavailable }
        return NgrokEndpointParser.reconcile(endpoints: endpoints, matching: expectedUpstream)
    }

    func diagnostics(
        for prerequisites: RemoteConnectorPrerequisiteReport,
        inspection: RemoteConnectorAgentAPIInspection?,
        reconciliation: RemoteEndpointReconciliation?
    ) -> [RemoteConnectorDiagnostic] {
        []
    }
}

private final class HandoffKeychainClient: KeychainClient, @unchecked Sendable {
    let valueToReturn: String?

    init(value: String?) {
        valueToReturn = value
    }

    func read(service: String, account: String) throws -> String? { valueToReturn }
    func create(value: String, service: String, account: String) throws {}
    func update(value: String, service: String, account: String) throws {}
}
