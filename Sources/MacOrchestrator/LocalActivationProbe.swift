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

enum LocalActivationProbePhase: String, Equatable, Sendable {
    case health
    case initialize
    case initialized
    case toolsList
    case safeCall
}

struct LocalActivationProbeOutcome: Equatable, Sendable {
    let phase: LocalActivationProbePhase
    let details: LocalActivationProbeDetails?
    let error: LocalActivationProbeError?

    init(
        phase: LocalActivationProbePhase,
        details: LocalActivationProbeDetails? = nil,
        error: LocalActivationProbeError? = nil
    ) {
        self.phase = phase
        self.details = details
        self.error = error
    }

    func get() throws -> LocalActivationProbeDetails {
        if let details {
            return details
        }
        throw error ?? LocalActivationProbeError.transport("activation failed")
    }
}

struct LocalActivationProbe: Sendable {
    private static let expectedHealthBody = Data(#"{"status":"ok"}"#.utf8)

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
        try await runOutcome(
            port: port,
            capabilityToken: capabilityToken,
            requiresInteractiveUI: requiresInteractiveUI
        ).get()
    }

    func runOutcome(
        port: Int,
        capabilityToken: String,
        requiresInteractiveUI: Bool = false
    ) async -> LocalActivationProbeOutcome {
        var phase: LocalActivationProbePhase = .health
        do {
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

            phase = .initialize
            guard let mcpURL = URL(string: "http://127.0.0.1:\(port)/\(capabilityToken)/mcp") else {
                throw LocalActivationProbeError.invalidCapabilityToken
            }
            let protocolOutcome = await MCPActivationProtocolEngine(
                configuration: MCPActivationProtocolConfiguration(
                    endpoint: mcpURL,
                    session: session,
                    inventoryPolicy: .required(["get_session_state"]),
                    requiresInteractiveUI: requiresInteractiveUI
                )
            ).runOutcome()
            phase = Self.localPhase(from: protocolOutcome.phase)
            if let details = protocolOutcome.details {
                return LocalActivationProbeOutcome(
                    phase: .safeCall,
                    details: LocalActivationProbeDetails(
                        exposedTools: details.exposedTools,
                        safeCallSucceeded: details.safeCallSucceeded
                    )
                )
            }
            throw Self.localError(from: protocolOutcome.error ?? .transport)
        } catch let error as LocalActivationProbeError {
            return LocalActivationProbeOutcome(phase: phase, error: error)
        } catch {
            return LocalActivationProbeOutcome(phase: phase, error: .transport("network failure"))
        }
    }

    private static func localPhase(from phase: MCPActivationProtocolPhase) -> LocalActivationProbePhase {
        switch phase {
        case .initialize:
            return .initialize
        case .initialized:
            return .initialized
        case .toolsList:
            return .toolsList
        case .safeCall:
            return .safeCall
        }
    }

    private static func localError(
        from error: MCPActivationProtocolError
    ) -> LocalActivationProbeError {
        switch error {
        case .transport:
            return .transport("network failure")
        case .redirectedResponse:
            return .transport("unexpected redirect")
        case let .requestFailed(method, status):
            return .mcpRequestFailed(method: method, status: status)
        case let .responseInvalid(method):
            return .mcpResponseInvalid(method: method)
        case let .mcpError(method, message):
            return .mcpError(method: method, message: message)
        case .missingSessionID, .invalidSessionID:
            return .missingSessionID
        case .missingRequiredTool, .unexpectedToolInventory:
            return .mcpResponseInvalid(method: "tools/list")
        case .safeCallFailed:
            return .mcpError(
                method: "tools/call",
                message: "get_session_state returned an application-level error."
            )
        case .interactiveUIUnavailable:
            return .mcpError(
                method: "tools/call",
                message: "the managed UI requester is not ready."
            )
        }
    }
}
