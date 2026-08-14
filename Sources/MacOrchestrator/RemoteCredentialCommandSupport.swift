import Foundation

enum TerminalCredentialOperationError: Error, LocalizedError, Sendable {
    case remoteNotConfigured
    case credentialUnavailable
    case supervisorUnavailable
    case localReadinessTimeout
    case remoteReadinessTimeout
    case oldCredentialAccepted
    case candidateUnavailable
    case candidateEndpointTimeout
    case candidateProcessFailed
    case operationCleanupFailed

    var errorDescription: String? {
        switch self {
        case .remoteNotConfigured:
            return "Remote access must be enabled before changing its credentials."
        case .credentialUnavailable:
            return "The current credential is unavailable."
        case .supervisorUnavailable:
            return "The managed supervisor is not running; no credential transaction was started."
        case .localReadinessTimeout:
            return "Local MCP did not become authenticated after the credential change."
        case .remoteReadinessTimeout:
            return "Remote MCP did not become authenticated after the credential change."
        case .oldCredentialAccepted:
            return "The previous connector credential was still accepted; recovery remains degraded."
        case .candidateUnavailable:
            return "The candidate provider session could not be started safely."
        case .candidateEndpointTimeout:
            return "The candidate provider session did not expose the managed endpoint."
        case .candidateProcessFailed:
            return "The candidate provider session exited before validation completed."
        case .operationCleanupFailed:
            return "Credential operation cleanup could not be completed safely."
        }
    }
}

final class TerminalConnectorCredentialRotationHooks: @unchecked Sendable, ConnectorCredentialRotationHooks {
    private let configuration: AppConfiguration
    private let keychain: KeychainStore
    private let stateStore: any RemoteConnectorStatePersisting
    private let expectedTools: Set<String>
    private var verifiedOrigin: RemotePublicOrigin?

    init(
        configuration: AppConfiguration,
        keychain: KeychainStore = KeychainStore(),
        stateStore: any RemoteConnectorStatePersisting = RemoteConnectorStateStore(),
        expectationsProvider: CurrentCoreMCPExpectationProvider = CurrentCoreMCPExpectationProvider()
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.stateStore = stateStore
        self.expectedTools = expectationsProvider.expectations(for: configuration).expectedTools
    }

    func validatePrerequisites() async throws {
        guard configuration.process.serverDesired,
              configuration.process.tunnelDesired,
              configuration.desiredCapabilities["remote.connector"] == true else {
            throw TerminalCredentialOperationError.remoteNotConfigured
        }
        guard let current = try keychain.value(for: .connectorToken), !current.isEmpty else {
            throw TerminalCredentialOperationError.credentialUnavailable
        }
        guard try stateStore.load() != nil else {
            throw TerminalCredentialOperationError.credentialUnavailable
        }
    }

    func restartLocalMCP(using newToken: String) async throws {
        guard !newToken.isEmpty else { throw TerminalCredentialOperationError.credentialUnavailable }
        guard try TerminalCommand.restartRunningSupervisorIfLoaded() else {
            throw TerminalCredentialOperationError.supervisorUnavailable
        }
        try await waitForLocalReadiness(using: newToken)
    }

    func validateLocalActivation(using newToken: String) async throws {
        try await runLocalProbe(using: newToken)
    }

    func validateOldLocalRouteRejects(oldToken: String) async throws {
        do {
            try await runLocalProbe(using: oldToken)
            throw TerminalCredentialOperationError.oldCredentialAccepted
        } catch let error as TerminalCredentialOperationError {
            throw error
        } catch {
            // Any bounded local rejection is sufficient negative evidence;
            // the underlying response is intentionally not retained.
        }
    }

    func reconcileRemote(using newToken: String) async throws {
        guard !newToken.isEmpty else { throw TerminalCredentialOperationError.credentialUnavailable }
        let service = RemoteConnectorReadinessService(configuration: configuration, keychain: keychain)
        do {
            _ = try await waitForRemoteReadiness(service: service)
        } catch {
            throw TerminalCredentialOperationError.remoteReadinessTimeout
        }
    }

