import Foundation
import XCTest
@testable import MacOrchestrator

final class RemoteActivationProbeTests: XCTestCase {
    private let connectorToken = "synthetic-connector-token"
    private let credentialPath = "/credential-route-token/mcp"

    override func setUp() {
        super.setUp()
        RemoteActivationURLProtocol.handler = nil
        RemoteActivationURLProtocol.requests.removeAll()
    }

    override func tearDown() {
        RemoteActivationURLProtocol.handler = nil
        RemoteActivationURLProtocol.requests.removeAll()
        super.tearDown()
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(RemoteActivationURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(RemoteActivationURLProtocol.self)
        super.tearDown()
    }

    func testRemoteInitializeAndSafeActivationSucceedWithExactInventory() async throws {
        RemoteActivationURLProtocol.handler = Self.successHandler()

        let details = try await makeProbe().runDetailed()

        XCTAssertEqual(details.exposedTools, ["get_session_state"])
        XCTAssertTrue(details.sessionEstablished)
        XCTAssertTrue(details.safeCallSucceeded)
        XCTAssertEqual(RemoteActivationURLProtocol.requests.count, 4)
        XCTAssertTrue(RemoteActivationURLProtocol.requests.allSatisfy { request in
            let userAgent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            return userAgent == "Mac-Orchestrator-Remote-Activation/1"
                && !userAgent.localizedCaseInsensitiveContains("Mozilla")
                && request.value(forHTTPHeaderField: "ngrok-skip-browser-warning") == nil
                && request.timeoutInterval > 0
                && request.timeoutInterval <= 3
        })
    }

    func testRemoteProbeRejectsRedirectAtEveryCredentialBearingRequest() async {
        let cases: [(method: String, phase: RemoteActivationProbePhase)] = [
            ("initialize", .initialize),
            ("notifications/initialized", .initialized),
            ("tools/list", .toolsList),
            ("tools/call", .safeCall),
        ]

        for testCase in cases {
            RemoteActivationURLProtocol.requests.removeAll()
            RemoteActivationURLProtocol.handler = { request in
                let payload = try XCTUnwrap(Self.jsonBody(from: request))
                let method = try XCTUnwrap(payload["method"] as? String)
                let response = try XCTUnwrap(Self.successResponse(for: method))
                if method == testCase.method {
                    return .init(
                        status: response.status,
                        body: response.body,
                        headers: response.headers,
                        responseURL: URL(string: "https://redirected.example\(self.credentialPath)")!
                    )
                }
                return response
            }

            let outcome = await makeProbe().runOutcome()

            XCTAssertEqual(outcome.phase, testCase.phase, "The redirect phase was unexpected.")
            XCTAssertEqual(outcome.error, .redirectedResponse, "The redirect method was not rejected.")
            XCTAssertNil(outcome.details, "A redirected probe must not return activation details.")
        }
    }

    func testMissingSessionIDFailsReadiness() async {
        RemoteActivationURLProtocol.handler = { request in
            let payload = try XCTUnwrap(Self.jsonBody(from: request))
            XCTAssertEqual(payload["method"] as? String, "initialize")
            return .init(
                status: 200,
                body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1)
            )
        }

        let outcome = await makeProbe().runOutcome()

        XCTAssertEqual(outcome.phase, .initialize)
        XCTAssertEqual(outcome.error, .missingSessionID)
    }

    func testInvalidSessionIDFailsReadiness() async {
        RemoteActivationURLProtocol.handler = { _ in
            .init(
                status: 200,
                body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                headers: ["Mcp-Session-Id": "   "]
            )
        }

        let outcome = await makeProbe().runOutcome()

        XCTAssertEqual(outcome.phase, .initialize)
        XCTAssertEqual(outcome.error, .invalidSessionID)
    }

    func testInitializedNonSuccessFailsReadiness() async {
        RemoteActivationURLProtocol.handler = { request in
            let payload = try XCTUnwrap(Self.jsonBody(from: request))
            switch payload["method"] as? String {
            case "initialize":
                return .init(
                    status: 200,
                    body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                    headers: ["Mcp-Session-Id": "remote-session"]
                )
            case "notifications/initialized":
                return .init(status: 500, body: Data())
            default:
                XCTFail("Unexpected method")
                return .init(status: 500, body: Data())
            }
        }

        let outcome = await makeProbe().runOutcome()

        XCTAssertEqual(outcome.phase, .initialized)
        XCTAssertEqual(
            outcome.error,
            .mcpRequestFailed(method: "notifications/initialized", status: 500)
        )
    }

    func testToolsListMissingRequiredToolFailsReadiness() async {
        RemoteActivationURLProtocol.handler = Self.successHandler(tools: [])

        let outcome = await makeProbe().runOutcome()

        XCTAssertEqual(outcome.phase, .toolsList)
        XCTAssertEqual(outcome.error, .missingRequiredTool)
    }

