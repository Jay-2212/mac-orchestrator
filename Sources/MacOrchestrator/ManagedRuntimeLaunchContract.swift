import Foundation

enum ManagedRuntimeLaunchContractError: Error, LocalizedError, Sendable {
    case invalidSnapshotEncoding
    case missingRequiredSecret(String)
    case missingRequiredRuntimeValue(String)

    var errorDescription: String? {
        switch self {
        case .invalidSnapshotEncoding:
            return "The managed capability snapshot could not be encoded."
        case let .missingRequiredSecret(name):
            return "A required managed runtime secret is unavailable: \(name)."
        case let .missingRequiredRuntimeValue(name):
            return "A required managed runtime value is unavailable: \(name)."
        }
    }
}

struct ManagedRuntimeLaunchContract: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private static let inheritedNonsecretNames = [
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TERM",
        "COLORTERM",
        "__CF_USER_TEXT_ENCODING",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "REQUESTS_CA_BUNDLE",
    ]

    let port: Int
    let configuration: AppConfiguration
    let capabilitySnapshot: CapabilitySnapshot
    let environment: [String: String]
    let redactedSecrets: [String]
    let ngrokAuthtoken: String?
    let meridianIndexerToken: String?

    init(
        port: Int,
        configuration: AppConfiguration,
        capabilitySnapshot: CapabilitySnapshot,
        environment: [String: String],
        redactedSecrets: [String],
        ngrokAuthtoken: String?,
        meridianIndexerToken: String? = nil
    ) {
        self.port = port
        self.configuration = configuration
        self.capabilitySnapshot = capabilitySnapshot
        self.environment = environment
        self.redactedSecrets = redactedSecrets
        self.ngrokAuthtoken = ngrokAuthtoken
        self.meridianIndexerToken = meridianIndexerToken
    }

    var description: String { "ManagedRuntimeLaunchContract" }
    var debugDescription: String { description }

    var healthURL: URL {
        URL(string: "http://127.0.0.1:\(port)/__mac_orchestrator_health")!
    }

    var tunnelTarget: String {
        "http://127.0.0.1:\(port)"
    }

    var configurationGeneration: UInt64 {
        UInt64(max(0, configuration.generation))
    }

    static func make(
        configuration: AppConfiguration,
        capabilitySnapshot: CapabilitySnapshot,
        keychain: KeychainStore,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ManagedRuntimeLaunchContract {
        let snapshotData = try CapabilitySnapshotCodec.encode(capabilitySnapshot)
        guard let encodedSnapshot = String(data: snapshotData, encoding: .utf8) else {
            throw ManagedRuntimeLaunchContractError.invalidSnapshotEncoding
        }
        let connectorToken = try keychain.connectorTokenValue()
        var environment: [String: String] = [:]
        for name in inheritedNonsecretNames {
            if let value = inheritedEnvironment[name] {
                environment[name] = value
            }
        }
        var redactedSecrets = [connectorToken]
        let ngrokAuthtoken = try keychain.value(for: .ngrokAuthtoken)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let ngrokAuthtoken {
            redactedSecrets.append(ngrokAuthtoken)
        }

        let meridianIndexerToken: String?
        if configuration.integration.meridianIndexer.enabled {
            meridianIndexerToken = try? keychain.meridianIngestToken()
            if let meridianIndexerToken, !meridianIndexerToken.isEmpty {
                redactedSecrets.append(meridianIndexerToken)
            }
        } else {
            meridianIndexerToken = nil
        }

        if capabilitySnapshot.capabilities["telegram.send"]?.ready == true {
            guard let botToken = try keychain.value(for: .telegramSendBotToken), !botToken.isEmpty else {
                throw ManagedRuntimeLaunchContractError.missingRequiredSecret(
                    "MAC_ORCHESTRATOR_TELEGRAM_BOT_TOKEN"
                )
            }
            guard let chatID = try keychain.value(for: .telegramSendChatID), !chatID.isEmpty else {
                throw ManagedRuntimeLaunchContractError.missingRequiredSecret(
                    "MAC_ORCHESTRATOR_TELEGRAM_CHAT_ID"
                )
            }
            environment["MAC_ORCHESTRATOR_TELEGRAM_BOT_TOKEN"] = botToken
            environment["MAC_ORCHESTRATOR_TELEGRAM_CHAT_ID"] = chatID
            redactedSecrets.append(contentsOf: [botToken, chatID])
        }

        if capabilitySnapshot.capabilities["meridian.search"]?.ready == true {
            guard let ingestToken = try keychain.meridianIngestToken(), !ingestToken.isEmpty else {
                throw ManagedRuntimeLaunchContractError.missingRequiredSecret(
                    "MAC_ORCHESTRATOR_MERIDIAN_INGEST_TOKEN"
                )
            }
            guard let workerURL = configuration.integration.meridianDeploymentURL,
                  !workerURL.isEmpty else {
                throw ManagedRuntimeLaunchContractError.missingRequiredRuntimeValue(
                    "MAC_ORCHESTRATOR_WORKER_URL"
                )
            }
            environment["MAC_ORCHESTRATOR_MERIDIAN_INGEST_TOKEN"] = ingestToken
            environment["MAC_ORCHESTRATOR_WORKER_URL"] = workerURL
            redactedSecrets.append(ingestToken)
        }

        environment["MAC_ORCHESTRATOR_MANAGED"] = "1"
        environment["MAC_ORCHESTRATOR_CAPABILITY_SNAPSHOT"] = encodedSnapshot
        environment["MAC_ORCHESTRATOR_PORT"] = String(configuration.localMCPPort)
        environment["MAC_ORCHESTRATOR_CONNECTOR_TOKEN"] = connectorToken
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"

        return ManagedRuntimeLaunchContract(
            port: configuration.localMCPPort,
            configuration: configuration,
            capabilitySnapshot: capabilitySnapshot,
            environment: environment,
            redactedSecrets: redactedSecrets,
            ngrokAuthtoken: ngrokAuthtoken,
            meridianIndexerToken: meridianIndexerToken
        )
    }

    func matchesTunnelAddress(_ address: String) -> Bool {
        address == tunnelTarget || address == "http://localhost:\(port)"
    }

    func ngrokEnvironment() -> [String: String] {
        var environment: [String: String] = [:]
        for name in Self.inheritedNonsecretNames {
            if let value = self.environment[name] {
                environment[name] = value
            }
        }
        if let ngrokAuthtoken {
            environment["NGROK_AUTHTOKEN"] = ngrokAuthtoken
        }
        return environment
    }

    func remoteConnectorLaunchInput(
        executableURL: URL,
        configurationURL: URL
    ) -> RemoteConnectorLaunchInput {
        RemoteConnectorLaunchInput(
            executableURL: executableURL,
            configurationURL: configurationURL,
            tunnelTarget: tunnelTarget,
            ownerID: configuration.ownerID,
            environment: ngrokEnvironment(),
            authenticationToken: ngrokAuthtoken
        )
    }
}

