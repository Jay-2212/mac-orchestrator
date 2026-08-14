import Foundation

enum RemoteActivationProbeError: Error, Equatable, LocalizedError, Sendable {
    case invalidRemoteURL
    case transport
    case redirectedResponse
    case mcpRequestFailed(method: String, status: Int)
    case mcpResponseInvalid(method: String)
    case mcpError(method: String)
    case missingSessionID
    case invalidSessionID
    case missingRequiredTool
    case unexpectedToolInventory
    case safeCallFailed

    var errorDescription: String? {
        switch self {
        case .invalidRemoteURL:
            return "The remote connector URL is invalid."
        case .transport:
            return "Remote MCP activation request failed."
        case .redirectedResponse:
            return "Remote MCP activation rejected a redirected response."
        case let .mcpRequestFailed(method, status):
            return "Remote MCP \(method) request returned HTTP \(status)."
        case let .mcpResponseInvalid(method):
            return "Remote MCP \(method) response was not a valid JSON-RPC result."
        case let .mcpError(method):
            return "Remote MCP \(method) returned an error."
        case .missingSessionID:
            return "Remote MCP initialize response did not include a session identifier."
        case .invalidSessionID:
            return "Remote MCP initialize response included an invalid session identifier."
        case .missingRequiredTool:
            return "Remote MCP tools/list did not expose the required safe tool inventory."
        case .unexpectedToolInventory:
            return "Remote MCP tools/list exposed an unexpected tool inventory."
        case .safeCallFailed:
            return "Remote MCP get_session_state did not report application-level success."
        }
    }
}

enum RemoteActivationProbePhase: String, Equatable, Sendable {
    case initialize
    case initialized
    case toolsList
    case safeCall
}

struct RemoteActivationProbeDetails: Equatable, Sendable {
    let exposedTools: Set<String>
    let sessionEstablished: Bool
    let safeCallSucceeded: Bool
}

struct RemoteActivationProbeOutcome: Equatable, Sendable {
    let phase: RemoteActivationProbePhase
    let details: RemoteActivationProbeDetails?
    let error: RemoteActivationProbeError?

    init(
        phase: RemoteActivationProbePhase,
        details: RemoteActivationProbeDetails? = nil,
        error: RemoteActivationProbeError? = nil
    ) {
        self.phase = phase
        self.details = details
        self.error = error
    }

    func get() throws -> RemoteActivationProbeDetails {
        if let details {
            return details
        }
        throw error ?? RemoteActivationProbeError.transport
    }
}

struct RemoteActivationProbe: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private static let userAgent = "Mac-Orchestrator-Remote-Activation/1"

    private let url: URL
    private let expectedTools: Set<String>
    private let session: URLSession

    init(
        url: URL,
        expectedTools: Set<String>,
        session: URLSession = Self.makeDefaultSession()
    ) {
        self.url = url
        self.expectedTools = expectedTools
        self.session = session
    }

    var description: String {
        "RemoteActivationProbe"
    }

    var debugDescription: String {
        description
    }

    private static func makeDefaultSession() -> URLSession {
        NoRedirectURLSession.make()
    }

    func run() async throws {
        _ = try await runDetailed()
    }

    func runDetailed() async throws -> RemoteActivationProbeDetails {
        try await runOutcome().get()
    }

    func runOutcome() async -> RemoteActivationProbeOutcome {
        guard Self.isValidRemoteURL(url) else {
            return RemoteActivationProbeOutcome(
                phase: .initialize,
                error: .invalidRemoteURL
            )
        }
        guard expectedTools.contains("get_session_state") else {
            return RemoteActivationProbeOutcome(
                phase: .toolsList,
                error: .missingRequiredTool
            )
        }

        let outcome = await MCPActivationProtocolEngine(
            configuration: MCPActivationProtocolConfiguration(
                endpoint: url,
                session: session,
                userAgent: Self.userAgent,
                inventoryPolicy: .exact(expectedTools),
                requiresInteractiveUI: false
            )
        ).runOutcome()

        guard let details = outcome.details else {
            return RemoteActivationProbeOutcome(
                phase: Self.remotePhase(from: outcome.phase),
                error: Self.remoteError(from: outcome.error ?? .transport)
            )
        }
        return RemoteActivationProbeOutcome(
            phase: .safeCall,
            details: RemoteActivationProbeDetails(
                exposedTools: details.exposedTools,
                sessionEstablished: details.sessionEstablished,
                safeCallSucceeded: details.safeCallSucceeded
            )
        )
    }

    private static func remotePhase(
        from phase: MCPActivationProtocolPhase
    ) -> RemoteActivationProbePhase {
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

    private static func remoteError(
        from error: MCPActivationProtocolError
    ) -> RemoteActivationProbeError {
        switch error {
        case .transport:
            return .transport
        case .redirectedResponse:
            return .redirectedResponse
        case let .requestFailed(method, status):
            return .mcpRequestFailed(method: method, status: status)
        case let .responseInvalid(method):
            return .mcpResponseInvalid(method: method)
        case let .mcpError(method, _):
            return .mcpError(method: method)
        case .missingSessionID:
            return .missingSessionID
        case .invalidSessionID:
            return .invalidSessionID
        case .missingRequiredTool:
            return .missingRequiredTool
        case .unexpectedToolInventory:
            return .unexpectedToolInventory
        case .safeCallFailed, .interactiveUIUnavailable:
            return .safeCallFailed
        }
    }

    private static func isValidRemoteURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            return false
        }
        return true
    }
}