    func testUnexpectedPrivilegedToolFailsExactInventoryContract() async {
        RemoteActivationURLProtocol.handler = Self.successHandler(
            tools: ["get_session_state", "run_terminal_command"]
        )

        let outcome = await makeProbe().runOutcome()

        XCTAssertEqual(outcome.phase, .toolsList)
        XCTAssertEqual(outcome.error, .unexpectedToolInventory)
    }

    func testSafeGetSessionStateFailureFailsReadiness() async {
        RemoteActivationURLProtocol.handler = Self.successHandler(
            safeCall: .init(
                status: 200,
                body: Self.rpcResult([
                    "structuredContent": ["status": "failure"],
                    "isError": false,
                ], id: 3)
            )
        )

        let outcome = await makeProbe().runOutcome()

        XCTAssertEqual(outcome.phase, .safeCall)
        XCTAssertEqual(outcome.error, .safeCallFailed)
    }

    func testRemoteProbeDoesNotRequireAccessibilityOrInteractiveUIReadiness() async throws {
        RemoteActivationURLProtocol.handler = Self.successHandler(
            safeCall: .init(
                status: 200,
                body: Self.rpcResult([
                    "structuredContent": ["status": "success"],
                    "isError": false,
                ], id: 3)
            )
        )

        let details = try await makeProbe().runDetailed()

        XCTAssertTrue(details.safeCallSucceeded)
    }

    func testRemoteErrorsAndResultsNeverContainCredentialURLTokenOrPath() async throws {
        let credentialURL = URL(
            string: "https://remote.example\(credentialPath)?access_token=\(connectorToken)"
        )!
        RemoteActivationURLProtocol.handler = { _ in
            .init(
                status: 500,
                body: Data(
                    "server body \(credentialURL.absoluteString) \(connectorToken)".utf8
                )
            )
        }

        let probe = RemoteActivationProbe(
            url: credentialURL,
            expectedTools: ["get_session_state"],
            session: Self.makeSession()
        )
        let outcome = await probe.runOutcome()
        let values = [
            String(describing: probe),
            String(reflecting: probe),
            String(describing: outcome),
            String(reflecting: outcome),
            outcome.error?.localizedDescription ?? "",
        ]

        for value in values {
            XCTAssertFalse(
                value.contains(connectorToken),
                "Remote probe output contained a synthetic connector token."
            )
            XCTAssertFalse(
                value.contains(credentialURL.absoluteString),
                "Remote probe output contained the credential URL."
            )
            XCTAssertFalse(
                value.contains(credentialPath),
                "Remote probe output contained the credential path."
            )
        }

        RemoteActivationURLProtocol.handler = Self.successHandler()
        let details = try await probe.runDetailed()
        let detailValues = [String(describing: details), String(reflecting: details)]
        for value in detailValues {
            XCTAssertFalse(value.contains(connectorToken))
            XCTAssertFalse(value.contains(credentialPath))
        }
    }

    private func makeProbe() -> RemoteActivationProbe {
        RemoteActivationProbe(
            url: URL(string: "https://remote.example\(credentialPath)?access_token=\(connectorToken)")!,
            expectedTools: ["get_session_state"],
            session: Self.makeSession()
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteActivationURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func successHandler(
        tools: [String] = ["get_session_state"],
        safeCall: RemoteActivationURLProtocol.Response? = nil
    ) -> (URLRequest) throws -> RemoteActivationURLProtocol.Response {
        { request in
            let payload = try XCTUnwrap(Self.jsonBody(from: request))
            let method = try XCTUnwrap(payload["method"] as? String)
            return try XCTUnwrap(
                Self.successResponse(for: method, tools: tools, safeCall: safeCall)
            )
        }
    }

    private static func successResponse(
        for method: String,
        tools: [String] = ["get_session_state"],
        safeCall: RemoteActivationURLProtocol.Response? = nil
    ) -> RemoteActivationURLProtocol.Response? {
        switch method {
        case "initialize":
            return .init(
                status: 200,
                body: rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                headers: ["Mcp-Session-Id": "remote-session"]
            )
        case "notifications/initialized":
            return .init(status: 202, body: Data())
        case "tools/list":
            return .init(
                status: 200,
                body: rpcResult(["tools": tools.map { ["name": $0] }], id: 2)
            )
        case "tools/call":
            return safeCall ?? .init(
                status: 200,
                body: rpcResult([
                    "structuredContent": ["status": "success"],
                    "isError": false,
                ], id: 3)
            )
        default:
            return nil
        }
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
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
            data = collected
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func rpcResult(_ result: [String: Any], id: Int) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ])
    }
}

private final class RemoteActivationURLProtocol: URLProtocol {
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
