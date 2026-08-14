import Foundation
import XCTest
@testable import MacOrchestrator

final class RemoteAuthenticatedDiagnosticProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DiagnosticRemoteProbeURLProtocol.handler = nil
        URLProtocol.registerClass(DiagnosticRemoteProbeURLProtocol.self)
    }

    override func tearDown() {
        DiagnosticRemoteProbeURLProtocol.handler = nil
        URLProtocol.unregisterClass(DiagnosticRemoteProbeURLProtocol.self)
        super.tearDown()
    }

    func testProviderUsesReadOnlyKeychainAndCanonicalAuthenticatedProbe() async throws {
        DiagnosticRemoteProbeURLProtocol.handler = Self.successResponse
        let keychainClient = DiagnosticRemoteKeychainClient(value: "connector-secret")
        var configuration = AppConfiguration(ownerID: "owner")
        configuration.desiredCapabilities["mac.ui"] = false
        let provider = ReadOnlyRemoteAuthenticatedMCPDiagnosticProvider(
            configuration: configuration,
            keychain: KeychainStore(client: keychainClient),
            adapter: DiagnosticRemoteAdapter(),
            stateStore: EmptyRemoteStateStore(),
            session: Self.makeSession()
        )

        let facts = try await provider.inspect()

        XCTAssertEqual(facts.state, .ready)
        XCTAssertTrue(facts.authenticationSucceeded)
        XCTAssertTrue(facts.safeCallSucceeded)
        XCTAssertTrue(keychainClient.createCalls.isEmpty)
        XCTAssertTrue(keychainClient.updateCalls.isEmpty)
        XCTAssertFalse(String(describing: facts).contains("connector-secret"))
    }

    func testProviderClassifiesInitialize404AsAuthPathRejectionWithoutRotation() async throws {
        DiagnosticRemoteProbeURLProtocol.handler = { _ in
            .init(status: 404, body: Data())
        }
        let keychainClient = DiagnosticRemoteKeychainClient(value: "connector-secret")
        let provider = ReadOnlyRemoteAuthenticatedMCPDiagnosticProvider(
            configuration: AppConfiguration(ownerID: "owner"),
            keychain: KeychainStore(client: keychainClient),
            adapter: DiagnosticRemoteAdapter(),
            stateStore: EmptyRemoteStateStore(),
            session: Self.makeSession()
        )

        let facts = try await provider.inspect()
        let remoteFacts = RemoteConnectorFacts(
            desired: true,
            endpointAvailable: true,
            endpointState: .established,
            agentAPIState: .available,
            localMCPPrerequisite: .available,
            authenticatedReadiness: facts
        )
        let result = DiagnosticChecks.remoteAuthenticatedReadiness(remoteFacts, desired: true)

        XCTAssertEqual(facts.state, .authenticationRejected)
        XCTAssertEqual(result.repair?.id, .retryRemoteConnector)
        XCTAssertTrue(keychainClient.createCalls.isEmpty)
        XCTAssertTrue(keychainClient.updateCalls.isEmpty)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticRemoteProbeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func successResponse(_ request: URLRequest) throws -> DiagnosticRemoteProbeURLProtocol.Response {
        let method = try XCTUnwrap(Self.method(from: request))
        switch method {
        case "initialize":
            return .init(
                status: 200,
                body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                headers: ["Mcp-Session-Id": "remote-session"]
            )
        case "notifications/initialized":
            return .init(status: 202, body: Data())
        case "tools/list":
            let tools = [
                "describe", "get_capabilities", "get_session_state",
                "play_sound_for_user_prompt", "clipboard"
            ]
            return .init(
                status: 200,
                body: Self.rpcResult(["tools": tools.map { ["name": $0] }], id: 2)
            )
        case "tools/call":
            return .init(
                status: 200,
                body: Self.rpcResult([
                    "structuredContent": ["status": "success"],
                    "isError": false,
                ], id: 3)
            )
        default:
            throw NSError(domain: "DiagnosticRemoteProbeTests", code: 1)
        }
    }

    private static func method(from request: URLRequest) -> String? {
        let body: Data
        if let httpBody = request.httpBody {
            body = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4_096)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            body = collected
        } else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return object["method"] as? String
    }

    private static func rpcResult(_ result: [String: Any], id: Int) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ])
    }
}

private struct DiagnosticRemoteAdapter: RemoteConnectorAdapter, Sendable {
    var provider: RemoteConnectorProvider { .ngrok }

    func validatePrerequisites(
        _ input: RemoteConnectorPrerequisiteInput
    ) -> RemoteConnectorPrerequisiteReport {
        RemoteConnectorPrerequisiteReport(
            executableAvailable: true,
            configurationAvailable: true,
            authenticationConfigured: true,
            agentAPIBaseURLValid: true
        )
    }

    func makeLaunchSpecification(
        for input: RemoteConnectorLaunchInput
    ) throws -> RemoteConnectorLaunchSpecification {
        RemoteConnectorLaunchSpecification(
            executableURL: input.executableURL,
            arguments: [],
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
        guard case let .available(endpoints) = inspection else {
            return .agentAPIUnavailable
        }
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

private struct EmptyRemoteStateStore: RemoteConnectorStatePersisting {
    func load() throws -> RemoteConnectorStateV1? { nil }

    func loadOrCreate(provider: RemoteConnectorProvider) throws -> RemoteConnectorStateV1 {
        RemoteConnectorStateV1.fresh(provider: provider)
    }

    func save(_ state: RemoteConnectorStateV1) throws -> RemoteConnectorStateV1 { state }

    func recordHandoff(
        generation: UInt64,
        origin: RemotePublicOrigin,
        at date: Date
    ) throws -> RemoteConnectorStateV1 {
        throw RemoteConnectorStateStoreError.staleHandoff
    }
}

private final class DiagnosticRemoteKeychainClient: KeychainClient, @unchecked Sendable {
    let storedValue: String?
    var createCalls = [String]()
    var updateCalls = [String]()

    init(value: String?) {
        storedValue = value
    }

    func read(service: String, account: String) throws -> String? { storedValue }

    func create(value: String, service: String, account: String) throws {
        createCalls.append(value)
    }

    func update(value: String, service: String, account: String) throws {
        updateCalls.append(value)
    }
}

private final class DiagnosticRemoteProbeURLProtocol: URLProtocol {
    struct Response {
        let status: Int
        let body: Data
        let headers: [String: String]

        init(status: Int, body: Data, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    static var handler: ((URLRequest) throws -> Response)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let response = try XCTUnwrap(Self.handler?(request))
            let httpResponse = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
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
