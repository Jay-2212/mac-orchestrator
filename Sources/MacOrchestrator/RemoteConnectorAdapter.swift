import Foundation

enum RemoteConnectorProvider: String, Codable, Equatable, Sendable {
    case ngrok
}

enum AgentAPIAddressError: Error, Equatable, LocalizedError, Sendable {
    case invalid

    var errorDescription: String? {
        "The remote connector Agent API address is invalid."
    }
}

/// A validated, loopback-only address for the local ngrok Agent API.
struct AgentAPIAddress: Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: URL

    init(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              let host = components.host,
              Self.isLoopbackHost(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "/api",
              components.percentEncodedPath == "/api",
              components.port == nil || (1...65_535).contains(components.port ?? 0),
              let sanitizedURL = components.url else {
            throw AgentAPIAddressError.invalid
        }
        self.url = sanitizedURL
    }

    var description: String {
        "AgentAPIAddress"
    }

    var debugDescription: String {
        description
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" || normalized == "::1" {
            return true
        }

        let octets = normalized.split(separator: ".")
        guard octets.count == 4,
              octets.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let first = Int(octets[0]) else {
            return false
        }
        return first == 127 && octets.dropFirst().allSatisfy { Int($0) != nil && (0...255).contains(Int($0)!) }
    }
}

struct RemoteConnectorPrerequisiteInput: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let executableURL: URL
    let configurationURL: URL
    let authenticationToken: String?

    init(
        executableURL: URL,
        configurationURL: URL,
        authenticationToken: String?
    ) {
        self.executableURL = executableURL
        self.configurationURL = configurationURL
        self.authenticationToken = authenticationToken
    }

    var description: String {
        "RemoteConnectorPrerequisiteInput"
    }

    var debugDescription: String {
        description
    }
}

struct RemoteConnectorPrerequisiteReport: Equatable, Sendable {
    let executableAvailable: Bool
    let configurationAvailable: Bool
    let authenticationConfigured: Bool
    let agentAPIBaseURLValid: Bool

    var isReady: Bool {
        executableAvailable
            && configurationAvailable
            && authenticationConfigured
            && agentAPIBaseURLValid
    }
}

struct RemoteConnectorLaunchInput: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let executableURL: URL
    let configurationURL: URL
    let tunnelTarget: String
    let ownerID: String
    let environment: [String: String]
    let authenticationToken: String?

    init(
        executableURL: URL,
        configurationURL: URL,
        tunnelTarget: String,
        ownerID: String,
        environment: [String: String],
        authenticationToken: String?
    ) {
        self.executableURL = executableURL
        self.configurationURL = configurationURL
        self.tunnelTarget = tunnelTarget
        self.ownerID = ownerID
        self.environment = environment
        self.authenticationToken = authenticationToken
    }

    var description: String {
        "RemoteConnectorLaunchInput"
    }

    var debugDescription: String {
        description
    }
}

struct RemoteConnectorLaunchSpecification: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]

    var description: String {
        "RemoteConnectorLaunchSpecification"
    }

    var debugDescription: String {
        description
    }
}

enum RemoteConnectorAgentAPIInspection: Equatable, Sendable {
    case available(endpoints: [NgrokEndpoint])
    case unavailable
    case invalidResponse
}

enum RemoteConnectorDiagnostic: String, Equatable, Sendable {
    case missingExecutable
    case missingConfiguration
    case missingAuthentication
    case invalidAgentAPIBaseURL
    case agentAPIUnavailable
    case invalidAgentAPIResponse
    case endpointMissing
    case foreignEndpoint
    case ambiguousEndpoint
    case ready
}

enum RemoteConnectorAdapterError: Error, Equatable, LocalizedError, Sendable {
    case invalidAgentAPIBaseURL
    case invalidLaunchInput

    var errorDescription: String? {
        switch self {
        case .invalidAgentAPIBaseURL:
            return "The remote connector Agent API address is invalid."
        case .invalidLaunchInput:
            return "The remote connector launch inputs are invalid."
        }
    }
}

protocol RemoteConnectorAdapter: Sendable {
    var provider: RemoteConnectorProvider { get }

    func validatePrerequisites(
        _ input: RemoteConnectorPrerequisiteInput
    ) -> RemoteConnectorPrerequisiteReport

    func makeLaunchSpecification(
        for input: RemoteConnectorLaunchInput
    ) throws -> RemoteConnectorLaunchSpecification

    func inspectAgentAPI() async -> RemoteConnectorAgentAPIInspection

    func reconcileEndpoint(
        from inspection: RemoteConnectorAgentAPIInspection,
        matching expectedUpstream: String
    ) -> RemoteEndpointReconciliation

    func diagnostics(
        for prerequisites: RemoteConnectorPrerequisiteReport,
        inspection: RemoteConnectorAgentAPIInspection?,
        reconciliation: RemoteEndpointReconciliation?
    ) -> [RemoteConnectorDiagnostic]
}

struct NgrokRemoteConnectorAdapter: RemoteConnectorAdapter, Sendable {
    static let defaultAgentAPIBaseURL = URL(string: "http://127.0.0.1:4040/api")!
    static let maximumAgentAPIResponseBytes = 1_048_576

