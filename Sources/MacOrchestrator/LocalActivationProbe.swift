import Foundation

enum LocalActivationProbeError: Error, Equatable, LocalizedError, Sendable {
    case healthCheckFailed(status: Int, body: String)
    case transport(String)
    case mcpRequestFailed(method: String, status: Int)
    case mcpResponseInvalid(method: String)
    case mcpError(method: String, message: String)
    case missingSessionID
    case invalidCapabilityToken

    var errorDescription: String? {
        switch self {
        case let .healthCheckFailed(status, body):
            _ = body
            return "Local MCP health check was not canonical (HTTP \(status))."
        case .transport:
            return "Local MCP activation request failed."
        case let .mcpRequestFailed(method, status):
            return "Local MCP \(method) request returned HTTP \(status)."
        case let .mcpResponseInvalid(method):
            return "Local MCP \(method) response was not a valid JSON-RPC result."
        case let .mcpError(method, _):
            return "Local MCP \(method) returned an error."
        case .missingSessionID:
            return "Local MCP initialize response did not include a session identifier."
        case .invalidCapabilityToken:
            return "The local connector identity is invalid."
        }
    }
}

struct LocalActivationProbe: Sendable {
    private static let expectedHealthBody = Data(#"{"status":"ok"}"#.utf8)
    private static let protocolVersion = "2025-06-18"

    private let session: URLSession

    init(session: URLSession = Self.makeDefaultSession()) {
        self.session = session
    }

    private static func makeDefaultSession() -> URLSession {
        NoRedirectURLSession.make()
    }

    func run(
        port: Int,
        capabilityToken: String,
        requiresInteractiveUI: Bool = false
    ) async throws {
        _ = try await runDetailed(
            port: port,
            capabilityToken: capabilityToken,
            requiresInteractiveUI: requiresInteractiveUI
        )
    }

    func runDetailed(
        port: Int,
        capabilityToken: String,
        requiresInteractiveUI: Bool = false
    ) async throws -> LocalActivationProbeDetails {
        let healthURL = URL(string: "http://127.0.0.1:\(port)/__mac_orchestrator_health")!
        var healthRequest = URLRequest(url: healthURL)
        healthRequest.httpMethod = "GET"
        healthRequest.timeoutInterval = 2

        let healthResponse: (Data, URLResponse)
        do {
            healthResponse = try await session.data(for: healthRequest)
        } catch {
            throw LocalActivationProbeError.transport("network failure")
        }
        guard let healthHTTPResponse = healthResponse.1 as? HTTPURLResponse,
              healthHTTPResponse.url == healthURL else {
            throw LocalActivationProbeError.transport("unexpected redirect")
        }
        let status = healthHTTPResponse.statusCode
        guard status == 200, healthResponse.0 == Self.expectedHealthBody else {
            throw LocalActivationProbeError.healthCheckFailed(
                status: status,
                body: String(data: healthResponse.0, encoding: .utf8) ?? "<non-UTF8>"
            )
        }

        guard let mcpURL = URL(string: "http://127.0.0.1:\(port)/\(capabilityToken)/mcp") else {
            throw LocalActivationProbeError.invalidCapabilityToken
        }
        let initialize = try await request(
            url: mcpURL,
            method: "initialize",
            id: 1,
            params: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": [:],
                "clientInfo": [
                    "name": "mac-orchestrator-bootstrap",
                    "version": "2.0",
                ],
            ],
            sessionID: nil
        )
        guard initialize.status == 200 else {
            throw LocalActivationProbeError.mcpRequestFailed(
                method: "initialize",
                status: initialize.status
            )
        }
        let sessionID = try sessionID(from: initialize.headers)
        try validateResult(initialize.body, method: "initialize", expectedID: 1)
        try validateInitialize(initialize.body)

        let initialized = try await request(
            url: mcpURL,
            method: "notifications/initialized",
            id: nil,
            params: [:],
            sessionID: sessionID
        )
        guard initialized.status == 200 || initialized.status == 202 else {
            throw LocalActivationProbeError.mcpRequestFailed(
                method: "notifications/initialized",
                status: initialized.status
            )
        }

        let tools = try await request(
            url: mcpURL,
            method: "tools/list",
            id: 2,
            params: [:],
            sessionID: sessionID
        )
        guard tools.status == 200 else {
            throw LocalActivationProbeError.mcpRequestFailed(
                method: "tools/list",
                status: tools.status
            )
        }
        let exposedTools = try validateToolsList(tools.body, expectedID: 2)

        let safeCall = try await request(
            url: mcpURL,
            method: "tools/call",
            id: 3,
            params: [
                "name": "get_session_state",
                "arguments": [:],
            ],
            sessionID: sessionID
        )
        guard safeCall.status == 200 else {
            throw LocalActivationProbeError.mcpRequestFailed(
                method: "tools/call",
                status: safeCall.status
            )
        }
        try validateSuccessfulToolCall(
            safeCall.body,
            expectedID: 3,
            requiresInteractiveUI: requiresInteractiveUI
        )
        return LocalActivationProbeDetails(
            exposedTools: exposedTools,
            safeCallSucceeded: true
        )
    }

