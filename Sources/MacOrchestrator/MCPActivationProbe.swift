import Foundation

enum MCPActivationToolInventoryPolicy: Sendable {
    case required(Set<String>)
    case exact(Set<String>)
}

enum MCPActivationProtocolPhase: String, Equatable, Sendable {
    case initialize
    case initialized
    case toolsList
    case safeCall
}

struct MCPActivationProtocolConfiguration: Sendable {
    let endpoint: URL
    let session: URLSession
    let userAgent: String?
    let inventoryPolicy: MCPActivationToolInventoryPolicy
    let requiresInteractiveUI: Bool

    init(
        endpoint: URL,
        session: URLSession,
        userAgent: String? = nil,
        inventoryPolicy: MCPActivationToolInventoryPolicy,
        requiresInteractiveUI: Bool = false
    ) {
        self.endpoint = endpoint
        self.session = session
        self.userAgent = userAgent
        self.inventoryPolicy = inventoryPolicy
        self.requiresInteractiveUI = requiresInteractiveUI
    }
}

struct MCPActivationProtocolDetails: Equatable, Sendable {
    let exposedTools: Set<String>
    let sessionEstablished: Bool
    let safeCallSucceeded: Bool
}

struct MCPActivationProtocolOutcome: Equatable, Sendable {
    let phase: MCPActivationProtocolPhase
    let details: MCPActivationProtocolDetails?
    let error: MCPActivationProtocolError?

    init(
        phase: MCPActivationProtocolPhase,
        details: MCPActivationProtocolDetails? = nil,
        error: MCPActivationProtocolError? = nil
    ) {
        self.phase = phase
        self.details = details
        self.error = error
    }

    func get() throws -> MCPActivationProtocolDetails {
        if let details {
            return details
        }
        throw error ?? MCPActivationProtocolError.transport
    }
}

enum MCPActivationProtocolError: Error, Equatable, Sendable {
    case transport
    case redirectedResponse
    case requestFailed(method: String, status: Int)
    case responseInvalid(method: String)
    case mcpError(method: String, message: String)
    case missingSessionID
    case invalidSessionID
    case missingRequiredTool
    case unexpectedToolInventory
    case safeCallFailed
    case interactiveUIUnavailable
}

extension MCPActivationProtocolError: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .transport:
            return "MCPActivationProtocolError.transport"
        case .redirectedResponse:
            return "MCPActivationProtocolError.redirectedResponse"
        case let .requestFailed(method, status):
            return "MCPActivationProtocolError.requestFailed(\(method), \(status))"
        case let .responseInvalid(method):
            return "MCPActivationProtocolError.responseInvalid(\(method))"
        case let .mcpError(method, _):
            return "MCPActivationProtocolError.mcpError(\(method))"
        case .missingSessionID:
            return "MCPActivationProtocolError.missingSessionID"
        case .invalidSessionID:
            return "MCPActivationProtocolError.invalidSessionID"
        case .missingRequiredTool:
            return "MCPActivationProtocolError.missingRequiredTool"
        case .unexpectedToolInventory:
            return "MCPActivationProtocolError.unexpectedToolInventory"
        case .safeCallFailed:
            return "MCPActivationProtocolError.safeCallFailed"
        case .interactiveUIUnavailable:
            return "MCPActivationProtocolError.interactiveUIUnavailable"
        }
    }

    var debugDescription: String {
        description
    }
}

struct MCPActivationProtocolEngine: Sendable {
    private static let protocolVersion = "2025-06-18"
    private static let clientName = "mac-orchestrator-bootstrap"
    private static let clientVersion = "2.0"
    private static let maximumResponseBytes = 1_048_576
    private static let integerJSONNumberTypes: Set<String> = [
        "i", "s", "l", "q", "I", "S", "L", "Q",
    ]

    private let configuration: MCPActivationProtocolConfiguration

    init(configuration: MCPActivationProtocolConfiguration) {
        self.configuration = configuration
    }

