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
                        body: Self.rpcResult(["content": [["type": "text", "text": "ok"]]], id: 3)
                    )
                default:
                    XCTFail("Unexpected MCP request: \(payload)")
                    return .init(status: 500, body: Data())
                }
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
                return .init(status: 404, body: Data())
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivationProbeURLProtocol.self]
        let probe = LocalActivationProbe(session: URLSession(configuration: configuration))

        try await probe.run(port: 8_000, capabilityToken: "connector-token")

        XCTAssertEqual(ActivationProbeURLProtocol.requests.map { $0.url?.path }, [
            "/__mac_orchestrator_health",
            "/connector-token/mcp",
            "/connector-token/mcp",
            "/connector-token/mcp",
            "/connector-token/mcp",
        ])
        let mcpRequests = ActivationProbeURLProtocol.requests.dropFirst()
        XCTAssertTrue(mcpRequests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == nil
        })
        XCTAssertEqual(
            mcpRequests.dropFirst(2).first?.value(forHTTPHeaderField: "Mcp-Session-Id"),
            sessionID
        )
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
                XCTFail("Unexpected probe error: \(error)")
                return
            }
            XCTAssertEqual(status, 200)
            XCTAssertEqual(body, #"{"status":"healthy"}"#)
        }
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
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
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
                    XCTFail("Unexpected MCP request: \(payload)")
                    return .init(status: 500, body: Data())
                }
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "nil")")
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

        init(status: Int, body: Data, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
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
