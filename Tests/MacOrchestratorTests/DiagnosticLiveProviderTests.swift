import Foundation
import XCTest
@testable import MacOrchestrator

final class DiagnosticLiveProviderTests: XCTestCase {
    func testActivationAdapterUsesCanonicalProbeAndNeverPIDOrTokenAsReadiness() async {
        let keychainClient = RecordingDiagnosticKeychainClient(value: "connector-secret")
        let probe = RecordingActivationProbe(result: .success(
            LocalActivationProbeDetails(
                exposedTools: ["describe", "get_capabilities", "get_session_state"],
                safeCallSucceeded: true
            )
        ))
        let configuration = AppConfiguration(ownerID: "owner-1")
        let adapter = LocalActivationProbeAdapter(
            probe: probe,
            keychain: KeychainStore(client: keychainClient),
            configuration: configuration,
            port: 8007,
            pythonPID: 4242
        )

        let facts = await adapter.inspect()

        XCTAssertEqual(probe.calls, [
            .init(port: 8007, token: "connector-secret", requiresInteractiveUI: true)
        ])
        XCTAssertTrue(facts.livenessVerified)
        XCTAssertTrue(facts.readinessVerified)
        XCTAssertTrue(facts.sessionEstablished)
        XCTAssertTrue(facts.safeCallSucceeded)
        XCTAssertFalse(String(describing: facts).contains("connector-secret"))
        XCTAssertFalse(String(describing: facts).contains("4242"))
        XCTAssertTrue(keychainClient.createCalls.isEmpty)
        XCTAssertTrue(keychainClient.updateCalls.isEmpty)
    }

    func testActivationAdapterMapsCanonicalFailureToNonReadyFacts() async {
        let keychainClient = RecordingDiagnosticKeychainClient(value: "connector-secret")
        let probe = RecordingActivationProbe(result: .failure(
            LocalActivationProbeError.healthCheckFailed(status: 200, body: "secret response body")
        ))
        let adapter = LocalActivationProbeAdapter(
            probe: probe,
            keychain: KeychainStore(client: keychainClient),
            configuration: AppConfiguration(ownerID: "owner-1"),
            port: 8007,
            pythonPID: 4242
        )

        let facts = await adapter.inspect()

        XCTAssertTrue(facts.livenessVerified)
        XCTAssertFalse(facts.readinessVerified)
        XCTAssertFalse(facts.sessionEstablished)
        XCTAssertFalse(facts.safeCallSucceeded)
        XCTAssertFalse(String(describing: facts).contains("secret response body"))
    }

    func testMissingConnectorTokenIsUnavailableWithoutCreatingOne() async {
        let keychainClient = RecordingDiagnosticKeychainClient(value: nil)
        let probe = RecordingActivationProbe(result: .success(LocalActivationProbeDetails()))
        let adapter = LocalActivationProbeAdapter(
            probe: probe,
            keychain: KeychainStore(client: keychainClient),
            configuration: AppConfiguration(ownerID: "owner-1"),
            port: 8007,
            pythonPID: 4242
        )

        let facts = await adapter.inspect()

        XCTAssertFalse(facts.livenessVerified)
        XCTAssertFalse(facts.readinessVerified)
        XCTAssertTrue(probe.calls.isEmpty)
        XCTAssertTrue(keychainClient.createCalls.isEmpty)
        XCTAssertTrue(keychainClient.updateCalls.isEmpty)
    }

    func testCurrentCoreExpectationsOnlyIncludeDesiredShippedGroups() {
        var configuration = AppConfiguration(ownerID: "owner-1")
        configuration.desiredCapabilities["mac.ui"] = true
        configuration.desiredCapabilities["mac.screenOcr"] = true
        configuration.desiredCapabilities["mac.files.read"] = true
        configuration.desiredCapabilities["mac.files.write"] = true
        configuration.desiredCapabilities["mac.shell"] = true
        configuration.desiredCapabilities["mac.clipboard.write"] = true
        configuration.desiredCapabilities["telegram.send"] = true
        configuration.desiredCapabilities["meridian.search"] = true
        configuration.desiredCapabilities["remote.connector"] = true

        let expectations = CurrentCoreMCPExpectationProvider().expectations(for: configuration)

        XCTAssertTrue(expectations.expectedCapabilityGroups.contains("core.session"))
        XCTAssertTrue(expectations.expectedCapabilityGroups.contains("mac.ui"))
        XCTAssertTrue(expectations.expectedCapabilityGroups.contains("mac.screenOcr"))
        XCTAssertTrue(expectations.expectedCapabilityGroups.contains("mac.files.read"))
        XCTAssertTrue(expectations.expectedCapabilityGroups.contains("mac.files.write"))
        XCTAssertTrue(expectations.expectedCapabilityGroups.contains("mac.shell"))
        XCTAssertTrue(expectations.expectedCapabilityGroups.contains("mac.clipboard.write"))
        XCTAssertTrue(expectations.expectedCapabilityGroups.contains("telegram.send"))
        XCTAssertFalse(expectations.expectedCapabilityGroups.contains("meridian.search"))
        XCTAssertFalse(expectations.expectedCapabilityGroups.contains("remote.connector"))
        XCTAssertTrue(expectations.skippedCapabilityGroups.contains("meridian.search"))
        XCTAssertTrue(expectations.skippedCapabilityGroups.contains("remote.connector"))
        XCTAssertTrue(expectations.skippedCapabilityGroups.contains("telegram.assistant"))
        XCTAssertTrue(expectations.skippedCapabilityGroups.contains("cloudflare"))
        XCTAssertTrue(expectations.expectedTools.contains("describe"))
        XCTAssertTrue(expectations.expectedTools.contains("get_session_state"))
        XCTAssertTrue(expectations.expectedTools.contains("write_file"))
        XCTAssertTrue(expectations.expectedTools.contains("run_terminal_command"))
        XCTAssertTrue(expectations.expectedTools.contains("send_file_to_telegram"))
        XCTAssertFalse(expectations.expectedTools.contains("vector_search"))
    }