    func validateRemoteReadiness(using newToken: String) async throws -> RemoteConnectorProbe {
        guard !newToken.isEmpty else { throw TerminalCredentialOperationError.credentialUnavailable }
        let service = RemoteConnectorReadinessService(configuration: configuration, keychain: keychain)
        let origin: RemotePublicOrigin
        do {
            origin = try await service.probe()
        } catch {
            throw TerminalCredentialOperationError.remoteReadinessTimeout
        }
        verifiedOrigin = origin
        return RemoteConnectorProbe(origin: origin, verifiedAt: Date())
    }

    func validateOldRemoteRouteRejects(oldToken: String) async throws {
        let origin = verifiedOrigin
        guard let origin,
              let oldURL = ConnectorURLBuilder.make(publicOrigin: origin, capabilityToken: oldToken) else {
            throw TerminalCredentialOperationError.remoteReadinessTimeout
        }
        let outcome = await RemoteActivationProbe(
            url: oldURL,
            expectedTools: expectedTools
        ).runOutcome()
        if outcome.details != nil {
            throw TerminalCredentialOperationError.oldCredentialAccepted
        }
    }

    private func runLocalProbe(using token: String) async throws {
        try await LocalActivationProbe().run(
            port: configuration.localMCPPort,
            capabilityToken: token,
            requiresInteractiveUI: configuration.desiredCapabilities["mac.ui"] == true
        )
    }

    private func waitForLocalReadiness(using token: String) async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            do {
                try await runLocalProbe(using: token)
                return
            } catch {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw TerminalCredentialOperationError.localReadinessTimeout
    }

    private func waitForRemoteReadiness(
        service: RemoteConnectorReadinessService
    ) async throws -> RemotePublicOrigin {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            do {
                return try await service.probe()
            } catch {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw TerminalCredentialOperationError.remoteReadinessTimeout
    }
}

final class TerminalNgrokCredentialReplacementHooks: @unchecked Sendable,
    NgrokCredentialCandidateValidationHooks,
    NgrokCredentialReplacementFinishing {
    private let configuration: AppConfiguration
    private let keychain: KeychainStore
    private let adapter: any RemoteConnectorAdapter
    private let expectedTools: Set<String>
    private let binaryURL: URL
    private let configurationURL: URL
    private let target: String
    private var candidateToken: String?
    private var candidateProcess: Process?
    private var candidateOrigin: RemotePublicOrigin?
    private var previousRemoteDesired = false

    init(
        configuration: AppConfiguration,
        keychain: KeychainStore = KeychainStore(),
        adapter: any RemoteConnectorAdapter = NgrokRemoteConnectorAdapter(),
        expectationsProvider: CurrentCoreMCPExpectationProvider = CurrentCoreMCPExpectationProvider(),
        supportDirectory: URL = ConfigurationStore.defaultDirectoryURL()
    ) {
        self.configuration = configuration
        self.keychain = keychain
        self.adapter = adapter
        self.expectedTools = expectationsProvider.expectations(for: configuration).expectedTools
        let ngrokDirectory = supportDirectory
            .appendingPathComponent("remote", isDirectory: true)
            .appendingPathComponent("ngrok", isDirectory: true)
        self.binaryURL = ngrokDirectory.appendingPathComponent("ngrok", isDirectory: false)
        self.configurationURL = ngrokDirectory.appendingPathComponent("ngrok.yml", isDirectory: false)
        self.target = "http://127.0.0.1:\(configuration.localMCPPort)"
    }

    func validatePrerequisites() async throws {
        guard configuration.process.serverDesired else {
            throw TerminalCredentialOperationError.remoteNotConfigured
        }
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path),
              FileManager.default.fileExists(atPath: configurationURL.path) else {
            throw TerminalCredentialOperationError.candidateUnavailable
        }
        previousRemoteDesired = configuration.process.tunnelDesired
    }