    func run() async throws -> MCPActivationProtocolDetails {
        try await runOutcome().get()
    }

    func runOutcome() async -> MCPActivationProtocolOutcome {
        var phase: MCPActivationProtocolPhase = .initialize
        do {
            let initialize = try await request(
                method: "initialize",
                id: 1,
                params: [
                    "protocolVersion": Self.protocolVersion,
                    "capabilities": [:],
                    "clientInfo": [
                        "name": Self.clientName,
                        "version": Self.clientVersion,
                    ],
                ],
                sessionID: nil
            )
            guard initialize.status == 200 else {
                throw MCPActivationProtocolError.requestFailed(
                    method: "initialize",
                    status: initialize.status
                )
            }
            let sessionID = try sessionID(from: initialize.headers)
            try validateResult(initialize.body, method: "initialize", expectedID: 1)
            try validateInitialize(initialize.body)

            phase = .initialized
            let initialized = try await request(
                method: "notifications/initialized",
                id: nil,
                params: [:],
                sessionID: sessionID
            )
            guard initialized.status == 200 || initialized.status == 202 else {
                throw MCPActivationProtocolError.requestFailed(
                    method: "notifications/initialized",
                    status: initialized.status
                )
            }

            phase = .toolsList
            let tools = try await request(
                method: "tools/list",
                id: 2,
                params: [:],
                sessionID: sessionID
            )
            guard tools.status == 200 else {
                throw MCPActivationProtocolError.requestFailed(
                    method: "tools/list",
                    status: tools.status
                )
            }
            let exposedTools = try validateToolsList(tools.body, expectedID: 2)

            phase = .safeCall
            let safeCall = try await request(
                method: "tools/call",
                id: 3,
                params: [
                    "name": "get_session_state",
                    "arguments": [:],
                ],
                sessionID: sessionID
            )
            guard safeCall.status == 200 else {
                throw MCPActivationProtocolError.requestFailed(
                    method: "tools/call",
                    status: safeCall.status
                )
            }
            try validateSuccessfulToolCall(
                safeCall.body,
                expectedID: 3
            )
            return MCPActivationProtocolOutcome(
                phase: .safeCall,
                details: MCPActivationProtocolDetails(
                    exposedTools: exposedTools,
                    sessionEstablished: true,
                    safeCallSucceeded: true
                )
            )
        } catch let error as MCPActivationProtocolError {
            return MCPActivationProtocolOutcome(phase: phase, error: error)
        } catch {
            return MCPActivationProtocolOutcome(phase: phase, error: .transport)
        }
    }

