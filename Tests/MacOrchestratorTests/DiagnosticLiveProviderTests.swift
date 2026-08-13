import Foundation
import Darwin
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

        XCTAssertFalse(facts.livenessVerified)
        XCTAssertFalse(facts.readinessVerified)
        XCTAssertFalse(facts.sessionEstablished)
        XCTAssertFalse(facts.safeCallSucceeded)
        XCTAssertFalse(String(describing: facts).contains("secret response body"))
    }

    func testActivationAdapterKeepsLivenessAfterHealthSuccessWhenMCPTransportFails() async {
        let probe = RecordingActivationProbe(outcome: .init(
            phase: .initialize,
            error: .transport("network failure")
        ))
        let adapter = LocalActivationProbeAdapter(
            probe: probe,
            keychain: KeychainStore(client: RecordingDiagnosticKeychainClient(value: "connector-secret")),
            configuration: AppConfiguration(ownerID: "owner-1"),
            port: 8007
        )

        let facts = await adapter.inspect()

        XCTAssertTrue(facts.livenessVerified)
        XCTAssertFalse(facts.readinessVerified)
        XCTAssertFalse(facts.sessionEstablished)
    }

    func testActivationAdapterKeepsLivenessAfterHealthSuccessWhenCapabilityTokenIsInvalid() async {
        let probe = RecordingActivationProbe(outcome: .init(
            phase: .initialize,
            error: .invalidCapabilityToken
        ))
        let adapter = LocalActivationProbeAdapter(
            probe: probe,
            keychain: KeychainStore(client: RecordingDiagnosticKeychainClient(value: "connector-secret")),
            configuration: AppConfiguration(ownerID: "owner-1"),
            port: 8007
        )

        let facts = await adapter.inspect()

        XCTAssertTrue(facts.livenessVerified)
        XCTAssertFalse(facts.readinessVerified)
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
        XCTAssertTrue(expectations.expectedTools.contains("clipboard"))
        XCTAssertTrue(expectations.expectedTools.contains("write_file"))
        XCTAssertTrue(expectations.expectedTools.contains("run_terminal_command"))
        XCTAssertTrue(expectations.expectedTools.contains("send_file_to_telegram"))
        XCTAssertFalse(expectations.expectedTools.contains("vector_search"))
    }

    func testCurrentCoreExpectationsAlwaysIncludeShippedClipboardToolWhenGroupDisabled() {
        var configuration = AppConfiguration(ownerID: "owner-1")
        configuration.desiredCapabilities["mac.clipboard.write"] = false

        let expectations = CurrentCoreMCPExpectationProvider().expectations(for: configuration)

        XCTAssertTrue(expectations.expectedTools.contains("clipboard"))
        XCTAssertFalse(expectations.expectedCapabilityGroups.contains("mac.clipboard.write"))
        XCTAssertTrue(expectations.skippedCapabilityGroups.contains("mac.clipboard.write"))
    }

    func testActivationAdapterReportsShippedClipboardGroupWhenClipboardToolIsExposed() async {
        var configuration = AppConfiguration(ownerID: "owner-1")
        configuration.desiredCapabilities["mac.clipboard.write"] = true
        let probe = RecordingActivationProbe(outcome: .init(
            phase: .safeCall,
            details: LocalActivationProbeDetails(
                exposedTools: ["describe", "get_capabilities", "get_session_state", "clipboard"],
                safeCallSucceeded: true
            )
        ))
        let adapter = LocalActivationProbeAdapter(
            probe: probe,
            keychain: KeychainStore(client: RecordingDiagnosticKeychainClient(value: "connector-secret")),
            configuration: configuration,
            port: 8007
        )

        let facts = await adapter.inspect()

        XCTAssertTrue(facts.expectedTools.contains("clipboard"))
        XCTAssertTrue(facts.expectedCapabilityGroups.contains("mac.clipboard.write"))
        XCTAssertTrue(facts.exposedCapabilityGroups.contains("mac.clipboard.write"))
    }

    func testActivationAdapterDoesNotExposeClipboardGroupWhenDisabled() async {
        var configuration = AppConfiguration(ownerID: "owner-1")
        configuration.desiredCapabilities["mac.clipboard.write"] = false
        let probe = RecordingActivationProbe(outcome: .init(
            phase: .safeCall,
            details: LocalActivationProbeDetails(
                exposedTools: ["describe", "get_capabilities", "get_session_state", "clipboard"],
                safeCallSucceeded: true
            )
        ))
        let adapter = LocalActivationProbeAdapter(
            probe: probe,
            keychain: KeychainStore(client: RecordingDiagnosticKeychainClient(value: "connector-secret")),
            configuration: configuration,
            port: 8007
        )

        let facts = await adapter.inspect()

        XCTAssertTrue(facts.expectedTools.contains("clipboard"))
        XCTAssertFalse(facts.expectedCapabilityGroups.contains("mac.clipboard.write"))
        XCTAssertFalse(facts.exposedCapabilityGroups.contains("mac.clipboard.write"))
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

    func testPortProviderFailsClosedWhenMultipleListenersAreReported() throws {
        let runner = RecordingDiagnosticCommandRunner(outputs: [
            DiagnosticCommandRequest(executable: "/usr/sbin/lsof", arguments: [
                "-nP", "-iTCP:8007", "-sTCP:LISTEN", "-t"
            ]): DiagnosticCommandResult(status: 0, stdout: "4242\n4343\n", stderr: "")
        ])
        let provider = ReadOnlyPortFactsProvider(
            port: 8007,
            ownerID: "owner-1",
            commandRunner: runner,
            processRunner: RecordingDiagnosticProcessRunner(processes: [
                DiagnosticProcessRecord(pid: 4242, commandLine: "python automac_mcp.py --managed-owner owner-1", running: true),
                DiagnosticProcessRecord(pid: 4343, commandLine: "python other-server", running: true),
            ])
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.listenerPresent)
        XCTAssertFalse(facts.listenerOwned)
        XCTAssertNil(facts.listenerPID)
    }

    func testPortProviderMarksCommandFailureAndMalformedOutputUnavailable() throws {
        let request = DiagnosticCommandRequest(executable: "/usr/sbin/lsof", arguments: [
            "-nP", "-iTCP:8007", "-sTCP:LISTEN", "-t"
        ])
        for result in [
            DiagnosticCommandResult(status: 1, stdout: "", stderr: "permission denied"),
            DiagnosticCommandResult(status: 0, stdout: "not-a-pid\n", stderr: ""),
        ] {
            let provider = ReadOnlyPortFactsProvider(
                port: 8007,
                commandRunner: RecordingDiagnosticCommandRunner(outputs: [request: result]),
                processRunner: RecordingDiagnosticProcessRunner(processes: [])
            )
            let facts = try provider.inspect()
            XCTAssertFalse(facts.inspectionAvailable)
            XCTAssertFalse(facts.listenerPresent)
        }
        XCTAssertEqual(
            DiagnosticChecks.portSelected(PortFacts(port: 8007, inspectionAvailable: false), configuredPort: 8007).status,
            .warn
        )
    }

    func testPortProviderTreatsAnEmptyNoMatchResultAsAVerifiedFreePort() throws {
        let request = DiagnosticCommandRequest(executable: "/usr/sbin/lsof", arguments: [
            "-nP", "-iTCP:8007", "-sTCP:LISTEN", "-t"
        ])
        let provider = ReadOnlyPortFactsProvider(
            port: 8007,
            commandRunner: RecordingDiagnosticCommandRunner(outputs: [
                request: DiagnosticCommandResult(status: 1, stdout: "", stderr: "")
            ]),
            processRunner: RecordingDiagnosticProcessRunner(processes: [])
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.inspectionAvailable)
        XCTAssertFalse(facts.listenerPresent)
        XCTAssertEqual(DiagnosticChecks.portSelected(facts, configuredPort: 8007).status, .pass)
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

    func testNgrokProviderAcceptsAnExactConfiguredTargetAmongMultipleEndpoints() throws {
        let apiURL = URL(string: "http://127.0.0.1:4040/api/endpoints")!
        let http = RecordingDiagnosticHTTPRunner(response: DiagnosticHTTPResponse(
            status: 200,
            url: apiURL,
            body: Data(#"{"endpoints":[{"url":"https://unrelated.example","upstream":{"url":"http://127.0.0.1:9000"}},{"url":"https://public.example","upstream":{"url":"http://127.0.0.1:8007"}}]}"#.utf8)
        ))
        let provider = ReadOnlyRemoteConnectorFactsProvider(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            target: "http://127.0.0.1:8007",
            httpRunner: http
        )

        let facts = try provider.inspect()

        XCTAssertEqual(facts.endpointCount, 2)
        XCTAssertTrue(facts.endpointAvailable)
        XCTAssertEqual(DiagnosticChecks.remoteEndpoint(facts, desired: true).status, .pass)
    }

    func testNgrokProviderReportsOnlyAuthPresenceAndStillChecksAgentAPI() throws {
        let apiURL = URL(string: "http://127.0.0.1:4040/api/endpoints")!
        let http = RecordingDiagnosticHTTPRunner(response: DiagnosticHTTPResponse(
            status: 200,
            url: apiURL,
            body: Data(#"{"endpoints":[]}"#.utf8)
        ))
        let keychain = RecordingDiagnosticKeychainPresenceProvider(
            facts: KeychainPresenceFacts(states: [.ngrokAuthtoken: .present])
        )
        let provider = ReadOnlyRemoteConnectorFactsProvider(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            target: "http://127.0.0.1:8007",
            httpRunner: http,
            keychainPresenceProvider: keychain
        )

        let inspection = try provider.inspectDetailed()

        XCTAssertEqual(inspection.ngrokAuthtokenPresence, .present)
        XCTAssertEqual(keychain.calls, 1)
        XCTAssertEqual(http.requests, [apiURL])
        XCTAssertFalse(String(describing: inspection).contains("ngrok_"))
    }

    func testNgrokProviderCarriesInjectedArchitectureAndVendorSigningFacts() throws {
        let apiURL = URL(string: "http://127.0.0.1:4040/api/endpoints")!
        let http = RecordingDiagnosticHTTPRunner(response: DiagnosticHTTPResponse(
            status: 200,
            url: apiURL,
            body: Data(#"{"endpoints":[]}"#.utf8)
        ))
        let provider = ReadOnlyRemoteConnectorFactsProvider(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            target: "http://127.0.0.1:8007",
            httpRunner: http,
            binaryArchitecture: "arm64",
            originalVendorSigning: true
        )

        let facts = try provider.inspect()

        XCTAssertEqual(facts.binaryArchitecture, "arm64")
        XCTAssertEqual(facts.originalVendorSigning, true)
    }

    func testNgrokProviderRequiresOneExactOwnedProcessBeforeUsingAgentAPI() throws {
        let apiURL = URL(string: "http://127.0.0.1:4040/api/endpoints")!
        let http = RecordingDiagnosticHTTPRunner(response: DiagnosticHTTPResponse(
            status: 200,
            url: apiURL,
            body: Data(#"{"endpoints":[{"url":"https://public.example","upstream":{"url":"http://127.0.0.1:8007"}}]}"#.utf8)
        ))
        let process = RecordingDiagnosticProcessRunner(processes: [
            DiagnosticProcessRecord(
                pid: 42,
                commandLine: "/opt/ngrok http --config /tmp/ngrok.yml mac-orchestrator-owner=owner-1",
                running: true
            )
        ])
        let provider = ReadOnlyRemoteConnectorFactsProvider(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            target: "http://127.0.0.1:8007",
            httpRunner: http,
            ownerID: "owner-1",
            processRunner: process,
            expectedBinaryPath: "/opt/ngrok"
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.ownershipMarkerPresent)
        XCTAssertTrue(facts.endpointAvailable)
        XCTAssertEqual(http.requests, [apiURL])

        let foreign = ReadOnlyRemoteConnectorFactsProvider(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            target: "http://127.0.0.1:8007",
            httpRunner: http,
            ownerID: "other-owner",
            processRunner: process,
            expectedBinaryPath: "/opt/ngrok"
        )
        XCTAssertFalse(try foreign.inspect().ownershipMarkerPresent)
        XCTAssertEqual(http.requests, [apiURL])
    }

    func testInstalledReleaseProviderDoesNotInferTrustOrIntegrityFromFilenames() throws {
        let fixture = try makeReleaseFixture()
        let paths = fixture.paths
        try FileManager.default.createDirectory(
            at: paths.appURL.appendingPathComponent("Contents/_MASReceipt", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("receipt".utf8).write(to: paths.appURL.appendingPathComponent("Contents/_MASReceipt/receipt"))
        try FileManager.default.createDirectory(
            at: paths.appURL.appendingPathComponent("Contents/_CodeSignature", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("resources".utf8).write(to: paths.appURL.appendingPathComponent("Contents/_CodeSignature/CodeResources"))

        let facts = try ReadOnlyInstalledReleaseFactsProvider(
            paths: paths,
            commandRunner: releaseCommandRunner(paths: paths)
        ).inspect()

        XCTAssertNil(facts.helper.developerIDTrusted)
        XCTAssertFalse(facts.helper.receiptAvailable)
        XCTAssertFalse(facts.helper.integrityAvailable)
    }

    func testNgrokPathProviderUsesFixedReadOnlyArchitectureAndSigningProbes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-orchestrator-ngrok-facts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("ngrok")
        let configuration = root.appendingPathComponent("ngrok.yml")
        try Data("binary-fixture".utf8).write(to: binary)
        try Data("version: 2".utf8).write(to: configuration)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let fileRequest = DiagnosticCommandRequest(executable: "/usr/bin/file", arguments: ["-b", binary.path])
        let signRequest = DiagnosticCommandRequest(executable: "/usr/bin/codesign", arguments: ["-dv", "--verbose=4", binary.path])
        let runner = RecordingDiagnosticCommandRunner(outputs: [
            fileRequest: DiagnosticCommandResult(status: 0, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
            signRequest: DiagnosticCommandResult(status: 0, stdout: "", stderr: "Authority=Developer ID Application: ngrok, Inc.")
        ])
        let apiURL = URL(string: "http://127.0.0.1:4040/api/endpoints")!
        let http = RecordingDiagnosticHTTPRunner(response: DiagnosticHTTPResponse(
            status: 200,
            url: apiURL,
            body: Data(#"{"endpoints":[]}"#.utf8)
        ))

        let provider = ReadOnlyRemoteConnectorFactsProvider(
            desired: true,
            binaryURL: binary,
            configurationURL: configuration,
            target: "http://127.0.0.1:8007",
            httpRunner: http,
            commandRunner: runner
        )
        let facts = try provider.inspect()

        XCTAssertEqual(facts.binaryArchitecture, "arm64")
        XCTAssertEqual(facts.originalVendorSigning, true)
        XCTAssertEqual(runner.requests, [fileRequest, signRequest])
    }

    func testNgrokPathProviderRejectsSymlinkedBinaryWithoutProbingOrContactingAgentAPI() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-orchestrator-ngrok-symlink-\(UUID().uuidString)", isDirectory: true)
        let foreign = root.appendingPathComponent("foreign-ngrok")
        let binary = root.appendingPathComponent("ngrok")
        let configuration = root.appendingPathComponent("ngrok.yml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("binary-fixture".utf8).write(to: foreign)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: foreign.path)
        try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: foreign)
        try Data("version: 2".utf8).write(to: configuration)

        let runner = RecordingDiagnosticCommandRunner(outputs: [:])
        let http = RecordingDiagnosticHTTPRunner(response: DiagnosticHTTPResponse(
            status: 200,
            url: URL(string: "http://127.0.0.1:4040/api/endpoints")!,
            body: Data(#"{"endpoints":[]}"#.utf8)
        ))
        let provider = ReadOnlyRemoteConnectorFactsProvider(
            desired: true,
            binaryURL: binary,
            configurationURL: configuration,
            target: "http://127.0.0.1:8007",
            httpRunner: http,
            commandRunner: runner
        )

        let facts = try provider.inspect()

        XCTAssertFalse(facts.binaryPresent)
        XCTAssertFalse(facts.configurationPresent)
        XCTAssertFalse(facts.endpointAvailable)
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testNgrokProviderUsesSelectiveExistenceOnlyKeychainRequest() throws {
        let apiURL = URL(string: "http://127.0.0.1:4040/api/endpoints")!
        let keychain = RecordingSelectiveDiagnosticKeychainPresenceProvider(
            facts: KeychainPresenceFacts(states: [.ngrokAuthtoken: .present])
        )
        let provider = ReadOnlyRemoteConnectorFactsProvider(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            target: "http://127.0.0.1:8007",
            httpRunner: RecordingDiagnosticHTTPRunner(response: DiagnosticHTTPResponse(
                status: 200,
                url: apiURL,
                body: Data(#"{"endpoints":[]}"#.utf8)
            )),
            keychainPresenceProvider: keychain
        )

        let inspection = try provider.inspectDetailed()

        XCTAssertEqual(inspection.ngrokAuthtokenPresence, .present)
        XCTAssertEqual(keychain.requestedItems, [Set([.ngrokAuthtoken])])
        XCTAssertTrue(keychain.legacyInspectCalls.isEmpty)
    }

    func testNgrokProviderRejectsRedirectedAgentAPIWithoutExposingEndpoint() throws {
        let apiURL = URL(string: "http://127.0.0.1:4040/api/endpoints")!
        let redirectedURL = URL(string: "http://127.0.0.1:4040/redirected")!
        let http = RecordingDiagnosticHTTPRunner(response: DiagnosticHTTPResponse(
            status: 200,
            url: redirectedURL,
            body: Data(#"{"endpoints":[{"url":"https://public.example"}]}"#.utf8)
        ))
        let keychain = RecordingDiagnosticKeychainPresenceProvider(
            facts: KeychainPresenceFacts(states: [.ngrokAuthtoken: .inaccessible])
        )
        let provider = ReadOnlyRemoteConnectorFactsProvider(
            desired: true,
            binaryPresent: true,
            configurationPresent: true,
            target: "http://127.0.0.1:8007",
            httpRunner: http,
            keychainPresenceProvider: keychain
        )

        let inspection = try provider.inspectDetailed()

        XCTAssertEqual(inspection.ngrokAuthtokenPresence, .inaccessible)
        XCTAssertFalse(inspection.facts.endpointAvailable)
        XCTAssertEqual(inspection.facts.endpointCount, 0)
        XCTAssertEqual(http.requests, [apiURL])
    }

    func testDisabledRemoteProviderDoesNotContactTheAgentAPI() throws {
        let http = RecordingDiagnosticHTTPRunner(response: DiagnosticHTTPResponse(
            status: 200,
            url: URL(string: "http://127.0.0.1:4040/api/endpoints")!,
            body: Data(#"{"endpoints":[]}"#.utf8)
        ))
        let keychain = RecordingDiagnosticKeychainPresenceProvider(
            facts: KeychainPresenceFacts(states: [.ngrokAuthtoken: .present])
        )
        let provider = ReadOnlyRemoteConnectorFactsProvider(
            desired: false,
            binaryPresent: false,
            configurationPresent: false,
            target: "http://127.0.0.1:8007",
            httpRunner: http,
            keychainPresenceProvider: keychain
        )

        let facts = try provider.inspect()

        XCTAssertFalse(facts.desired)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(keychain.calls, 0)
    }

    func testLifecycleRejectsMalformedStateAndNonRunningRecordedProcesses() throws {
        let fixture = try makeLifecycleFixture()
        try Data("{malformed".utf8).write(to: fixture.paths.ownedProcessesURL)
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let processRunner = RecordingDiagnosticProcessRunner(processes: [
            DiagnosticProcessRecord(
                pid: 4242,
                commandLine: "python automac_mcp.py --managed-owner owner-1",
                running: false
            )
        ])
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: processRunner
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.launchAgentValid)
        XCTAssertEqual(facts.ownedProcessCount, 0)
        XCTAssertTrue(facts.pidReuseDetected)
    }

    func testLifecycleRejectsDuplicateComponentAssignmentsAndComponentMismatch() throws {
        let fixture = try makeLifecycleFixture()
        let state = OwnedProcessState(ownerID: "owner-1", serverPID: 42, tunnelPID: 42)
        try JSONEncoder().encode(state).write(to: fixture.paths.ownedProcessesURL)
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [
                DiagnosticProcessRecord(pid: 42, commandLine: "ngrok mac-orchestrator-owner=owner-1", running: true),
                DiagnosticProcessRecord(pid: 43, commandLine: "python automac_mcp.py --managed-owner owner-1", running: true),
            ])
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.duplicateOwnedProcesses)
        XCTAssertTrue(facts.pidReuseDetected)
        XCTAssertEqual(facts.ownedProcessCount, 2)
    }

    func testLifecycleUsesExactOwnershipTokensAndRejectsOwnerSubstringReuse() throws {
        let fixture = try makeLifecycleFixture()
        try JSONEncoder().encode(OwnedProcessState(ownerID: "owner-1", serverPID: 42, tunnelPID: nil))
            .write(to: fixture.paths.ownedProcessesURL)
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [
                DiagnosticProcessRecord(
                    pid: 42,
                    commandLine: "python automac_mcp.py --managed-owner owner-10",
                    running: true
                )
            ])
        )

        let facts = try provider.inspect()

        XCTAssertEqual(facts.ownedProcessCount, 0)
        XCTAssertFalse(facts.ownershipMarkerPresent)
        XCTAssertTrue(facts.pidReuseDetected)
    }

    func testLifecycleRejectsDuplicateHelperInstances() throws {
        let fixture = try makeLifecycleFixture()
        try JSONEncoder().encode(OwnedProcessState(ownerID: "owner-1", serverPID: 42, tunnelPID: 43))
            .write(to: fixture.paths.ownedProcessesURL)
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let helperCommand = fixture.paths.helperExecutableURL.path
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [
                DiagnosticProcessRecord(pid: 10, commandLine: helperCommand, running: true),
                DiagnosticProcessRecord(pid: 11, commandLine: helperCommand, running: true),
                DiagnosticProcessRecord(
                    pid: 42,
                    commandLine: "python automac_mcp.py --managed-owner owner-1",
                    running: true
                ),
                DiagnosticProcessRecord(
                    pid: 43,
                    commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-1",
                    running: true
                ),
            ])
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.duplicateHelperInstances)
        XCTAssertTrue(facts.duplicateOwnedProcesses)
        XCTAssertFalse(facts.ownershipMarkerPresent)
    }

    func testLifecycleRejectsOwnedStateWithOwnerButNoComponentPIDs() throws {
        let fixture = try makeLifecycleFixture()
        try JSONEncoder().encode(OwnedProcessState(ownerID: "owner-1", serverPID: nil, tunnelPID: nil))
            .write(to: fixture.paths.ownedProcessesURL)
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [])
        )

        let facts = try provider.inspect()

        XCTAssertFalse(facts.ownershipMarkerPresent)
        XCTAssertTrue(facts.pidReuseDetected)
        XCTAssertEqual(facts.ownedProcessCount, 0)
        XCTAssertNil(facts.serverPID)
        XCTAssertNil(facts.tunnelPID)
    }

    func testLifecycleOwnershipMarkerRequiresMatchingStateOwner() throws {
        let fixture = try makeLifecycleFixture()
        try JSONEncoder().encode(OwnedProcessState(ownerID: "owner-2", serverPID: 42, tunnelPID: nil))
            .write(to: fixture.paths.ownedProcessesURL)
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [
                DiagnosticProcessRecord(
                    pid: 42,
                    commandLine: "python automac_mcp.py --managed-owner owner-1",
                    running: true
                )
            ])
        )

        let facts = try provider.inspect()

        XCTAssertFalse(facts.ownershipMarkerPresent)
    }

    func testLifecycleOwnershipMarkerRequiresLiveProcessesForRecordedPIDs() throws {
        let fixture = try makeLifecycleFixture()
        try JSONEncoder().encode(OwnedProcessState(ownerID: "owner-1", serverPID: 42, tunnelPID: nil))
            .write(to: fixture.paths.ownedProcessesURL)
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [
                DiagnosticProcessRecord(
                    pid: 43,
                    commandLine: "python automac_mcp.py --managed-owner owner-1",
                    running: true
                )
            ])
        )

        let facts = try provider.inspect()

        XCTAssertFalse(facts.ownershipMarkerPresent)
    }

    func testLifecycleOwnershipMarkerAcceptsCompleteUnambiguousOwnedState() throws {
        let fixture = try makeLifecycleFixture()
        try JSONEncoder().encode(OwnedProcessState(ownerID: "owner-1", serverPID: 42, tunnelPID: 43))
            .write(to: fixture.paths.ownedProcessesURL)
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [
                DiagnosticProcessRecord(
                    pid: 42,
                    commandLine: "python automac_mcp.py --managed-owner owner-1",
                    running: true
                ),
                DiagnosticProcessRecord(
                    pid: 43,
                    commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-1",
                    running: true
                ),
            ])
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.ownershipMarkerPresent)
        XCTAssertFalse(facts.pidReuseDetected)
        XCTAssertFalse(facts.duplicateOwnedProcesses)
    }

    func testLifecycleRejectsRepeatedOrConflictingServerOwnershipMarkers() throws {
        let commandLines = [
            "python automac_mcp.py --managed-owner owner-1 --managed-owner owner-1",
            "python automac_mcp.py --managed-owner owner-1 --managed-owner owner-2",
        ]

        for commandLine in commandLines {
            let fixture = try makeLifecycleFixture()
            try JSONEncoder().encode(OwnedProcessState(ownerID: "owner-1", serverPID: 42, tunnelPID: 43))
                .write(to: fixture.paths.ownedProcessesURL)
            try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
            let provider = ReadOnlyLifecycleFactsProvider(
                paths: fixture.paths,
                ownerID: "owner-1",
                commandRunner: launchctlRunner(),
                processRunner: RecordingDiagnosticProcessRunner(processes: [
                    DiagnosticProcessRecord(pid: 42, commandLine: commandLine, running: true),
                    DiagnosticProcessRecord(
                        pid: 43,
                        commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-1",
                        running: true
                    ),
                ])
            )

            let facts = try provider.inspect()

            XCTAssertFalse(facts.ownershipMarkerPresent, commandLine)
            XCTAssertTrue(facts.pidReuseDetected, commandLine)
        }
    }

    func testLifecycleRejectsRepeatedOrConflictingTunnelOwnershipMarkers() throws {
        let commandLines = [
            "ngrok http --metadata mac-orchestrator-owner=owner-1 --metadata mac-orchestrator-owner=owner-1",
            "ngrok http --metadata mac-orchestrator-owner=owner-1 --metadata mac-orchestrator-owner=owner-2",
        ]

        for commandLine in commandLines {
            let fixture = try makeLifecycleFixture()
            try JSONEncoder().encode(OwnedProcessState(ownerID: "owner-1", serverPID: 42, tunnelPID: 43))
                .write(to: fixture.paths.ownedProcessesURL)
            try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
            let provider = ReadOnlyLifecycleFactsProvider(
                paths: fixture.paths,
                ownerID: "owner-1",
                commandRunner: launchctlRunner(),
                processRunner: RecordingDiagnosticProcessRunner(processes: [
                    DiagnosticProcessRecord(
                        pid: 42,
                        commandLine: "python automac_mcp.py --managed-owner owner-1",
                        running: true
                    ),
                    DiagnosticProcessRecord(pid: 43, commandLine: commandLine, running: true),
                ])
            )

            let facts = try provider.inspect()

            XCTAssertFalse(facts.ownershipMarkerPresent, commandLine)
            XCTAssertTrue(facts.pidReuseDetected, commandLine)
        }
    }

    func testLifecycleRejectsMatchingPartialOwnedStateAsPIDReuse() throws {
        let fixture = try makeLifecycleFixture()
        try JSONEncoder().encode(OwnedProcessState(ownerID: "owner-1", serverPID: 42, tunnelPID: nil))
            .write(to: fixture.paths.ownedProcessesURL)
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [
                DiagnosticProcessRecord(
                    pid: 42,
                    commandLine: "python automac_mcp.py --managed-owner owner-1",
                    running: true
                ),
            ])
        )

        let facts = try provider.inspect()

        XCTAssertFalse(facts.ownershipMarkerPresent)
        XCTAssertTrue(facts.pidReuseDetected)
        XCTAssertEqual(facts.serverPID, 42)
        XCTAssertNil(facts.tunnelPID)
    }

    func testLifecycleRejectsMarkerWithoutOwnedProcessRecord() throws {
        let fixture = try makeLifecycleFixture()
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [
                DiagnosticProcessRecord(
                    pid: 42,
                    commandLine: "python automac_mcp.py --managed-owner owner-1",
                    running: true
                )
            ])
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.pidReuseDetected || facts.duplicateOwnedProcesses)
        XCTAssertFalse(facts.ownershipMarkerPresent)
    }

    func testLifecycleRejectsMarkerWhenItsComponentPIDIsMissing() throws {
        let fixture = try makeLifecycleFixture()
        try JSONEncoder().encode(OwnedProcessState(ownerID: "owner-1", serverPID: nil, tunnelPID: 43))
            .write(to: fixture.paths.ownedProcessesURL)
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [
                DiagnosticProcessRecord(
                    pid: 42,
                    commandLine: "python automac_mcp.py --managed-owner owner-1",
                    running: true
                ),
                DiagnosticProcessRecord(
                    pid: 43,
                    commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-1",
                    running: true
                ),
            ])
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.pidReuseDetected || facts.duplicateOwnedProcesses)
    }

    func testLifecycleRejectsCrossComponentMarkerAssignment() throws {
        let fixture = try makeLifecycleFixture()
        try JSONEncoder().encode(OwnedProcessState(ownerID: "owner-1", serverPID: 42, tunnelPID: 43))
            .write(to: fixture.paths.ownedProcessesURL)
        try writeSupportedLaunchAgent(to: fixture.paths.launchAgentURL, helper: fixture.paths.helperExecutableURL)
        let provider = ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [
                DiagnosticProcessRecord(
                    pid: 42,
                    commandLine: "python automac_mcp.py --managed-owner owner-1 --metadata mac-orchestrator-owner=owner-1",
                    running: true
                ),
                DiagnosticProcessRecord(
                    pid: 43,
                    commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-1",
                    running: true
                ),
            ])
        )

        let facts = try provider.inspect()

        XCTAssertTrue(facts.duplicateOwnedProcesses)
        XCTAssertTrue(facts.pidReuseDetected)
    }

    func testLifecycleRejectsUnknownLaunchAgentKeysAndWrongContractValues() throws {
        let fixture = try makeLifecycleFixture()
        let plist: [String: Any] = [
            "Label": "com.jay.mac-orchestrator",
            "ProgramArguments": [fixture.paths.helperExecutableURL.path, "--unexpected"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "Unexpected": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: fixture.paths.launchAgentURL)

        let facts = try ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [])
        ).inspect()

        XCTAssertFalse(facts.launchAgentValid)
    }

    func testLifecycleRejectsMissingLaunchAgentContractKey() throws {
        let fixture = try makeLifecycleFixture()
        let plist: [String: Any] = [
            "Label": "com.jay.mac-orchestrator",
            "ProgramArguments": [fixture.paths.helperExecutableURL.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: fixture.paths.launchAgentURL)

        let facts = try ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [])
        ).inspect()

        XCTAssertFalse(facts.launchAgentValid)
    }

    func testLifecycleAcceptsDistributionLaunchAgentContract() throws {
        let fixture = try makeLifecycleFixture()
        try writeSupportedLaunchAgent(
            to: fixture.paths.launchAgentURL,
            helper: fixture.paths.helperExecutableURL,
            distribution: true
        )

        let facts = try ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [])
        ).inspect()

        XCTAssertTrue(facts.launchAgentValid)
    }

    func testLifecycleRejectsArbitraryLaunchAgentExecutablePath() throws {
        let fixture = try makeLifecycleFixture()
        try writeSupportedLaunchAgent(
            to: fixture.paths.launchAgentURL,
            helper: URL(fileURLWithPath: "/tmp/MacOrchestrator")
        )

        let facts = try ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [])
        ).inspect()

        XCTAssertFalse(facts.launchAgentValid)
    }

    func testLifecycleRejectsLaunchAgentFileAndParentSymlinks() throws {
        let fixture = try makeLifecycleFixture()
        let fileTarget = fixture.root.appendingPathComponent("valid.plist")
        try writeSupportedLaunchAgent(to: fileTarget, helper: fixture.paths.helperExecutableURL)
        try FileManager.default.createSymbolicLink(at: fixture.paths.launchAgentURL, withDestinationURL: fileTarget)

        let fileLinkFacts = try ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [])
        ).inspect()
        XCTAssertFalse(fileLinkFacts.launchAgentValid)

        try FileManager.default.removeItem(at: fixture.paths.launchAgentURL)
        let parent = fixture.paths.launchAgentURL.deletingLastPathComponent()
        let parentTarget = fixture.root.appendingPathComponent("target-launch-agents", isDirectory: true)
        try FileManager.default.createDirectory(at: parentTarget, withIntermediateDirectories: true)
        try writeSupportedLaunchAgent(
            to: parentTarget.appendingPathComponent(fixture.paths.launchAgentURL.lastPathComponent),
            helper: fixture.paths.helperExecutableURL
        )
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: parentTarget)

        let parentLinkFacts = try ReadOnlyLifecycleFactsProvider(
            paths: fixture.paths,
            ownerID: "owner-1",
            commandRunner: launchctlRunner(),
            processRunner: RecordingDiagnosticProcessRunner(processes: [])
        ).inspect()
        XCTAssertFalse(parentLinkFacts.launchAgentValid)
    }

    func testInstalledReleaseProviderReportsCompleteFixtureWithoutSecrets() throws {
        let fixture = try makeReleaseFixture()
        let runner = releaseCommandRunner(paths: fixture.paths)

        let facts = try ReadOnlyInstalledReleaseFactsProvider(paths: fixture.paths, commandRunner: runner).inspect()

        XCTAssertTrue(facts.helperPresent)
        XCTAssertTrue(facts.ownershipMarkerPresent)
        XCTAssertTrue(facts.runtime.runtimePresent)
        XCTAssertTrue(facts.runtime.markerPresent)
        XCTAssertTrue(facts.runtime.payloadPresent)
        XCTAssertTrue(facts.runtime.structurallyValid)
        XCTAssertEqual(facts.helper.architecture, "arm64")
        XCTAssertFalse(String(describing: facts).contains("connector"))
    }

    func testInstalledReleaseProviderRejectsSymlinkedAppParentWithoutExecutingRuntime() throws {
        let fixture = try makeReleaseFixture()
        let appParent = fixture.paths.appURL.deletingLastPathComponent()
        let appTarget = fixture.root.appendingPathComponent("app-target", isDirectory: true)
        try FileManager.default.moveItem(at: appParent, to: appTarget)
        try FileManager.default.createSymbolicLink(at: appParent, withDestinationURL: appTarget)
        let runner = releaseCommandRunner(paths: fixture.paths)

        let facts = try ReadOnlyInstalledReleaseFactsProvider(paths: fixture.paths, commandRunner: runner).inspect()

        XCTAssertFalse(facts.helperPresent)
        XCTAssertFalse(facts.ownershipMarkerPresent)
        XCTAssertFalse(facts.runtime.structurallyValid)
        XCTAssertFalse(runner.requests.contains {
            $0.executable == fixture.paths.runtimePythonURL.path && $0.arguments == ["--version"]
        })
    }

    func testInstalledReleaseProviderRejectsSymlinkedRuntimeDirectoryWithoutExecutingRuntime() throws {
        let fixture = try makeReleaseFixture()
        let runtimeTarget = fixture.root.appendingPathComponent("runtime-target", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.paths.runtimeDirectory, to: runtimeTarget)
        try FileManager.default.createSymbolicLink(at: fixture.paths.runtimeDirectory, withDestinationURL: runtimeTarget)
        let runner = releaseCommandRunner(paths: fixture.paths)

        let facts = try ReadOnlyInstalledReleaseFactsProvider(paths: fixture.paths, commandRunner: runner).inspect()

        XCTAssertFalse(facts.runtime.runtimePresent)
        XCTAssertFalse(facts.runtime.structurallyValid)
        XCTAssertFalse(runner.requests.contains {
            $0.executable == fixture.paths.runtimePythonURL.path && $0.arguments == ["--version"]
        })
    }

    func testInstalledReleaseProviderRejectsNonExecutableHelperAndRuntimeFixtures() throws {
        let fixture = try makeReleaseFixture()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.paths.helperExecutableURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.paths.runtimePythonURL.path
        )

        let facts = try ReadOnlyInstalledReleaseFactsProvider(
            paths: fixture.paths,
            commandRunner: releaseCommandRunner(paths: fixture.paths)
        ).inspect()

        XCTAssertFalse(facts.helperPresent)
        XCTAssertFalse(facts.runtime.runtimePresent)
        XCTAssertFalse(facts.runtime.structurallyValid)
    }

    func testInstalledReleaseProviderRejectsZeroByteExecutableHelper() throws {
        let fixture = try makeReleaseFixture()
        try Data().write(to: fixture.paths.helperExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.paths.helperExecutableURL.path
        )

        let facts = try ReadOnlyInstalledReleaseFactsProvider(
            paths: fixture.paths,
            commandRunner: releaseCommandRunner(paths: fixture.paths)
        ).inspect()

        XCTAssertFalse(facts.helperPresent)
        XCTAssertFalse(facts.runtime.structurallyValid)
    }

    func testInstalledReleaseProviderRejectsZeroByteExecutableRuntime() throws {
        let fixture = try makeReleaseFixture()
        try Data().write(to: fixture.paths.runtimePythonURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.paths.runtimePythonURL.path
        )

        let facts = try ReadOnlyInstalledReleaseFactsProvider(
            paths: fixture.paths,
            commandRunner: releaseCommandRunner(paths: fixture.paths)
        ).inspect()

        XCTAssertFalse(facts.runtime.runtimePresent)
        XCTAssertFalse(facts.runtime.structurallyValid)
    }

    func testInstalledReleaseProviderRejectsEmptyReleaseMarker() throws {
        let fixture = try makeReleaseFixture()
        try Data().write(to: fixture.paths.runtimeMarkerURL)

        let facts = try ReadOnlyInstalledReleaseFactsProvider(
            paths: fixture.paths,
            commandRunner: releaseCommandRunner(paths: fixture.paths)
        ).inspect()

        XCTAssertFalse(facts.runtime.markerPresent)
        XCTAssertNil(facts.releaseVersion)
        XCTAssertFalse(facts.runtime.structurallyValid)
    }

    func testInstalledReleaseProviderRejectsEmptyRuntimePayload() throws {
        let fixture = try makeReleaseFixture()
        try Data().write(to: fixture.paths.runtimeScriptURL)

        let facts = try ReadOnlyInstalledReleaseFactsProvider(
            paths: fixture.paths,
            commandRunner: releaseCommandRunner(paths: fixture.paths)
        ).inspect()

        XCTAssertFalse(facts.runtime.payloadPresent)
        XCTAssertFalse(facts.runtime.structurallyValid)
    }

    func testInstalledReleaseProviderRejectsEmptyBundleMetadata() throws {
        let fixture = try makeReleaseFixture()
        try Data().write(to: fixture.paths.appURL.appendingPathComponent("Contents/Info.plist"))

        let facts = try ReadOnlyInstalledReleaseFactsProvider(
            paths: fixture.paths,
            commandRunner: releaseCommandRunner(paths: fixture.paths)
        ).inspect()

        XCTAssertFalse(facts.helperPresent)
        XCTAssertFalse(facts.runtime.structurallyValid)
    }

    func testDiskProviderReportsCriticalSymlinkWithoutFollowingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("critical")
        try Data("safe".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let facts = try ReadOnlyDiskSpaceProvider(filesystemURL: root, criticalPaths: [link]).inspect()

        XCTAssertTrue(facts.filesystemAccessible)
        XCTAssertEqual(facts.criticalPathSymlinkCount, 1)
    }

    private struct LifecycleFixture {
        let root: URL
        let paths: DiagnosticPathSet
    }

    private func makeLifecycleFixture() throws -> LifecycleFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pathsLaunchAgentParent(home), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return LifecycleFixture(root: root, paths: DiagnosticPathSet(supportDirectory: support, homeDirectory: home))
    }

    private func pathsLaunchAgentParent(_ home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private func writeSupportedLaunchAgent(to url: URL, helper: URL, distribution: Bool = false) throws {
        var plist: [String: Any] = [
            "Label": "com.jay.mac-orchestrator",
            "ProgramArguments": [helper.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
        ]
        if distribution {
            plist["ProgramArguments"] = ["/Applications/Mac Orchestrator.app/Contents/MacOS/MacOrchestrator"]
            let logPath = fixtureHome(from: url).appendingPathComponent("Library/Logs/Mac Orchestrator/launcher.log").path
            plist["ThrottleInterval"] = 5
            plist["ProcessType"] = "Interactive"
            plist["StandardOutPath"] = logPath
            plist["StandardErrorPath"] = logPath
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }

    private func fixtureHome(from launchAgentURL: URL) -> URL {
        launchAgentURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func launchctlRunner() -> RecordingDiagnosticCommandRunner {
        RecordingDiagnosticCommandRunner(outputs: [
            DiagnosticCommandRequest(
                executable: "/bin/launchctl",
                arguments: ["print", "gui/\(getuid())/com.jay.mac-orchestrator"]
            ): .init(status: 0, stdout: "", stderr: "")
        ])
    }

    private func makeReleaseFixture() throws -> (paths: DiagnosticPathSet, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let paths = DiagnosticPathSet(supportDirectory: support, homeDirectory: root.appendingPathComponent("home"))
        try FileManager.default.createDirectory(at: paths.helperExecutableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.runtimePythonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1.2.3".utf8).write(to: paths.runtimeMarkerURL)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: paths.helperExecutableURL)
        try Data("#!/bin/sh\necho Python 3.13.14\n".utf8).write(to: paths.runtimePythonURL)
        try Data("print('fixture')\n".utf8).write(to: paths.runtimeScriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.helperExecutableURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.runtimePythonURL.path)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.jay.mac-orchestrator",
            "CFBundleShortVersionString": "1.2.3",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: paths.appURL.appendingPathComponent("Contents/Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (paths, root)
    }

    private func releaseCommandRunner(paths: DiagnosticPathSet) -> RecordingDiagnosticCommandRunner {
        RecordingDiagnosticCommandRunner(outputs: [
            DiagnosticCommandRequest(executable: "/usr/bin/file", arguments: ["-b", paths.helperExecutableURL.path]): .init(status: 0, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
            DiagnosticCommandRequest(executable: "/usr/bin/codesign", arguments: ["-dv", "--verbose=4", paths.appURL.path]): .init(status: 0, stdout: "", stderr: "Authority=Developer ID Application"),
            DiagnosticCommandRequest(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", paths.appURL.path]): .init(status: 0, stdout: "", stderr: ""),
            DiagnosticCommandRequest(executable: "/usr/bin/file", arguments: ["-b", paths.runtimePythonURL.path]): .init(status: 0, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
            DiagnosticCommandRequest(executable: paths.runtimePythonURL.path, arguments: ["--version"]): .init(status: 0, stdout: "Python 3.13.14\n", stderr: ""),
        ])
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
    let outcome: LocalActivationProbeOutcome?
    var calls: [Call] = []

    init(result: Result<LocalActivationProbeDetails, Error>) {
        self.result = result
        self.outcome = nil
    }

    init(outcome: LocalActivationProbeOutcome) {
        self.result = .failure(LocalActivationProbeError.transport("recorded outcome"))
        self.outcome = outcome
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

    func runOutcome(
        port: Int,
        capabilityToken: String,
        requiresInteractiveUI: Bool
    ) async -> LocalActivationProbeOutcome {
        calls.append(Call(
            port: port,
            token: capabilityToken,
            requiresInteractiveUI: requiresInteractiveUI
        ))
        if let outcome { return outcome }
        do {
            return .init(phase: .safeCall, details: try result.get())
        } catch let error as LocalActivationProbeError {
            return .init(phase: .health, error: error)
        } catch {
            return .init(phase: .health, error: .transport("recorded failure"))
        }
    }
}

private final class RecordingDiagnosticKeychainPresenceProvider: SelectiveKeychainPresenceProviding, @unchecked Sendable {
    let facts: KeychainPresenceFacts
    var calls = 0

    init(facts: KeychainPresenceFacts) {
        self.facts = facts
    }

    func inspect() throws -> KeychainPresenceFacts {
        calls += 1
        return facts
    }

    func inspect(items: Set<KeychainPresenceItem>) throws -> KeychainPresenceFacts {
        calls += 1
        return KeychainPresenceFacts(states: items.reduce(into: [:]) { states, item in
            if let presence = facts.presence(for: item) {
                states[item] = presence
            }
        })
    }
}

private final class RecordingSelectiveDiagnosticKeychainPresenceProvider:
    SelectiveKeychainPresenceProviding,
    @unchecked Sendable {
    let facts: KeychainPresenceFacts
    var requestedItems: [Set<KeychainPresenceItem>] = []
    var legacyInspectCalls: [Bool] = []

    init(facts: KeychainPresenceFacts) {
        self.facts = facts
    }

    func inspect() throws -> KeychainPresenceFacts {
        legacyInspectCalls.append(true)
        return facts
    }

    func inspect(items: Set<KeychainPresenceItem>) throws -> KeychainPresenceFacts {
        requestedItems.append(items)
        return KeychainPresenceFacts(states: items.reduce(into: [:]) { states, item in
            if let presence = facts.presence(for: item) {
                states[item] = presence
            }
        })
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
