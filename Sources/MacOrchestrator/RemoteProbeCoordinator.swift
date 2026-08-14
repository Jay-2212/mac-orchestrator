import Foundation

enum RemoteProbeFailure: Error, Equatable, LocalizedError, Sendable {
    case agentAPIUnavailable
    case invalidAgentAPIResponse
    case endpointMissing
    case foreignEndpoint
    case ambiguousEndpoint
    case invalidCredentialURL
    case activation(RemoteActivationProbeError)

    var errorDescription: String? {
        switch self {
        case .agentAPIUnavailable:
            return "The remote connector Agent API is unavailable."
        case .invalidAgentAPIResponse:
            return "The remote connector Agent API returned an invalid response."
        case .endpointMissing:
            return "The remote connector endpoint is not available."
        case .foreignEndpoint:
            return "The remote connector endpoint does not target the managed MCP server."
        case .ambiguousEndpoint:
            return "The remote connector endpoint is ambiguous."
        case .invalidCredentialURL:
            return "The remote connector URL could not be constructed safely."
        case let .activation(error):
            return error.localizedDescription
        }
    }
}

struct RemoteProbeRequest: Sendable {
    let tunnelTarget: String
    let connectorToken: String
    let expectedTools: Set<String>?
    let knownPublicOrigin: RemotePublicOrigin?
    let forceAuthenticatedProbe: Bool

    init(
        tunnelTarget: String,
        connectorToken: String,
        expectedTools: Set<String>? = nil,
        knownPublicOrigin: RemotePublicOrigin? = nil,
        forceAuthenticatedProbe: Bool = true
    ) {
        self.tunnelTarget = tunnelTarget
        self.connectorToken = connectorToken
        self.expectedTools = expectedTools
        self.knownPublicOrigin = knownPublicOrigin
        self.forceAuthenticatedProbe = forceAuthenticatedProbe
    }
}

struct RemoteProbeFence: Equatable, Sendable {
    let tunnelProcessID: Int32
    let serverProcessID: Int32
    let tunnelLaunchGeneration: UInt64
    let serverLaunchGeneration: UInt64
    let configurationGeneration: UInt64
    let connectorCredentialGeneration: UInt64
    let knownPublicOrigin: RemotePublicOrigin?
    let localMCPGeneration: UInt64
    let localMCPReady: Bool
    let remoteDesired: Bool
    let serverDesired: Bool
    let maintenance: Bool
    let quitting: Bool

    func matches(_ current: RemoteProbeFence) -> Bool {
        self == current &&
            current.localMCPReady &&
            current.remoteDesired &&
            current.serverDesired &&
            !current.maintenance &&
            !current.quitting
    }
}

enum RemoteProbeResult: Equatable, Sendable {
    case busy
    case unchanged(publicOrigin: RemotePublicOrigin)
    case authenticated(
        publicOrigin: RemotePublicOrigin,
        connectorURL: URL,
        details: RemoteActivationProbeDetails
    )
    case failed(RemoteProbeFailure)
}

/// Owns one remote inspection/authentication operation at a time. It does not
/// own lifecycle state; callers fence its result against their lifecycle
/// authority after the async work completes.
actor RemoteProbeCoordinator {
    typealias ProbeRunner = @Sendable (
        _ url: URL,
        _ expectedTools: Set<String>
    ) async -> RemoteActivationProbeOutcome

    static let activeCoreExpectedTools: Set<String> = ["get_session_state"]

    private let adapter: any RemoteConnectorAdapter
    private let expectedTools: Set<String>
    private let probeRunner: ProbeRunner
    private var operationInFlight = false

    init(
        adapter: any RemoteConnectorAdapter = NgrokRemoteConnectorAdapter(),
        expectedTools: Set<String> = ["get_session_state"],
        probeRunner: @escaping ProbeRunner = { url, expectedTools in
            await RemoteActivationProbe(
                url: url,
                expectedTools: expectedTools
            ).runOutcome()
        }
    ) {
        self.adapter = adapter
        self.expectedTools = expectedTools
        self.probeRunner = probeRunner
    }

    func run(_ request: RemoteProbeRequest) async -> RemoteProbeResult {
        guard !operationInFlight else { return .busy }
        operationInFlight = true
        defer { operationInFlight = false }

        let inspection = await adapter.inspectAgentAPI()
        let reconciliation = adapter.reconcileEndpoint(
            from: inspection,
            matching: request.tunnelTarget
        )

        let publicURL: URL
        switch reconciliation {
        case .current(let currentURL):
            publicURL = currentURL
        case .missing:
            return .failed(.endpointMissing)
        case .foreign:
            return .failed(.foreignEndpoint)
        case .ambiguous:
            return .failed(.ambiguousEndpoint)
        case .agentAPIUnavailable:
            return .failed(.agentAPIUnavailable)
        case .invalidAgentAPIResponse:
            return .failed(.invalidAgentAPIResponse)
        }

        guard let publicOrigin = try? RemotePublicOrigin(publicURL.absoluteString) else {
            return .failed(.invalidAgentAPIResponse)
        }
        if !request.forceAuthenticatedProbe,
           request.knownPublicOrigin == publicOrigin {
            return .unchanged(publicOrigin: publicOrigin)
        }

        guard let connectorURL = ConnectorURLBuilder.make(
            publicOrigin: publicOrigin,
            capabilityToken: request.connectorToken
        ) else {
            return .failed(.invalidCredentialURL)
        }

        let outcome = await probeRunner(
            connectorURL,
            request.expectedTools ?? expectedTools
        )
        guard let details = outcome.details else {
            return .failed(.activation(
                outcome.error ?? .transport
            ))
        }
        return .authenticated(
            publicOrigin: publicOrigin,
            connectorURL: connectorURL,
            details: details
        )
    }
}
