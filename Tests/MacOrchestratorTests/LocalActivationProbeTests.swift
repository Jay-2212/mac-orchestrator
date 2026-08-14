import Foundation
import XCTest
@testable import MacOrchestrator

final class LocalActivationProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ActivationProbeURLProtocol.handler = nil
        ActivationProbeURLProtocol.requests.removeAll()
    }

    override func tearDown() {
        ActivationProbeURLProtocol.handler = nil
        ActivationProbeURLProtocol.requests.removeAll()
        super.tearDown()
    }

    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(ActivationProbeURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(ActivationProbeURLProtocol.self)
        super.tearDown()
    }

    func testProbePerformsExactHealthThenAuthenticatedMCPActivationSequence() async throws {
        let sessionID = "session-123"
        ActivationProbeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/__mac_orchestrator_health":
                return .init(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
            case "/connector-token/mcp":
                let payload = try XCTUnwrap(Self.jsonBody(from: request))
                switch payload["method"] as? String {
                case "initialize":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                        headers: ["Mcp-Session-Id": sessionID]
                    )
                case "notifications/initialized":
                    return .init(status: 202, body: Data())
                case "tools/list":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["tools": [["name": "get_session_state"]]], id: 2)
                    )
                case "tools/call":
                    return .init(
                        status: 200,
                        body: Self.rpcResult([
                            "content": [["type": "text", "text": "ok"]],
                            "structuredContent": [
                                "status": "success",
                                "gui_interaction_available": true,
                            ],
                            "isError": false,
                        ], id: 3)
                    )
                default:
                    XCTFail("Unexpected MCP request in the local activation fixture.")
                    return .init(status: 500, body: Data())
                }
            default:
                XCTFail("Unexpected URL in the local activation fixture.")
                return .init(status: 404, body: Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        try await probe.run(
            port: 8_000,
            capabilityToken: "connector-token",
            requiresInteractiveUI: true
        )

        let requestPaths = ActivationProbeURLProtocol.requests.map { $0.url?.path }
        XCTAssertTrue(
            requestPaths == [
                "/__mac_orchestrator_health",
                "/connector-token/mcp",
                "/connector-token/mcp",
                "/connector-token/mcp",
                "/connector-token/mcp",
            ],
            "The local activation request sequence was unexpected."
        )
        let mcpRequests = ActivationProbeURLProtocol.requests.dropFirst()
        XCTAssertTrue(mcpRequests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == nil
        })
        XCTAssertEqual(
            mcpRequests.dropFirst(2).first?.value(forHTTPHeaderField: "Mcp-Session-Id"),
            sessionID
        )
    }

    func testDetailedProbeReturnsSanitizedToolInventoryFromTheCanonicalSequence() async throws {
        let sessionID = "session-detailed"
        ActivationProbeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/__mac_orchestrator_health":
                return .init(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
            case "/connector-token/mcp":
                let payload = try XCTUnwrap(Self.jsonBody(from: request))
                switch payload["method"] as? String {
                case "initialize":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                        headers: ["Mcp-Session-Id": sessionID]
                    )
                case "notifications/initialized":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), sessionID)
                    return .init(status: 202, body: Data())
                case "tools/list":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), sessionID)
                    return .init(
                        status: 200,
                        body: Self.rpcResult([
                            "tools": [
                                ["name": "describe"],
                                ["name": "get_capabilities"],
                                ["name": "get_session_state"],
                            ],
                        ], id: 2)
                    )
                case "tools/call":
                    XCTAssertEqual((payload["params"] as? [String: Any])?["name"] as? String, "get_session_state")
                    return .init(
                        status: 200,
                        body: Self.rpcResult([
                            "structuredContent": ["status": "success"],
                            "isError": false,
                        ], id: 3)
                    )
                default:
                    XCTFail("Unexpected MCP request in the local activation fixture.")
                    return .init(status: 500, body: Data())
                }
            default:
                XCTFail("Unexpected URL in the local activation fixture.")
                return .init(status: 404, body: Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        let detail = try await probe.runDetailed(
            port: 8_000,
            capabilityToken: "connector-token",
            requiresInteractiveUI: false
        )

        XCTAssertEqual(detail.exposedTools, ["describe", "get_capabilities", "get_session_state"])
        XCTAssertTrue(detail.safeCallSucceeded)
        XCTAssertFalse(String(describing: detail).contains("connector-token"))
    }

    func testDetailedProbeRejectsRedirectedHealthResponse() async throws {
        ActivationProbeURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/__mac_orchestrator_health")
            return .init(
                status: 200,
                body: Data(#"{"status":"ok"}"#.utf8),
                responseURL: URL(string: "http://127.0.0.1:8001/__mac_orchestrator_health")!
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        do {
            _ = try await probe.runDetailed(
                port: 8_000,
                capabilityToken: "connector-token"
            )
            XCTFail("A redirected health response must not activate the runtime.")
        } catch let error as LocalActivationProbeError {
            XCTAssertEqual(error, .transport("unexpected redirect"))
        }
    }

    func testProbeRejectsManagedUIReadinessFailureWhenRequired() async throws {
        ActivationProbeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/__mac_orchestrator_health":
                return .init(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
            case "/connector-token/mcp":
                let payload = try XCTUnwrap(Self.jsonBody(from: request))
                switch payload["method"] as? String {
                case "initialize":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                        headers: ["Mcp-Session-Id": "session-123"]
                    )
                case "notifications/initialized":
                    return .init(status: 202, body: Data())
                case "tools/list":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["tools": [["name": "get_session_state"]]], id: 2)
                    )
                case "tools/call":
                    return .init(
                        status: 200,
                        body: Self.rpcResult([
                            "structuredContent": [
                                "status": "success",
                                "gui_interaction_available": false,
                            ],
                            "isError": false,
                        ], id: 3)
                    )
                default:
                    XCTFail("Unexpected MCP request in the local activation fixture.")
                    return .init(status: 500, body: Data())
                }
            default:
                XCTFail("Unexpected URL in the local activation fixture.")
                return .init(status: 404, body: Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        do {
            try await probe.run(
                port: 8_000,
                capabilityToken: "connector-token",
                requiresInteractiveUI: true
            )
            XCTFail("A managed UI readiness failure must not complete activation.")
        } catch let error as LocalActivationProbeError {
            XCTAssertEqual(
                error,
                .mcpError(method: "tools/call", message: "the managed UI requester is not ready.")
            )
        }
    }

    func testProbeRejectsHealthResponseUnlessStatusAndBodyAreExact() async throws {
        ActivationProbeURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/__mac_orchestrator_health")
            return .init(status: 200, body: Data(#"{"status":"healthy"}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        do {
            try await probe.run(port: 8_000, capabilityToken: "connector-token")
            XCTFail("A noncanonical health response must not activate the runtime.")
        } catch let error as LocalActivationProbeError {
            guard case let .healthCheckFailed(status, body) = error else {
                XCTFail("Unexpected local activation probe error.")
                return
            }
            XCTAssertEqual(status, 200)
            XCTAssertEqual(body, #"{"status":"healthy"}"#)
        }
    }

    func testProbeOutcomeRetainsPostHealthPhaseForRedirectedMCPResponse() async throws {
        ActivationProbeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/__mac_orchestrator_health":
                return .init(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
            case "/connector-token/mcp":
                return .init(
                    status: 200,
                    body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                    headers: ["Mcp-Session-Id": "session-123"],
                    responseURL: URL(string: "http://127.0.0.1:8001/redirected")
                )
            default:
                XCTFail("Unexpected URL in the local activation fixture.")
                return .init(status: 404, body: Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        let outcome = await probe.runOutcome(port: 8_000, capabilityToken: "connector-token")

        XCTAssertEqual(outcome.phase, .initialize)
        XCTAssertEqual(outcome.error, .transport("unexpected redirect"))
        XCTAssertNil(outcome.details)
    }

    func testProbeRejectsMismatchedJSONRPCResponseID() async throws {
        ActivationProbeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/__mac_orchestrator_health":
                return .init(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
            case "/connector-token/mcp":
                return .init(
                    status: 200,
                    body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 99),
                    headers: ["Mcp-Session-Id": "session-123"]
                )
            default:
                XCTFail("Unexpected URL in the local activation fixture.")
                return .init(status: 404, body: Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        do {
            try await probe.run(port: 8_000, capabilityToken: "connector-token")
            XCTFail("A mismatched JSON-RPC response ID must not activate the runtime.")
        } catch let error as LocalActivationProbeError {
            XCTAssertEqual(error, .mcpResponseInvalid(method: "initialize"))
        }
    }

    func testProbeRejectsWrongCapabilityAuthentication() async throws {
        ActivationProbeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/__mac_orchestrator_health":
                return .init(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
            case "/wrong-token/mcp":
                return .init(status: 401, body: Data())
            default:
                XCTFail("Unexpected URL in the local activation fixture.")
                return .init(status: 404, body: Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        do {
            try await probe.run(port: 8_000, capabilityToken: "wrong-token")
            XCTFail("A wrong capability token must not activate the runtime.")
        } catch let error as LocalActivationProbeError {
            XCTAssertEqual(error, .mcpRequestFailed(method: "initialize", status: 401))
        }
    }

    func testProbeRejectsWrongSessionIdentity() async throws {
        ActivationProbeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/__mac_orchestrator_health":
                return .init(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
            case "/connector-token/mcp":
                let payload = try XCTUnwrap(Self.jsonBody(from: request))
                switch payload["method"] as? String {
                case "initialize":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                        headers: ["Mcp-Session-Id": "session-123"]
                    )
                case "notifications/initialized":
                    return .init(status: 202, body: Data())
                case "tools/list":
                    XCTAssertEqual(
                        request.value(forHTTPHeaderField: "Mcp-Session-Id"),
                        "session-123"
                    )
                    return .init(status: 409, body: Data())
                default:
                    XCTFail("Unexpected MCP request in the local activation fixture.")
                    return .init(status: 500, body: Data())
                }
            default:
                XCTFail("Unexpected URL in the local activation fixture.")
                return .init(status: 404, body: Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        do {
            try await probe.run(port: 8_000, capabilityToken: "connector-token")
            XCTFail("A wrong session identity must not activate the runtime.")
        } catch let error as LocalActivationProbeError {
            XCTAssertEqual(error, .mcpRequestFailed(method: "tools/list", status: 409))
        }
    }

    func testProbeRequiresSafeSessionTool() async throws {
        ActivationProbeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/__mac_orchestrator_health":
                return .init(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
            case "/connector-token/mcp":
                let payload = try XCTUnwrap(Self.jsonBody(from: request))
                switch payload["method"] as? String {
                case "initialize":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                        headers: ["Mcp-Session-Id": "session-123"]
                    )
                case "notifications/initialized":
                    return .init(status: 202, body: Data())
                case "tools/list":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["tools": [["name": "not_safe"]]], id: 2)
                    )
                default:
                    XCTFail("Unexpected MCP request in the local activation fixture.")
                    return .init(status: 500, body: Data())
                }
            default:
                XCTFail("Unexpected URL in the local activation fixture.")
                return .init(status: 404, body: Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        do {
            try await probe.run(port: 8_000, capabilityToken: "connector-token")
            XCTFail("The safe session tool is required for activation.")
        } catch let error as LocalActivationProbeError {
            XCTAssertEqual(error, .mcpResponseInvalid(method: "tools/list"))
        }
    }

    func testProbeRejectsApplicationLevelToolFailure() async throws {
        ActivationProbeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/__mac_orchestrator_health":
                return .init(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
            case "/connector-token/mcp":
                let payload = try XCTUnwrap(Self.jsonBody(from: request))
                switch payload["method"] as? String {
                case "initialize":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                        headers: ["Mcp-Session-Id": "session-123"]
                    )
                case "notifications/initialized":
                    return .init(status: 202, body: Data())
                case "tools/list":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["tools": [["name": "get_session_state"]]], id: 2)
                    )
                case "tools/call":
                    return .init(
                        status: 200,
                        body: Self.rpcResult([
                            "content": [["type": "text", "text": "permission denied"]],
                            "structuredContent": ["status": "error", "error_code": "PERMISSION"],
                            "isError": true,
                        ], id: 3)
                    )
                default:
                    XCTFail("Unexpected MCP request in the local activation fixture.")
                    return .init(status: 500, body: Data())
                }
            default:
                XCTFail("Unexpected URL in the local activation fixture.")
                return .init(status: 404, body: Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        do {
            try await probe.run(port: 8_000, capabilityToken: "connector-token")
            XCTFail("An application-level tool failure must not activate the runtime.")
        } catch let error as LocalActivationProbeError {
            XCTAssertEqual(
                error,
                .mcpError(
                    method: "tools/call",
                    message: "get_session_state returned an application-level error."
                )
            )
        }
    }

    func testProbeRejectsMalformedToolSuccessPayload() async throws {
        ActivationProbeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/__mac_orchestrator_health":
                return .init(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
            case "/connector-token/mcp":
                let payload = try XCTUnwrap(Self.jsonBody(from: request))
                switch payload["method"] as? String {
                case "initialize":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["protocolVersion": "2025-06-18"], id: 1),
                        headers: ["Mcp-Session-Id": "session-123"]
                    )
                case "notifications/initialized":
                    return .init(status: 202, body: Data())
                case "tools/list":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["tools": [["name": "get_session_state"]]], id: 2)
                    )
                case "tools/call":
                    return .init(
                        status: 200,
                        body: Self.rpcResult(["content": []], id: 3)
                    )
                default:
                    XCTFail("Unexpected MCP request in the local activation fixture.")
                    return .init(status: 500, body: Data())
                }
            default:
                XCTFail("Unexpected URL in the local activation fixture.")
                return .init(status: 404, body: Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        do {
            try await probe.run(port: 8_000, capabilityToken: "connector-token")
            XCTFail("A malformed tool result must not activate the runtime.")
        } catch let error as LocalActivationProbeError {
            XCTAssertEqual(error, .mcpResponseInvalid(method: "tools/call"))
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

private final class ActivationProbeURLProtocol: URLProtocol {
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
            let responseURL: URL
            if let explicitResponseURL = response.responseURL {
                responseURL = explicitResponseURL
            } else {
                responseURL = try XCTUnwrap(request.url)
            }
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
