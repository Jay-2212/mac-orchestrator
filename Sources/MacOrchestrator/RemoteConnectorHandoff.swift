import Foundation

enum RemoteConnectorHandoffError: Error, Equatable, LocalizedError, Sendable {
    case remoteNotConfigured
    case stateUnavailable
    case connectorCredentialUnavailable
    case remoteNotReady
    case probeFailed(RemoteProbeFailure)
    case stateChanged
    case recordFailed

    var errorDescription: String? {
        switch self {
        case .remoteNotConfigured:
            return "Optional remote access is not enabled."
        case .stateUnavailable:
            return "Current remote readiness state could not be evaluated safely."
        case .connectorCredentialUnavailable:
            return "The connector credential is unavailable."
        case .remoteNotReady:
            return "Authenticated remote MCP readiness is not current."
        case let .probeFailed(failure):
            return "Authenticated remote readiness failed: " + failure.localizedDescription
        case .stateChanged:
            return "Remote connector identity changed while the handoff was being prepared."
        case .recordFailed:
            return "The connector handoff could not be recorded safely."
        }
    }
}

/// The URL is intentionally available only to an explicit handoff caller. It
/// is not part of ServiceSnapshot, Doctor facts, or persisted remote state.
struct RemoteConnectorHandoff: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: URL
    let publicOrigin: RemotePublicOrigin
    let connectorCredentialGeneration: UInt64
    let classificationBeforeHandoff: RemoteClientHandoffClassification

    var description: String { "RemoteConnectorHandoff" }
    var debugDescription: String { description }
}

/// Performs one fresh authenticated remote probe for an explicit user
/// handoff. The state journal is used as a second authority so a successful
/// network response cannot by itself create a receipt for stale lifecycle
/// state.
struct RemoteConnectorHandoffService {
    private let configuration: AppConfiguration
    private let keychain: KeychainStore
    private let stateStore: any RemoteConnectorStatePersisting
    private let probeCoordinator: RemoteProbeCoordinator
    private let expectedTools: Set<String>

    init(
        configuration: AppConfiguration,
        keychain: KeychainStore = KeychainStore(),
        adapter: any RemoteConnectorAdapter = NgrokRemoteConnectorAdapter(),
        stateStore: any RemoteConnectorStatePersisting = RemoteConnectorStateStore(),
        probeCoordinator: RemoteProbeCoordinator? = nil,
        expectationsProvider: CurrentCoreMCPExpectationProvider = CurrentCoreMCPExpectationProvider()
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.stateStore = stateStore
        self.expectedTools = expectationsProvider.expectations(for: configuration).expectedTools
        self.probeCoordinator = probeCoordinator ?? RemoteProbeCoordinator(
            adapter: adapter,
            expectedTools: self.expectedTools
        )
    }

    func prepare() async throws -> RemoteConnectorHandoff {
        guard configuration.process.tunnelDesired
                || configuration.desiredCapabilities["remote.connector"] == true else {
            throw RemoteConnectorHandoffError.remoteNotConfigured
        }

        let state = try readyState()
        let connectorToken: String
        do {
            guard let value = try keychain.value(for: .connectorToken), !value.isEmpty else {
                throw RemoteConnectorHandoffError.connectorCredentialUnavailable
            }
            connectorToken = value
        } catch let error as RemoteConnectorHandoffError {
            throw error
        } catch {
            throw RemoteConnectorHandoffError.connectorCredentialUnavailable
        }

        let request = RemoteProbeRequest(
            tunnelTarget: "http://127.0.0.1:\(configuration.localMCPPort)",
            connectorToken: connectorToken,
            expectedTools: expectedTools,
            knownPublicOrigin: state.lastVerifiedPublicOrigin,
            forceAuthenticatedProbe: true
        )
        let result = await probeCoordinator.run(request)
        let publicOrigin: RemotePublicOrigin
        switch result {
        case let .authenticated(origin, _):
            publicOrigin = origin
        case let .failed(failure):
            throw RemoteConnectorHandoffError.probeFailed(failure)
        case .busy:
            throw RemoteConnectorHandoffError.remoteNotReady
        case .unchanged:
            // Handoff always requests a fresh authenticated probe. Treat an
            // unexpected unchanged result as insufficient evidence rather
            // than using a cached identity.
            throw RemoteConnectorHandoffError.remoteNotReady
        }

        let current = try readyState()
        guard current.connectorCredentialGeneration == state.connectorCredentialGeneration,
              current.lastVerifiedPublicOrigin == publicOrigin else {
            throw RemoteConnectorHandoffError.stateChanged
        }
        guard let url = ConnectorURLBuilder.make(
            publicOrigin: publicOrigin,
            capabilityToken: connectorToken
        ) else {
            throw RemoteConnectorHandoffError.connectorCredentialUnavailable
        }

        return RemoteConnectorHandoff(
            url: url,
            publicOrigin: publicOrigin,
            connectorCredentialGeneration: current.connectorCredentialGeneration,
            classificationBeforeHandoff: current.clientHandoffClassification
        )
    }