struct ManagedRuntimeTransition: Equatable, Sendable {
    let requiresRestart: Bool
    let requiresClientRefresh: Bool

    static func between(
        current: ManagedRuntimeLaunchContract,
        replacement: ManagedRuntimeLaunchContract
    ) -> ManagedRuntimeTransition {
        let snapshotChanged =
            current.capabilitySnapshot.controlProfile != replacement.capabilitySnapshot.controlProfile ||
            current.capabilitySnapshot.capabilities != replacement.capabilitySnapshot.capabilities ||
            current.capabilitySnapshot.policy != replacement.capabilitySnapshot.policy
        let endpointChanged = current.port != replacement.port
        let runtimeEnvironmentChanged = runtimeEnvironmentNames.contains { name in
            current.environment[name] != replacement.environment[name]
        }
        let ngrokCredentialChanged = current.ngrokAuthtoken != replacement.ngrokAuthtoken
        let requiresRestart = snapshotChanged || endpointChanged || runtimeEnvironmentChanged || ngrokCredentialChanged
        return ManagedRuntimeTransition(
            requiresRestart: requiresRestart,
            requiresClientRefresh: requiresRestart
        )
    }

    private static let runtimeEnvironmentNames = [
        "MAC_ORCHESTRATOR_CONNECTOR_TOKEN",
        "MAC_ORCHESTRATOR_TELEGRAM_BOT_TOKEN",
        "MAC_ORCHESTRATOR_TELEGRAM_CHAT_ID",
        "MAC_ORCHESTRATOR_MERIDIAN_INGEST_TOKEN",
        "MAC_ORCHESTRATOR_WORKER_URL",
    ]
}