    func testPortProviderUsesInjectedReadOnlyCommandAndDoesNotTreatPIDAsReadiness() throws {
        let runner = RecordingDiagnosticCommandRunner(outputs: [
            DiagnosticCommandRequest(executable: "/usr/sbin/lsof", arguments: [
                "-nP", "-iTCP:8007", "-sTCP:LISTEN", "-t"
            ]): DiagnosticCommandResult(status: 0, stdout: "4242\n", stderr: "")
        ])
        let provider = ReadOnlyPortFactsProvider(
            port: 8007,
            commandRunner: runner,
            processRunner: RecordingDiagnosticProcessRunner(processes: [])
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.listenerPresent)
        XCTAssertFalse(facts.listenerOwned)
        XCTAssertEqual(facts.listenerPID, 4242)
        XCTAssertFalse(facts.pidReuseDetected)
        XCTAssertTrue(runner.requests.allSatisfy { !$0.executable.contains("kill") })
    }

    func testNgrokProviderParsesEndpointCountWithoutReturningURLOrBody() throws {
        let apiURL = URL(string: "http://127.0.0.1:4040/api/endpoints")!
        let http = RecordingDiagnosticHTTPRunner(response: DiagnosticHTTPResponse(
            status: 200,
            url: apiURL,
            body: Data(#"{"endpoints":[{"url":"https://public.example","upstream":{"url":"http://127.0.0.1:8007"}}]}"#.utf8)
        ))
        let provider = ReadOnlyRemoteConnectorFactsProvider(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            target: "http://127.0.0.1:8007",
            httpRunner: http
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.desired)
        XCTAssertTrue(facts.binaryPresent)
        XCTAssertTrue(facts.configurationPresent)
        XCTAssertTrue(facts.endpointAvailable)
        XCTAssertEqual(facts.endpointCount, 1)
        XCTAssertFalse(String(describing: facts).contains("public.example"))
        XCTAssertFalse(String(describing: facts).contains("127.0.0.1:8007"))
        XCTAssertEqual(http.requests, [apiURL])
    }

    func testDisabledRemoteProviderDoesNotContactTheAgentAPI() throws {
        let http = RecordingDiagnosticHTTPRunner(response: DiagnosticHTTPResponse(
            status: 200,
            url: URL(string: "http://127.0.0.1:4040/api/endpoints")!,
            body: Data(#"{"endpoints":[]}"#.utf8)
        ))
        let provider = ReadOnlyRemoteConnectorFactsProvider(
            desired: false,
            binaryPresent: false,
            configurationPresent: false,
            target: "http://127.0.0.1:8007",
            httpRunner: http
        )

        let facts = try provider.inspect()

        XCTAssertFalse(facts.desired)
        XCTAssertTrue(http.requests.isEmpty)
    }
}

private final class RecordingDiagnosticKeychainClient: KeychainClient, @unchecked Sendable {
    let value: String?
    var createCalls: [String] = []
    var updateCalls: [String] = []

    init(value: String?) {
        self.value = value
    }

    func read(service: String, account: String) throws -> String? { value }

    func create(value: String, service: String, account: String) throws {
        createCalls.append(KeychainItem.key(service: service, account: account))
    }

    func update(value: String, service: String, account: String) throws {
        updateCalls.append(KeychainItem.key(service: service, account: account))
    }
}

private final class RecordingActivationProbe: LocalActivationProbeRunning, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let port: Int
        let token: String
        let requiresInteractiveUI: Bool
    }

    let result: Result<LocalActivationProbeDetails, Error>
    var calls: [Call] = []

    init(result: Result<LocalActivationProbeDetails, Error>) {
        self.result = result
    }

    func runDetailed(
        port: Int,
        capabilityToken: String,
        requiresInteractiveUI: Bool
    ) async throws -> LocalActivationProbeDetails {
        calls.append(Call(
            port: port,
            token: capabilityToken,
            requiresInteractiveUI: requiresInteractiveUI
        ))
        return try result.get()
    }
}

private struct RecordingDiagnosticProcessRunner: DiagnosticProcessRunning {
    let processes: [DiagnosticProcessRecord]

    init(processes: [DiagnosticProcessRecord]) {
        self.processes = processes
    }

    func snapshot() -> [DiagnosticProcessRecord] { processes }
}

private final class RecordingDiagnosticCommandRunner: DiagnosticCommandRunning, @unchecked Sendable {
    let outputs: [DiagnosticCommandRequest: DiagnosticCommandResult]
    var requests: [DiagnosticCommandRequest] = []

    init(outputs: [DiagnosticCommandRequest: DiagnosticCommandResult]) {
        self.outputs = outputs
    }

    func run(_ request: DiagnosticCommandRequest) -> DiagnosticCommandResult {
        requests.append(request)
        return outputs[request] ?? DiagnosticCommandResult(status: 1, stdout: "", stderr: "")
    }
}

private final class RecordingDiagnosticHTTPRunner: DiagnosticHTTPRunning, @unchecked Sendable {
    let response: DiagnosticHTTPResponse
    var requests: [URL] = []

    init(response: DiagnosticHTTPResponse) {
        self.response = response
    }

    func get(_ url: URL) throws -> DiagnosticHTTPResponse {
        requests.append(url)
        return response
    }
}