    private let agentAPIAddress: AgentAPIAddress?
    private let session: URLSession

    init(
        agentAPIBaseURL: URL = Self.defaultAgentAPIBaseURL,
        session: URLSession = NoRedirectURLSession.make()
    ) {
        self.agentAPIAddress = try? AgentAPIAddress(agentAPIBaseURL)
        self.session = session
    }

    var provider: RemoteConnectorProvider { .ngrok }

    func validatePrerequisites(
        _ input: RemoteConnectorPrerequisiteInput
    ) -> RemoteConnectorPrerequisiteReport {
        RemoteConnectorPrerequisiteReport(
            executableAvailable: input.executableURL.isFileURL
                && FileManager.default.isExecutableFile(atPath: input.executableURL.path),
            configurationAvailable: input.configurationURL.isFileURL
                && FileManager.default.fileExists(atPath: input.configurationURL.path),
            authenticationConfigured: Self.hasValue(input.authenticationToken),
            agentAPIBaseURLValid: agentAPIAddress != nil
        )
    }

    func makeLaunchSpecification(
        for input: RemoteConnectorLaunchInput
    ) throws -> RemoteConnectorLaunchSpecification {
        guard input.executableURL.isFileURL,
              input.configurationURL.isFileURL,
              !input.executableURL.path.isEmpty,
              !input.configurationURL.path.isEmpty,
              let tunnelTarget = URL(string: input.tunnelTarget),
              tunnelTarget.scheme?.lowercased() == "http",
              tunnelTarget.host != nil,
              !input.ownerID.isEmpty,
              input.ownerID.rangeOfCharacter(from: .controlCharacters) == nil,
              let authenticationToken = input.authenticationToken,
              !authenticationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteConnectorAdapterError.invalidLaunchInput
        }

        var environment = input.environment
        environment["NGROK_AUTHTOKEN"] = authenticationToken
        return RemoteConnectorLaunchSpecification(
            executableURL: input.executableURL,
            arguments: [
                "http", input.tunnelTarget,
                "--config", input.configurationURL.path,
                "--log", "stdout",
                "--log-format", "json",
                "--log-level", "info",
                "--inspect=true",
                "--metadata", "mac-orchestrator-owner=\(input.ownerID)",
            ],
            environment: environment
        )
    }

    func inspectAgentAPI() async -> RemoteConnectorAgentAPIInspection {
        guard let agentAPIAddress else {
            return .unavailable
        }
        let endpointURL = agentAPIAddress.url.appendingPathComponent("endpoints")
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1
        request.setValue("Mac-Orchestrator-Agent-Inspection/1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.url == endpointURL,
                  httpResponse.statusCode == 200 else {
                return .unavailable
            }
            guard data.count <= Self.maximumAgentAPIResponseBytes else {
                return .invalidResponse
            }
            guard let endpoints = NgrokEndpointParser.endpoints(from: data) else {
                return .invalidResponse
            }
            return .available(endpoints: endpoints)
        } catch {
            return .unavailable
        }
    }

    func reconcileEndpoint(
        from inspection: RemoteConnectorAgentAPIInspection,
        matching expectedUpstream: String
    ) -> RemoteEndpointReconciliation {
        switch inspection {
        case let .available(endpoints):
            return NgrokEndpointParser.reconcile(
                endpoints: endpoints,
                matching: expectedUpstream
            )
        case .unavailable:
            return .agentAPIUnavailable
        case .invalidResponse:
            return .invalidAgentAPIResponse
        }
    }

    func diagnostics(
        for prerequisites: RemoteConnectorPrerequisiteReport,
        inspection: RemoteConnectorAgentAPIInspection?,
        reconciliation: RemoteEndpointReconciliation?
    ) -> [RemoteConnectorDiagnostic] {
        var diagnostics: [RemoteConnectorDiagnostic] = []
        if !prerequisites.executableAvailable {
            diagnostics.append(.missingExecutable)
        }
        if !prerequisites.configurationAvailable {
            diagnostics.append(.missingConfiguration)
        }
        if !prerequisites.authenticationConfigured {
            diagnostics.append(.missingAuthentication)
        }
        if !prerequisites.agentAPIBaseURLValid {
            diagnostics.append(.invalidAgentAPIBaseURL)
        }

        if let inspection {
            switch inspection {
            case .available:
                break
            case .unavailable:
                diagnostics.append(.agentAPIUnavailable)
            case .invalidResponse:
                diagnostics.append(.invalidAgentAPIResponse)
            }
        }
        if let reconciliation {
            switch reconciliation {
            case .current:
                break
            case .missing:
                diagnostics.append(.endpointMissing)
            case .foreign:
                diagnostics.append(.foreignEndpoint)
            case .ambiguous:
                diagnostics.append(.ambiguousEndpoint)
            case .agentAPIUnavailable:
                if !diagnostics.contains(.agentAPIUnavailable) {
                    diagnostics.append(.agentAPIUnavailable)
                }
            case .invalidAgentAPIResponse:
                if !diagnostics.contains(.invalidAgentAPIResponse) {
                    diagnostics.append(.invalidAgentAPIResponse)
                }
            }
        }

        return diagnostics.isEmpty ? [.ready] : diagnostics
    }

    private static func hasValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
