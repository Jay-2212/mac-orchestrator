import Foundation

struct RemoteConnectorProbe: Equatable, Sendable {
    let origin: RemotePublicOrigin
    let verifiedAt: Date

    init(origin: RemotePublicOrigin, verifiedAt: Date) {
        self.origin = origin
        self.verifiedAt = verifiedAt
    }
}

enum ConnectorRotationPhase: String, Equatable, Sendable {
    case statePreparation
    case localRestart
    case localActivation
    case oldLocalValidation
    case remoteReconciliation
    case remoteReadiness
    case oldRemoteValidation
    case stateCommit
}

protocol ConnectorCredentialRotationHooks {
    func validatePrerequisites() throws
    func restartLocalMCP(using newToken: String) throws
    func validateLocalActivation(using newToken: String) throws
    func validateOldLocalRouteRejects(oldToken: String) throws
    func reconcileRemote(using newToken: String) throws
    func validateRemoteReadiness(using newToken: String) throws -> RemoteConnectorProbe
    func validateOldRemoteRouteRejects(oldToken: String) throws
}

enum ConnectorCredentialRotationError: Error, Equatable, LocalizedError, Sendable {
    case prerequisitesFailed
    case stateUnavailable
    case canonicalCredentialUnavailable
    case tokenGenerationFailed
    case cutoverFailed
    case validationFailed(ConnectorRotationPhase)
    case statePersistenceFailed(ConnectorRotationPhase)
    case interruptedRecoveryRequired

    var errorDescription: String? {
        switch self {
        case .prerequisitesFailed:
            return "Connector credential rotation prerequisites were not satisfied."
        case .stateUnavailable:
            return "Connector credential rotation state could not be evaluated safely."
        case .canonicalCredentialUnavailable:
            return "The canonical connector credential is unavailable."
        case .tokenGenerationFailed:
            return "A fresh connector credential could not be generated."
        case .cutoverFailed:
            return "Connector credential cutover failed; recovery is required."
        case let .validationFailed(phase):
            return "Connector credential validation failed during " + phase.rawValue + "."
        case let .statePersistenceFailed(phase):
            return "Connector credential state could not be persisted during " + phase.rawValue + "."
        case .interruptedRecoveryRequired:
            return "An interrupted connector credential transaction requires forward recovery."
        }
    }
}

struct ConnectorCredentialRotationReceipt: Equatable, Sendable {
    let generation: UInt64
    let handoffGeneration: UInt64
    let probe: RemoteConnectorProbe
}

struct ConnectorCredentialRotationTransaction {
    private let keychain: KeychainStore
    private let stateStore: any RemoteConnectorStatePersisting
    private let hooks: any ConnectorCredentialRotationHooks

    init(
        keychain: KeychainStore,
        stateStore: any RemoteConnectorStatePersisting,
        hooks: any ConnectorCredentialRotationHooks
    ) {
        self.keychain = keychain
        self.stateStore = stateStore
        self.hooks = hooks
    }