    func launchCandidateSession(using candidateAuthtoken: String) async throws {
        guard !candidateAuthtoken.isEmpty else {
            throw TerminalCredentialOperationError.candidateUnavailable
        }
        try await quiescePreviousSession()

        let input = RemoteConnectorLaunchInput(
            executableURL: binaryURL,
            configurationURL: configurationURL,
            tunnelTarget: target,
            ownerID: configuration.ownerID,
            environment: inheritedEnvironment(),
            authenticationToken: candidateAuthtoken
        )
        let specification: RemoteConnectorLaunchSpecification
        do {
            specification = try adapter.makeLaunchSpecification(for: input)
        } catch {
            throw TerminalCredentialOperationError.candidateUnavailable
        }

        let process = Process()
        process.executableURL = specification.executableURL
        process.arguments = specification.arguments
        process.environment = specification.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw TerminalCredentialOperationError.candidateUnavailable
        }
        candidateToken = candidateAuthtoken
        candidateProcess = process
    }

    func reconcileCandidateEndpoint() async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let process = candidateProcess
            guard process?.isRunning == true else {
                throw TerminalCredentialOperationError.candidateProcessFailed
            }
            let inspection = await adapter.inspectAgentAPI()
            let reconciliation = adapter.reconcileEndpoint(from: inspection, matching: target)
            if case let .current(publicURL) = reconciliation,
               let origin = try? RemotePublicOrigin(publicURL.absoluteString) {
                candidateOrigin = origin
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw TerminalCredentialOperationError.candidateEndpointTimeout
    }

    func validateAuthenticatedRemoteReadiness() async throws -> RemoteConnectorProbe {
        let token = candidateToken
        let origin = candidateOrigin
        guard let token, let origin,
              let url = ConnectorURLBuilder.make(publicOrigin: origin, capabilityToken: token) else {
            throw TerminalCredentialOperationError.remoteReadinessTimeout
        }
        let outcome = await RemoteActivationProbe(url: url, expectedTools: expectedTools).runOutcome()
        guard let details = outcome.details,
              details.sessionEstablished,
              details.safeCallSucceeded else {
            throw TerminalCredentialOperationError.remoteReadinessTimeout
        }
        return RemoteConnectorProbe(origin: origin, verifiedAt: Date())
    }

    func restorePriorProviderSession() async throws {
        try await finishCandidateReplacement(restorePreviousSession: true)
    }

    func finishCandidateReplacement(restorePreviousSession: Bool) async throws {
        stopCandidateProcess()
        if !restorePreviousSession {
            clearCandidateMemory()
            return
        }

        let shouldRestore: Bool
        shouldRestore = previousRemoteDesired
        guard shouldRestore else {
            clearCandidateMemory()
            return
        }

        do {
            _ = try ConfigurationStore().update { configuration in
                configuration.process.tunnelDesired = true
                configuration.desiredCapabilities["remote.connector"] = true
            }
            guard try TerminalCommand.restartRunningSupervisorIfLoaded() else {
                throw TerminalCredentialOperationError.supervisorUnavailable
            }
            let service = RemoteConnectorReadinessService(configuration: configuration, keychain: keychain)
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                do {
                    _ = try await service.probe()
                    clearCandidateMemory()
                    return
                } catch {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            throw TerminalCredentialOperationError.remoteReadinessTimeout
        } catch {
            clearCandidateMemory()
            throw error
        }
    }

    private func quiescePreviousSession() async throws {
        let shouldStop: Bool
        shouldStop = previousRemoteDesired
        guard shouldStop else { return }

        _ = try ConfigurationStore().update { configuration in
            configuration.process.tunnelDesired = false
            configuration.desiredCapabilities["remote.connector"] = false
        }
        guard try TerminalCommand.restartRunningSupervisorIfLoaded() else {
            throw TerminalCredentialOperationError.supervisorUnavailable
        }
        let adapter = NgrokRemoteConnectorAdapter()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let inspection = await adapter.inspectAgentAPI()
            let reconciliation = adapter.reconcileEndpoint(from: inspection, matching: target)
            switch reconciliation {
            case .missing, .foreign:
                return
            default:
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw TerminalCredentialOperationError.candidateUnavailable
    }

    private func stopCandidateProcess() {
        let process = candidateProcess
        candidateProcess = nil
        guard let process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private func clearCandidateMemory() {
        candidateToken = nil
        candidateOrigin = nil
    }

    private func inheritedEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let names = ["PATH", "HOME", "USER", "TMPDIR", "LANG", "SSL_CERT_FILE", "SSL_CERT_DIR"]
        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            source[name].map { (name, $0) }
        })
    }
}