    private func request(
        url: URL,
        method: String,
        id: Int?,
        params: [String: Any],
        sessionID: String?
    ) async throws -> MCPProbeResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        if let id {
            payload["id"] = id
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw LocalActivationProbeError.transport("MCP returned a non-HTTP response")
            }
            guard httpResponse.url == url else {
                throw LocalActivationProbeError.transport("unexpected redirect")
            }
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                guard let key = key as? String, let value = value as? String else { continue }
                headers[key] = value
            }
            return MCPProbeResponse(
                status: httpResponse.statusCode,
                headers: headers,
                body: data
            )
        } catch let error as LocalActivationProbeError {
            throw error
        } catch {
            throw LocalActivationProbeError.transport("network failure")
        }
    }

    private func sessionID(from headers: [String: String]) throws -> String {
        for (key, value) in headers {
            if key.caseInsensitiveCompare("Mcp-Session-Id") == .orderedSame, !value.isEmpty {
                return value
            }
        }
        throw LocalActivationProbeError.missingSessionID
    }

    private func validateResult(_ data: Data, method: String, expectedID: Int) throws {
        guard let object = Self.jsonObject(from: data) else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: method)
        }
        guard object["jsonrpc"] as? String == "2.0",
              let responseID = object["id"] as? NSNumber,
              responseID.intValue == expectedID else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: method)
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown MCP error"
            throw LocalActivationProbeError.mcpError(method: method, message: message)
        }
        guard object["result"] != nil else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: method)
        }
    }

    private func validateInitialize(_ data: Data) throws {
        guard let object = Self.jsonObject(from: data),
              let result = object["result"] as? [String: Any],
              result["protocolVersion"] as? String == Self.protocolVersion else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: "initialize")
        }
    }

    private func validateSuccessfulToolCall(
        _ data: Data,
        expectedID: Int,
        requiresInteractiveUI: Bool
    ) throws {
        guard let object = Self.jsonObject(from: data) else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: "tools/call")
        }
        guard object["jsonrpc"] as? String == "2.0",
              let responseID = object["id"] as? NSNumber,
              responseID.intValue == expectedID else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: "tools/call")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown MCP error"
            throw LocalActivationProbeError.mcpError(method: "tools/call", message: message)
        }
        guard let result = object["result"] as? [String: Any] else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: "tools/call")
        }
        if result["isError"] as? Bool == true {
            throw LocalActivationProbeError.mcpError(
                method: "tools/call",
                message: "get_session_state returned an application-level error."
            )
        }

        if let structured = result["structuredContent"] as? [String: Any] {
            guard structured["status"] as? String == "success" else {
                throw LocalActivationProbeError.mcpError(
                    method: "tools/call",
                    message: "get_session_state returned an application-level error."
                )
            }
            try validateInteractiveUIReadiness(
                structured,
                required: requiresInteractiveUI
            )
            return
        }

        guard let content = result["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String }).first,
              let textData = text.data(using: .utf8),
              let contentObject = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
              contentObject["status"] as? String == "success" else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: "tools/call")
        }
        try validateInteractiveUIReadiness(contentObject, required: requiresInteractiveUI)
    }

    private func validateInteractiveUIReadiness(
        _ result: [String: Any],
        required: Bool
    ) throws {
        guard required else { return }
        guard result["gui_interaction_available"] as? Bool == true else {
            throw LocalActivationProbeError.mcpError(
                method: "tools/call",
                message: "the managed UI requester is not ready."
            )
        }
    }

    private func validateToolsList(_ data: Data, expectedID: Int) throws -> Set<String> {
        guard let object = Self.jsonObject(from: data) else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: "tools/list")
        }
        guard object["jsonrpc"] as? String == "2.0",
              let responseID = object["id"] as? NSNumber,
              responseID.intValue == expectedID else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: "tools/list")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown MCP error"
            throw LocalActivationProbeError.mcpError(method: "tools/list", message: message)
        }
        guard let result = object["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: "tools/list")
        }
        let names: Set<String> = Set(tools.compactMap { tool -> String? in
            guard let name = tool["name"] as? String,
                  !name.isEmpty,
                  name.rangeOfCharacter(from: CharacterSet.controlCharacters) == nil else {
                return nil
            }
            return name
        })
        guard names.contains("get_session_state") else {
            throw LocalActivationProbeError.mcpResponseInvalid(method: "tools/list")
        }
        return names
    }

    private static func jsonObject(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }

        let lines = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline) ?? []
        for line in lines.reversed() {
            let value: String = line.hasPrefix("data:")
                ? line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                : String(line)
            guard !value.isEmpty, value != "[DONE]",
                  let lineData = value.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            return object
        }
        return nil
    }
}

private struct MCPProbeResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}