    func execute() throws -> ConnectorCredentialRotationReceipt {
        do {
            try hooks.validatePrerequisites()
        } catch {
            throw ConnectorCredentialRotationError.prerequisitesFailed
        }

        let currentState: RemoteConnectorStateV1
        do {
            currentState = try stateStore.loadOrCreate(provider: .ngrok)
        } catch {
            throw ConnectorCredentialRotationError.stateUnavailable
        }
        guard currentState.pendingConnectorCredentialGeneration == nil,
              currentState.recoveryPhase != .cutoverPendingValidation else {
            throw ConnectorCredentialRotationError.interruptedRecoveryRequired
        }

        var previousToken: String?
        do {
            guard let current = try keychain.value(for: .connectorToken), !current.isEmpty else {
                throw ConnectorCredentialRotationError.canonicalCredentialUnavailable
            }
            previousToken = current
        } catch let error as ConnectorCredentialRotationError {
            throw error
        } catch {
            throw ConnectorCredentialRotationError.canonicalCredentialUnavailable
        }
        defer { previousToken = nil }

        let newToken: String
        do {
            newToken = try keychain.generateConnectorToken()
        } catch {
            throw ConnectorCredentialRotationError.tokenGenerationFailed
        }

        let (nextGeneration, overflow) = currentState.connectorCredentialGeneration.addingReportingOverflow(1)
        guard !overflow else {
            throw ConnectorCredentialRotationError.stateUnavailable
        }

        var pendingState = currentState
        pendingState.pendingConnectorCredentialGeneration = nextGeneration
        pendingState.recoveryPhase = .cutoverPendingValidation
        pendingState.lastRemoteResult = .notReady
        do {
            try stateStore.save(pendingState)
        } catch {
            throw ConnectorCredentialRotationError.statePersistenceFailed(.statePreparation)
        }

        do {
            guard let tokenForCutover = previousToken else {
                throw ConnectorCredentialRotationError.canonicalCredentialUnavailable
            }
            try keychain.replaceConnectorToken(expectedCurrent: tokenForCutover, with: newToken)
        } catch {
            // The pending marker is intentionally retained. It is safer than
            // claiming that an independent Keychain/filesystem cutover is known
            // to have not happened after an operation error.
            throw ConnectorCredentialRotationError.cutoverFailed
        }

        var phase = ConnectorRotationPhase.localRestart
        do {
            let probe: RemoteConnectorProbe
            do {
                guard let tokenForNegativeValidation = previousToken else {
                    throw ConnectorCredentialRotationError.canonicalCredentialUnavailable
                }
                try hooks.restartLocalMCP(using: newToken)
                phase = .localActivation
                try hooks.validateLocalActivation(using: newToken)
                phase = .oldLocalValidation
                try hooks.validateOldLocalRouteRejects(oldToken: tokenForNegativeValidation)
                phase = .remoteReconciliation
                try hooks.reconcileRemote(using: newToken)
                phase = .remoteReadiness
                probe = try hooks.validateRemoteReadiness(using: newToken)
                phase = .oldRemoteValidation
                try hooks.validateOldRemoteRouteRejects(oldToken: tokenForNegativeValidation)
            }
            // The old token is no longer needed once both bounded negative
            // validations have completed, before state commit begins.
            previousToken = nil

            var committedState = pendingState
            committedState.connectorCredentialGeneration = nextGeneration
            committedState.pendingConnectorCredentialGeneration = nil
            committedState.recoveryPhase = .stable
            committedState.lastVerifiedPublicOrigin = probe.origin
            committedState.lastSuccessfulRemoteProbeAt = probe.verifiedAt
            committedState.lastRemoteResult = .ready
            committedState.lastConnectorHandoffGeneration = nextGeneration
            phase = .stateCommit
            do {
                try stateStore.save(committedState)
            } catch {
                persistDegradedState(from: pendingState, generation: nextGeneration)
                throw ConnectorCredentialRotationError.statePersistenceFailed(.stateCommit)
            }

            return ConnectorCredentialRotationReceipt(
                generation: nextGeneration,
                handoffGeneration: nextGeneration,
                probe: probe
            )
        } catch let error as ConnectorCredentialRotationError {
            if case .statePersistenceFailed(.stateCommit) = error {
                throw error
            }
            persistDegradedState(from: pendingState, generation: nextGeneration)
            throw error
        } catch {
            persistDegradedState(from: pendingState, generation: nextGeneration)
            throw ConnectorCredentialRotationError.validationFailed(phase)
        }
    }

    private func persistDegradedState(
        from pendingState: RemoteConnectorStateV1,
        generation: UInt64
    ) {
        var degraded = pendingState
        degraded.connectorCredentialGeneration = generation
        degraded.pendingConnectorCredentialGeneration = nil
        degraded.recoveryPhase = .degraded
        degraded.lastRemoteResult = .degraded
        _ = try? stateStore.save(degraded)
    }
}

enum NgrokCredentialFailurePolicy: Equatable, Sendable {
    case preserveExistingCredential
    case failClosedIfCompromised
}

enum NgrokCredentialReplacementPhase: String, Equatable, Sendable {
    case prerequisites
    case launch
    case endpoint
    case readiness
    case commit
}

protocol NgrokCredentialCandidateValidationHooks {
    func validatePrerequisites() throws
    func launchCandidateSession(using candidateAuthtoken: String) throws
    func reconcileCandidateEndpoint() throws
    func validateAuthenticatedRemoteReadiness() throws -> RemoteConnectorProbe
    func restorePriorProviderSession() throws
}

