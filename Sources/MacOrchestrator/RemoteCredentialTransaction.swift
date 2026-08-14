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

protocol ConnectorCredentialRotationHooks: Sendable {
    func validatePrerequisites() async throws
    func restartLocalMCP(using newToken: String) async throws
    func validateLocalActivation(using newToken: String) async throws
    func validateOldLocalRouteRejects(oldToken: String) async throws
    func reconcileRemote(using newToken: String) async throws
    func validateRemoteReadiness(using newToken: String) async throws -> RemoteConnectorProbe
    func validateOldRemoteRouteRejects(oldToken: String) async throws
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
    let probe: RemoteConnectorProbe
    let clientHandoff: RemoteClientHandoffClassification
}

struct ConnectorCredentialRotationTransaction {
    private let keychain: KeychainStore
    private let stateStore: any RemoteConnectorStatePersisting
    private let hooks: any ConnectorCredentialRotationHooks
    private let coordinator: RemoteCredentialOperationCoordinator

    init(
        keychain: KeychainStore,
        stateStore: any RemoteConnectorStatePersisting,
        hooks: any ConnectorCredentialRotationHooks,
        coordinator: RemoteCredentialOperationCoordinator = .shared
    ) {
        self.keychain = keychain
        self.stateStore = stateStore
        self.hooks = hooks
        self.coordinator = coordinator
    }

    func execute() async throws -> ConnectorCredentialRotationReceipt {
        try await coordinator.acquire()
        do {
            let receipt = try await executeUnlocked()
            await coordinator.release()
            return receipt
        } catch {
            await coordinator.release()
            throw error
        }
    }

    private func executeUnlocked() async throws -> ConnectorCredentialRotationReceipt {
        do {
            try await hooks.validatePrerequisites()
        } catch {
            throw ConnectorCredentialRotationError.prerequisitesFailed
        }

        let currentState: RemoteConnectorStateV1
        do {
            currentState = try stateStore.loadOrCreate(provider: .ngrok)
        } catch {
            throw ConnectorCredentialRotationError.stateUnavailable
        }
        let previousToken: String
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
        let newToken: String
        do {
            newToken = try keychain.generateConnectorToken()
        } catch {
            throw ConnectorCredentialRotationError.tokenGenerationFailed
        }

        let baseGeneration = max(
            currentState.connectorCredentialGeneration,
            currentState.pendingConnectorCredentialGeneration ?? currentState.connectorCredentialGeneration
        )
        let (nextGeneration, overflow) = baseGeneration.addingReportingOverflow(1)
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
            try keychain.replaceConnectorToken(expectedCurrent: previousToken, with: newToken)
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
                try await hooks.restartLocalMCP(using: newToken)
                phase = .localActivation
                try await hooks.validateLocalActivation(using: newToken)
                phase = .oldLocalValidation
                try await hooks.validateOldLocalRouteRejects(oldToken: previousToken)
                phase = .remoteReconciliation
                try await hooks.reconcileRemote(using: newToken)
                phase = .remoteReadiness
                probe = try await hooks.validateRemoteReadiness(using: newToken)
                phase = .oldRemoteValidation
                try await hooks.validateOldRemoteRouteRejects(oldToken: previousToken)
            }
            // The old token is no longer needed once both bounded negative
            // validations have completed, before state commit begins.

            var committedState = pendingState
            committedState.connectorCredentialGeneration = nextGeneration
            committedState.pendingConnectorCredentialGeneration = nil
            committedState.recoveryPhase = .stable
            committedState.lastVerifiedPublicOrigin = probe.origin
            committedState.lastSuccessfulRemoteProbeAt = probe.verifiedAt
            committedState.lastRemoteResult = .ready
            phase = .stateCommit
            do {
                try stateStore.save(committedState)
            } catch {
                persistDegradedState(from: pendingState, generation: nextGeneration)
                throw ConnectorCredentialRotationError.statePersistenceFailed(.stateCommit)
            }

