import Foundation
import XCTest
@testable import MacOrchestrator

final class RemoteConnectorAdapterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ConnectorAgentAPIURLProtocol.handler = nil
        ConnectorAgentAPIURLProtocol.requests.removeAll()
    }

    override func tearDown() {
        ConnectorAgentAPIURLProtocol.handler = nil
        ConnectorAgentAPIURLProtocol.requests.removeAll()
        super.tearDown()
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(ConnectorAgentAPIURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(ConnectorAgentAPIURLProtocol.self)
        super.tearDown()
    }

    func testCustomAgentAPIBaseAddressIsUsedForEndpointInspection() async throws {
        let customBase = URL(string: "http://127.0.0.1:5050/api")!
        ConnectorAgentAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.url, customBase.appendingPathComponent("endpoints"))
            XCTAssertEqual(request.httpMethod, "GET")
            return .init(
                status: 200,
                body: Data(
                    #"{"endpoints":[{"url":"https://demo.ngrok.app","upstream":{"url":"http://127.0.0.1:8000"}}]}"#.utf8
                )
            )
        }

        let adapter = NgrokRemoteConnectorAdapter(
            agentAPIBaseURL: customBase,
            session: Self.makeSession()
        )

        let inspection = await adapter.inspectAgentAPI()
        let reconciliation = adapter.reconcileEndpoint(
            from: inspection,
            matching: "http://127.0.0.1:8000"
        )

        XCTAssertEqual(
            reconciliation,
            .current(publicURL: URL(string: "https://demo.ngrok.app")!)
        )
    }

    func testAgentAPIUnavailableDoesNotExposeUnderlyingTransportDetails() async {
        ConnectorAgentAPIURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let adapter = NgrokRemoteConnectorAdapter(session: Self.makeSession())
        let inspection = await adapter.inspectAgentAPI()

        XCTAssertEqual(inspection, .unavailable)
        XCTAssertFalse(String(describing: inspection).contains("127.0.0.1:4040"))
    }

    func testMalformedSuccessfulAgentAPIResponseIsInvalid() async {
        ConnectorAgentAPIURLProtocol.handler = { _ in
            .init(status: 200, body: Data("not-json".utf8))
        }

        let adapter = NgrokRemoteConnectorAdapter(session: Self.makeSession())
        let inspection = await adapter.inspectAgentAPI()

        XCTAssertEqual(inspection, .invalidResponse)
    }

    func testRejectsNonLoopbackAgentAPIHosts() {
        for value in [
            "http://attacker.example/api",
            "http://192.168.1.8:4040/api",
        ] {
            XCTAssertThrowsError(try AgentAPIAddress(URL(string: value)!))
        }
    }

    func testAcceptsLoopbackAgentAPIWithCustomPort() throws {
        let address = try AgentAPIAddress(URL(string: "http://127.0.0.1:5050/api")!)

        XCTAssertEqual(address.url.absoluteString, "http://127.0.0.1:5050/api")
    }

    func testRejectsAgentAPIUserinfoQueryFragmentAndForeignPath() {
        for value in [
            "http://user:password@127.0.0.1/api",
            "http://127.0.0.1/api?token=secret",
            "http://127.0.0.1/api#fragment",
            "http://127.0.0.1/other",
        ] {
            XCTAssertThrowsError(try AgentAPIAddress(URL(string: value)!))
        }
    }

    func testRejectsPublicOriginUserinfoPathQueryAndFragment() {
        for value in [
            "https://user:password@example.ngrok.app",
            "https://example.ngrok.app/mcp",
            "https://example.ngrok.app?token=secret",
            "https://example.ngrok.app#fragment",
        ] {
            XCTAssertThrowsError(try RemotePublicOrigin(value))
        }
    }

    func testInjectedAgentAPISessionCannotFollowRedirects() async {
        ConnectorAgentAPIURLProtocol.handler = { request in
            .init(
                status: 200,
                body: Data(#"{"endpoints":[]}"#.utf8),
                responseURL: URL(string: "http://attacker.example/api/endpoints")
            )
        }

        let inspection = await NgrokRemoteConnectorAdapter(session: Self.makeSession()).inspectAgentAPI()

        XCTAssertEqual(inspection, .unavailable)
    }

    func testOversizedAgentAPIResponseIsRejectedBeforeDecoding() async {
        ConnectorAgentAPIURLProtocol.handler = { _ in
            .init(status: 200, body: Data(repeating: 0x20, count: 1_048_577))
        }

        let inspection = await NgrokRemoteConnectorAdapter(session: Self.makeSession()).inspectAgentAPI()

        XCTAssertEqual(inspection, .invalidResponse)
    }

    func testSecretBearingAdapterInputsHaveSafeDescriptions() {
        let canary = "adapter-secret-canary"
        let prerequisite = RemoteConnectorPrerequisiteInput(
            executableURL: URL(fileURLWithPath: "/support/ngrok"),
            configurationURL: URL(fileURLWithPath: "/support/ngrok.yml"),
            authenticationToken: canary
        )
        let launch = RemoteConnectorLaunchInput(
            executableURL: URL(fileURLWithPath: "/support/ngrok"),
            configurationURL: URL(fileURLWithPath: "/support/ngrok.yml"),
            tunnelTarget: "http://127.0.0.1:8000",
            ownerID: "owner-123",
            environment: ["TOKEN": canary],
            authenticationToken: canary
        )

        for value in [String(describing: prerequisite), String(reflecting: prerequisite), String(describing: launch), String(reflecting: launch)] {
            XCTAssertFalse(value.contains(canary))
        }
    }

    func testLaunchSpecificationPreservesNgrokProductionInputsWithoutLifecycleOwnership() throws {
        let adapter = NgrokRemoteConnectorAdapter()
        let input = RemoteConnectorLaunchInput(
            executableURL: URL(fileURLWithPath: "/support/ngrok"),
            configurationURL: URL(fileURLWithPath: "/support/ngrok.yml"),
            tunnelTarget: "http://127.0.0.1:8000",
            ownerID: "owner-123",
            environment: ["PATH": "/usr/bin"],
            authenticationToken: "synthetic-ngrok-token"
        )

        let specification = try adapter.makeLaunchSpecification(for: input)

        XCTAssertEqual(specification.executableURL, input.executableURL)
        XCTAssertEqual(
            specification.arguments,
            [
                "http", "http://127.0.0.1:8000",
                "--config", "/support/ngrok.yml",
                "--log", "stdout",
                "--log-format", "json",
                "--log-level", "info",
                "--inspect=true",
                "--metadata", "mac-orchestrator-owner=owner-123",
            ]
        )
        XCTAssertEqual(specification.environment["PATH"], "/usr/bin")
        XCTAssertTrue(
            specification.environment["NGROK_AUTHTOKEN"] == "synthetic-ngrok-token",
            "The launch environment did not retain the in-memory authentication token."
        )
        XCTAssertFalse(String(describing: specification).contains("synthetic-ngrok-token"))
        XCTAssertFalse(String(reflecting: specification).contains("synthetic-ngrok-token"))
    }

    func testPrerequisiteValidationReportsMissingProviderInputs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-orchestrator-ngrok-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = root.appendingPathComponent("ngrok")
        let configuration = root.appendingPathComponent("ngrok.yml")
        try Data("ngrok".utf8).write(to: binary)
        try Data("version: 3\nagent: {}\nendpoints: []\n".utf8).write(to: configuration)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let adapter = NgrokRemoteConnectorAdapter()
        let valid = adapter.validatePrerequisites(
            RemoteConnectorPrerequisiteInput(
                executableURL: binary,
                configurationURL: configuration,
                authenticationToken: "synthetic-ngrok-token"
            )
        )
        XCTAssertTrue(valid.isReady)

        let missing = adapter.validatePrerequisites(
            RemoteConnectorPrerequisiteInput(
                executableURL: root.appendingPathComponent("missing-ngrok"),
                configurationURL: root.appendingPathComponent("missing.yml"),
                authenticationToken: nil
            )
        )
        XCTAssertFalse(missing.isReady)
    }

    func testDiagnosticsExposeOnlySafeProviderFacts() {
        let adapter = NgrokRemoteConnectorAdapter()
        let prerequisites = RemoteConnectorPrerequisiteReport(
            executableAvailable: false,
            configurationAvailable: true,
            authenticationConfigured: false,
            agentAPIBaseURLValid: true
        )

        let diagnostics = adapter.diagnostics(
            for: prerequisites,
            inspection: .unavailable,
            reconciliation: .agentAPIUnavailable
        )

        XCTAssertTrue(diagnostics.contains(.missingExecutable))
        XCTAssertTrue(diagnostics.contains(.missingAuthentication))
        XCTAssertTrue(diagnostics.contains(.agentAPIUnavailable))
        XCTAssertFalse(String(describing: diagnostics).contains("synthetic-ngrok-token"))
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectorAgentAPIURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ConnectorAgentAPIURLProtocol: URLProtocol {
    struct Response {
        let status: Int
        let body: Data
        let headers: [String: String]
        let responseURL: URL?

        init(
            status: Int,
            body: Data,
            headers: [String: String] = [:],
            responseURL: URL? = nil
        ) {
            self.status = status
            self.body = body
            self.headers = headers
            self.responseURL = responseURL
        }
    }

    static var handler: ((URLRequest) throws -> Response)?
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        do {
            let response = try XCTUnwrap(Self.handler?(request))
            let responseURL = response.responseURL ?? XCTUnwrap(request.url)
            let httpResponse = try XCTUnwrap(
                HTTPURLResponse(
                    url: responseURL,
                    statusCode: response.status,
                    httpVersion: nil,
                    headerFields: response.headers
                )
            )
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