    private func request(
        method: String,
        id: Int?,
        params: [String: Any],
        sessionID: String?
    ) async throws -> MCPProbeResponse {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let userAgent = configuration.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
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
            let (data, response) = try await configuration.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MCPActivationProtocolError.transport
            }
            guard httpResponse.url == configuration.endpoint else {
                throw MCPActivationProtocolError.redirectedResponse
            }
            guard data.count <= Self.maximumResponseBytes else {
                throw MCPActivationProtocolError.responseInvalid(method: method)
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
        } catch let error as MCPActivationProtocolError {
            throw error
        } catch {
            throw MCPActivationProtocolError.transport
        }
    }

    private func sessionID(from headers: [String: String]) throws -> String {
        for (key, value) in headers {
            guard key.caseInsensitiveCompare("Mcp-Session-Id") == .orderedSame else {
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPActivationProtocolError.invalidSessionID
            }
            guard value.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw MCPActivationProtocolError.invalidSessionID
            }
            return value
        }
        throw MCPActivationProtocolError.missingSessionID
    }

    private func validateResult(
        _ data: Data,
        method: String,
        expectedID: Int
    ) throws {
        guard let object = Self.jsonObject(from: data) else {
            throw MCPActivationProtocolError.responseInvalid(method: method)
        }
        guard object["jsonrpc"] as? String == "2.0",
              Self.hasExactIntegerID(object["id"], matching: expectedID) else {
            throw MCPActivationProtocolError.responseInvalid(method: method)
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown MCP error"
            throw MCPActivationProtocolError.mcpError(method: method, message: message)
        }
        guard object["result"] != nil else {
            throw MCPActivationProtocolError.responseInvalid(method: method)
        }
    }

    private func validateInitialize(_ data: Data) throws {
        guard let object = Self.jsonObject(from: data),
              let result = object["result"] as? [String: Any],
              result["protocolVersion"] as? String == Self.protocolVersion else {
            throw MCPActivationProtocolError.responseInvalid(method: "initialize")
        }
    }

    private func validateSuccessfulToolCall(
        _ data: Data,
        expectedID: Int
    ) throws {
        guard let object = Self.jsonObject(from: data) else {
            throw MCPActivationProtocolError.responseInvalid(method: "tools/call")
        }
        guard object["jsonrpc"] as? String == "2.0",
              Self.hasExactIntegerID(object["id"], matching: expectedID) else {
            throw MCPActivationProtocolError.responseInvalid(method: "tools/call")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown MCP error"
            throw MCPActivationProtocolError.mcpError(method: "tools/call", message: message)
        }
        guard let result = object["result"] as? [String: Any] else {
            throw MCPActivationProtocolError.responseInvalid(method: "tools/call")
        }
        if result["isError"] as? Bool == true {
            throw MCPActivationProtocolError.safeCallFailed
        }

        if let structured = result["structuredContent"] as? [String: Any] {
            guard structured["status"] as? String == "success" else {
                throw MCPActivationProtocolError.safeCallFailed
            }
            try validateInteractiveUIReadiness(structured)
            return
        }

        guard let content = result["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String }).first,
              let textData = text.data(using: .utf8),
              let contentObject = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
              contentObject["status"] as? String == "success" else {
            throw MCPActivationProtocolError.responseInvalid(method: "tools/call")
        }
        try validateInteractiveUIReadiness(contentObject)
    }

    private func validateInteractiveUIReadiness(_ result: [String: Any]) throws {
        guard configuration.requiresInteractiveUI else { return }
        guard result["gui_interaction_available"] as? Bool == true else {
            throw MCPActivationProtocolError.interactiveUIUnavailable
        }
    }

    private func validateToolsList(_ data: Data, expectedID: Int) throws -> Set<String> {
        guard let object = Self.jsonObject(from: data) else {
            throw MCPActivationProtocolError.responseInvalid(method: "tools/list")
        }
        guard object["jsonrpc"] as? String == "2.0",
              Self.hasExactIntegerID(object["id"], matching: expectedID) else {
            throw MCPActivationProtocolError.responseInvalid(method: "tools/list")
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown MCP error"
            throw MCPActivationProtocolError.mcpError(method: "tools/list", message: message)
        }
        guard let result = object["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw MCPActivationProtocolError.responseInvalid(method: "tools/list")
        }
        let names: Set<String> = Set(tools.compactMap { tool -> String? in
            guard let name = tool["name"] as? String,
                  !name.isEmpty,
                  name.rangeOfCharacter(from: .controlCharacters) == nil else {
                return nil
            }
            return name
        })

        switch configuration.inventoryPolicy {
        case let .required(required):
            guard required.isSubset(of: names) else {
                throw MCPActivationProtocolError.missingRequiredTool
            }
        case let .exact(expected):
            guard expected.isSubset(of: names) else {
                throw MCPActivationProtocolError.missingRequiredTool
            }
            guard names == expected else {
                throw MCPActivationProtocolError.unexpectedToolInventory
            }
        }
        return names
    }

    private static func hasExactIntegerID(_ value: Any?, matching expected: Int) -> Bool {
        guard let number = value as? NSNumber,
              integerJSONNumberTypes.contains(String(cString: number.objCType)),
              number.intValue == expected,
              number.doubleValue == Double(expected) else {
            return false
        }
        return true
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