            return ConnectorCredentialRotationReceipt(
                generation: nextGeneration,
                probe: probe,
                clientHandoff: committedState.clientHandoffClassification
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
        degraded.lastVerifiedPublicOrigin = nil
        degraded.lastSuccessfulRemoteProbeAt = nil
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

protocol NgrokCredentialCandidateValidationHooks: Sendable {
    func validatePrerequisites() async throws
    func launchCandidateSession(using candidateAuthtoken: String) async throws
    func reconcileCandidateEndpoint() async throws
    func validateAuthenticatedRemoteReadiness() async throws -> RemoteConnectorProbe
    func restorePriorProviderSession() async throws
}

enum NgrokCredentialReplacementError: Error, Equatable, LocalizedError, Sendable {
    case invalidCandidate
    case prerequisitesFailed
    case candidateValidationFailed(NgrokCredentialReplacementPhase)
    case commitFailed
    case commitAmbiguous
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
        case .commitAmbiguous:
            return "ngrok credential commit could not be classified safely; reconciliation is required."
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

protocol NgrokCredentialReplacementFinishing: Sendable {
    func finishCandidateReplacement(restorePreviousSession: Bool) async throws
}

struct NgrokCredentialReplacementTransaction {
    private let keychain: KeychainStore
    private let hooks: any NgrokCredentialCandidateValidationHooks
    private let finisher: (any NgrokCredentialReplacementFinishing)?
    private let failurePolicy: NgrokCredentialFailurePolicy
    private let stateStore: (any RemoteConnectorStatePersisting)?
    private let coordinator: RemoteCredentialOperationCoordinator

    init(
        keychain: KeychainStore,
        hooks: any NgrokCredentialCandidateValidationHooks,
        failurePolicy: NgrokCredentialFailurePolicy,
        stateStore: (any RemoteConnectorStatePersisting)? = nil,
        finisher: (any NgrokCredentialReplacementFinishing)? = nil,
        coordinator: RemoteCredentialOperationCoordinator = .shared
    ) {
        self.keychain = keychain
        self.hooks = hooks
        self.finisher = finisher
        self.failurePolicy = failurePolicy
        self.stateStore = stateStore
        self.coordinator = coordinator
    }

    func execute(candidate: String) async throws -> NgrokCredentialReplacementReceipt {
        try await coordinator.acquire()
        do {
            let receipt = try await executeUnlocked(candidate: candidate)
            if let finisher {
                do {
                    try await finisher.finishCandidateReplacement(restorePreviousSession: true)
                } catch {
                    // The candidate is already canonical. Never restore the
                    // previous provider credential after post-commit cleanup
                    // fails.
                    persistNgrokDegradedState()
                    try? await finisher.finishCandidateReplacement(restorePreviousSession: false)
                    throw NgrokCredentialReplacementError.commitFailed
                }
            }
            await coordinator.release()
            return receipt
        } catch {
            await coordinator.release()
            throw error
        }
    }

    private func executeUnlocked(candidate: String) async throws -> NgrokCredentialReplacementReceipt {
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
        var candidateCommitted = false
        do {
            try await hooks.validatePrerequisites()
            phase = .launch
            try await hooks.launchCandidateSession(using: candidateForValidation)
            phase = .endpoint
            try await hooks.reconcileCandidateEndpoint()
            phase = .readiness
            let probe = try await hooks.validateAuthenticatedRemoteReadiness()
            phase = .commit
            do {
                try keychain.replaceNgrokAuthtoken(expectedCurrent: currentValue, with: candidateForValidation)
            } catch let error as KeychainStoreError
                where error == .readBackMismatch || error == .commitAmbiguous {
                throw NgrokCredentialReplacementError.commitAmbiguous
            }
            candidateCommitted = true
            currentValue = nil
            try persistNgrokReadyState(probe)
            return NgrokCredentialReplacementReceipt(probe: probe)
        } catch let error as NgrokCredentialReplacementError {
            throw await handleFailure(currentValue: &currentValue, originalError: error)
        } catch {
            let safeError: NgrokCredentialReplacementError
            switch failurePolicy {
            case .preserveExistingCredential:
                if phase == .commit, candidateCommitted {
                    persistNgrokDegradedState()
                    try? await finisher?.finishCandidateReplacement(restorePreviousSession: false)
                    safeError = .commitFailed
                } else if phase == .commit {
                    try? await hooks.restorePriorProviderSession()
                    safeError = .commitFailed
                } else {
                    try? await hooks.restorePriorProviderSession()
                    safeError = .candidateValidationFailed(phase)
                }
            case .failClosedIfCompromised:
                do {
                    try keychain.deleteNgrokAuthtoken(expectedCurrent: currentValue)
                    try? await finisher?.finishCandidateReplacement(restorePreviousSession: false)
                    safeError = .failedClosed
                } catch {
                    try? await finisher?.finishCandidateReplacement(restorePreviousSession: false)
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
    ) async -> NgrokCredentialReplacementError {
        if originalError == .commitAmbiguous {
            persistNgrokDegradedState()
            try? await finisher?.finishCandidateReplacement(restorePreviousSession: false)
            currentValue = nil
            return originalError
        }
        switch failurePolicy {
        case .preserveExistingCredential:
            try? await hooks.restorePriorProviderSession()
            currentValue = nil
            return originalError
        case .failClosedIfCompromised:
            do {
                try keychain.deleteNgrokAuthtoken(expectedCurrent: currentValue)
                try? await finisher?.finishCandidateReplacement(restorePreviousSession: false)
                currentValue = nil
                return .failedClosed
            } catch {
                try? await finisher?.finishCandidateReplacement(restorePreviousSession: false)
                currentValue = nil
                return .failClosedUnavailable
            }
        }
    }

    private func persistNgrokReadyState(_ probe: RemoteConnectorProbe) throws {
        guard let stateStore else { return }
        var state = try stateStore.loadOrCreate(provider: .ngrok)
        state.lastVerifiedPublicOrigin = probe.origin
        state.lastSuccessfulRemoteProbeAt = probe.verifiedAt
        state.lastRemoteResult = .ready
        if state.pendingConnectorCredentialGeneration == nil {
            state.recoveryPhase = .stable
        } else {
            state.recoveryPhase = .cutoverPendingValidation
        }
        try stateStore.save(state)
    }

    private func persistNgrokDegradedState() {
        guard let stateStore,
              var state = try? stateStore.loadOrCreate(provider: .ngrok) else { return }
        state.lastVerifiedPublicOrigin = nil
        state.lastSuccessfulRemoteProbeAt = nil
        state.lastRemoteResult = .degraded
        state.recoveryPhase = state.pendingConnectorCredentialGeneration == nil
            ? .degraded
            : .cutoverPendingValidation
        _ = try? stateStore.save(state)
    }
}