enum NgrokCredentialReplacementError: Error, Equatable, LocalizedError, Sendable {
    case invalidCandidate
    case prerequisitesFailed
    case candidateValidationFailed(NgrokCredentialReplacementPhase)
    case commitFailed
    case failedClosed
    case failClosedUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidCandidate:
            return "The ngrok credential candidate is invalid."
        case .prerequisitesFailed:
            return "ngrok credential replacement prerequisites were not satisfied."
        case let .candidateValidationFailed(phase):
            return "ngrok credential candidate validation failed during " + phase.rawValue + "."
        case .commitFailed:
            return "The validated ngrok credential candidate could not be committed."
        case .failedClosed:
            return "ngrok credential replacement failed closed; recovery is required."
        case .failClosedUnavailable:
            return "ngrok credential replacement could not establish local fail-closed state."
        }
    }
}

struct NgrokCredentialReplacementReceipt: Equatable, Sendable {
    let probe: RemoteConnectorProbe
}

struct NgrokCredentialReplacementTransaction {
    private let keychain: KeychainStore
    private let hooks: any NgrokCredentialCandidateValidationHooks
    private let failurePolicy: NgrokCredentialFailurePolicy

    init(
        keychain: KeychainStore,
        hooks: any NgrokCredentialCandidateValidationHooks,
        failurePolicy: NgrokCredentialFailurePolicy
    ) {
        self.keychain = keychain
        self.hooks = hooks
        self.failurePolicy = failurePolicy
    }

    func execute(candidate: String) throws -> NgrokCredentialReplacementReceipt {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NgrokCredentialReplacementError.invalidCandidate
        }

        var candidateValue: String? = candidate
        defer { candidateValue = nil }
        guard let candidateForValidation = candidateValue else {
            throw NgrokCredentialReplacementError.invalidCandidate
        }

        var currentValue: String?
        do {
            currentValue = try keychain.value(for: .ngrokAuthtoken)
        } catch {
            if failurePolicy == .failClosedIfCompromised {
                throw NgrokCredentialReplacementError.failClosedUnavailable
            }
            throw NgrokCredentialReplacementError.commitFailed
        }

        var phase = NgrokCredentialReplacementPhase.prerequisites
        do {
            try hooks.validatePrerequisites()
            phase = .launch
            try hooks.launchCandidateSession(using: candidateForValidation)
            phase = .endpoint
            try hooks.reconcileCandidateEndpoint()
            phase = .readiness
            let probe = try hooks.validateAuthenticatedRemoteReadiness()
            phase = .commit
            try keychain.replaceNgrokAuthtoken(expectedCurrent: currentValue, with: candidateForValidation)
            currentValue = nil
            return NgrokCredentialReplacementReceipt(probe: probe)
        } catch let error as NgrokCredentialReplacementError {
            throw handleFailure(currentValue: &currentValue, originalError: error)
        } catch {
            let safeError: NgrokCredentialReplacementError
            switch failurePolicy {
            case .preserveExistingCredential:
                try? hooks.restorePriorProviderSession()
                safeError = phase == .commit
                    ? .commitFailed
                    : .candidateValidationFailed(phase)
            case .failClosedIfCompromised:
                do {
                    try keychain.deleteNgrokAuthtoken(expectedCurrent: currentValue)
                    safeError = .failedClosed
                } catch {
                    safeError = .failClosedUnavailable
                }
            }
            currentValue = nil
            throw safeError
        }
    }

    private func handleFailure(
        currentValue: inout String?,
        originalError: NgrokCredentialReplacementError
    ) -> NgrokCredentialReplacementError {
        switch failurePolicy {
        case .preserveExistingCredential:
            try? hooks.restorePriorProviderSession()
            currentValue = nil
            return originalError
        case .failClosedIfCompromised:
            do {
                try keychain.deleteNgrokAuthtoken(expectedCurrent: currentValue)
                currentValue = nil
                return .failedClosed
            } catch {
                currentValue = nil
                return .failClosedUnavailable
            }
        }
    }
}