    @discardableResult
    func record(
        _ handoff: RemoteConnectorHandoff,
        at date: Date = Date()
    ) throws -> RemoteClientHandoffClassification {
        do {
            return try stateStore.recordHandoff(
                generation: handoff.connectorCredentialGeneration,
                origin: handoff.publicOrigin,
                at: date
            ).clientHandoffClassification
        } catch RemoteConnectorStateStoreError.staleHandoff {
            throw RemoteConnectorHandoffError.stateChanged
        } catch {
            throw RemoteConnectorHandoffError.recordFailed
        }
    }

    private func readyState() throws -> RemoteConnectorStateV1 {
        let state: RemoteConnectorStateV1
        do {
            guard let loaded = try stateStore.load() else {
                throw RemoteConnectorHandoffError.stateUnavailable
            }
            state = loaded
        } catch let error as RemoteConnectorHandoffError {
            throw error
        } catch {
            throw RemoteConnectorHandoffError.stateUnavailable
        }

        guard state.provider == .ngrok,
              state.recoveryPhase == .stable,
              state.pendingConnectorCredentialGeneration == nil,
              state.lastRemoteResult == .ready,
              state.lastSuccessfulRemoteProbeAt != nil,
              state.lastVerifiedPublicOrigin != nil else {
            throw RemoteConnectorHandoffError.remoteNotReady
        }
        return state
    }
}

/// Shared by non-handoff wait/recovery commands. It proves authenticated
/// readiness but deliberately does not construct or return a user-visible
/// connector URL.
struct RemoteConnectorReadinessService {
    private let configuration: AppConfiguration
    private let keychain: KeychainStore
    private let probeCoordinator: RemoteProbeCoordinator
    private let expectedTools: Set<String>

    init(
        configuration: AppConfiguration,
        keychain: KeychainStore = KeychainStore(),
        adapter: any RemoteConnectorAdapter = NgrokRemoteConnectorAdapter(),
        probeCoordinator: RemoteProbeCoordinator? = nil,
        expectationsProvider: CurrentCoreMCPExpectationProvider = CurrentCoreMCPExpectationProvider()
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.expectedTools = expectationsProvider.expectations(for: configuration).expectedTools
        self.probeCoordinator = probeCoordinator ?? RemoteProbeCoordinator(
            adapter: adapter,
            expectedTools: self.expectedTools
        )
    }

    func probe() async throws -> RemotePublicOrigin {
        let token: String
        do {
            guard let value = try keychain.value(for: .connectorToken), !value.isEmpty else {
                throw RemoteConnectorHandoffError.connectorCredentialUnavailable
            }
            token = value
        } catch let error as RemoteConnectorHandoffError {
            throw error
        } catch {
            throw RemoteConnectorHandoffError.connectorCredentialUnavailable
        }

        let result = await probeCoordinator.run(RemoteProbeRequest(
            tunnelTarget: "http://127.0.0.1:\(configuration.localMCPPort)",
            connectorToken: token,
            expectedTools: expectedTools,
            forceAuthenticatedProbe: true
        ))
        switch result {
        case let .authenticated(origin, _), let .unchanged(origin):
            return origin
        case let .failed(failure):
            throw RemoteConnectorHandoffError.probeFailed(failure)
        case .busy:
            throw RemoteConnectorHandoffError.remoteNotReady
        }
    }
}
