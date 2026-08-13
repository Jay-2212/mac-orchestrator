import Foundation

struct DoctorThresholds: Equatable, Sendable {
    let lowDiskBytes: Int64?

    init(lowDiskBytes: Int64? = nil) {
        self.lowDiskBytes = lowDiskBytes
    }
}

private struct DoctorInspection<Value> {
    let value: Value?
    let failureReason: String?

    init(value: Value? = nil, failureReason: String? = nil) {
        self.value = value
        self.failureReason = failureReason
    }
}

struct DoctorConfigurationSnapshot: Equatable, Sendable {
    let facts: ConfigurationDiagnosticFacts
    let validatedConfiguration: AppConfiguration?

    init(
        facts: ConfigurationDiagnosticFacts,
        validatedConfiguration: AppConfiguration?
    ) {
        self.facts = facts
        self.validatedConfiguration = validatedConfiguration
    }
}

protocol DoctorConfigurationContextProviding {
    func inspect() throws -> DoctorConfigurationSnapshot
}

protocol ReadOnlyConfigurationDiagnosticProviding: ConfigurationDiagnosticProviding {}

extension ReadOnlyConfigurationDiagnosticProvider: ReadOnlyConfigurationDiagnosticProviding {}

struct ReadOnlyDoctorConfigurationContextProvider: DoctorConfigurationContextProviding {
    private let diagnosticProvider: any ReadOnlyConfigurationDiagnosticProviding
    private let primaryConfigurationURL: URL
    private let decoder: JSONDecoder

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.init(
            diagnosticProvider: ReadOnlyConfigurationDiagnosticProvider(
                directoryURL: directoryURL,
                fileManager: fileManager
            ),
            primaryConfigurationURL: directoryURL.appendingPathComponent("config.json", isDirectory: false)
        )
    }

    init(
        diagnosticProvider: any ReadOnlyConfigurationDiagnosticProviding,
        primaryConfigurationURL: URL
    ) {
        self.diagnosticProvider = diagnosticProvider
        self.primaryConfigurationURL = primaryConfigurationURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func inspect() throws -> DoctorConfigurationSnapshot {
        let facts = try diagnosticProvider.inspect()
        return DoctorConfigurationSnapshot(
            facts: facts,
            validatedConfiguration: decodeValidatedConfiguration(facts: facts)
        )
    }

    private func decodeValidatedConfiguration(facts: ConfigurationDiagnosticFacts) -> AppConfiguration? {
        guard DiagnosticChecks.isUsableConfigurationContext(facts),
              let data = try? Data(contentsOf: primaryConfigurationURL),
              let configuration = try? decoder.decode(AppConfiguration.self, from: data) else {
            return nil
        }
        return try? configuration.validated()
    }
}

protocol DoctorKeychainPresenceProviding {
    func inspect(items: Set<KeychainPresenceItem>) throws -> KeychainPresenceFacts
}

struct SystemDoctorKeychainPresenceProvider: DoctorKeychainPresenceProviding {
    private let querying: KeychainPresenceQuerying

    private static let currentCoreItems: Set<KeychainPresenceItem> = [
        .connectorToken,
        .ngrokAuthtoken,
        .telegramSendBotToken,
        .telegramSendChatID,
    ]

    init(querying: KeychainPresenceQuerying = SystemKeychainPresenceQuery()) {
        self.querying = querying
    }

    func inspect(items: Set<KeychainPresenceItem>) throws -> KeychainPresenceFacts {
        var states = [KeychainPresenceItem: KeychainPresence]()
        for item in items.intersection(Self.currentCoreItems).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let keychainItem = item.keychainItem else {
                continue
            }
            let request = KeychainPresenceQuery(
                item: item,
                service: keychainItem.service,
                account: keychainItem.account,
                requestsData: false
            )
            states[item] = querying.query(request)
        }
        return KeychainPresenceFacts(states: states)
    }
}

struct SystemManagedRuntimePermissionFactsProvider: PermissionFactsProviding {
    let runtimeDirectory: URL
    let checker: any ManagedPermissionChecking

    init(
        runtimeDirectory: URL,
        checker: any ManagedPermissionChecking = SystemManagedPermissionChecker()
    ) {
        self.runtimeDirectory = runtimeDirectory
        self.checker = checker
    }

    func inspect() throws -> PermissionFacts {
        guard let probe = checker.probe(runtimeDirectory: runtimeDirectory) else {
            throw DiagnosticProviderError.unavailable
        }
        return PermissionFacts(
            accessibility: probe.accessibility,
            screenRecording: probe.screenRecording,
            automation: probe.automation,
            activeConsole: probe.activeConsole,
            sessionLocked: !probe.unlocked,
            requesterIsManagedRuntime: true
        )
    }
}

protocol DoctorAsyncLocalMCPDiagnosticProviding {
    func inspect() async throws -> LocalMCPFacts
}

struct CanonicalLocalMCPDiagnosticProvider: DoctorAsyncLocalMCPDiagnosticProviding {
    private let adapter: LocalActivationProbeAdapter

    init(adapter: LocalActivationProbeAdapter) {
        self.adapter = adapter
    }

    func inspect() async throws -> LocalMCPFacts {
        await adapter.inspect()
    }
}

struct DoctorDependencies {
    let configurationContextProvider: any DoctorConfigurationContextProviding
    let installedReleaseProvider: any InstalledReleaseFactsProviding
    let permissionProvider: any PermissionFactsProviding
    let keychainPresenceProvider: any DoctorKeychainPresenceProviding
    let portProvider: any PortFactsProviding
    let localMCPProvider: any LocalMCPDiagnosticProviding
    let asyncLocalMCPProvider: (any DoctorAsyncLocalMCPDiagnosticProviding)?
    let lifecycleProvider: any LifecycleFactsProviding
    let remoteConnectorProvider: any RemoteConnectorFactsProviding
    let diskSpaceProvider: any DiskSpaceProviding
    let logDirectoryProvider: any LogDirectoryPermissionsProviding
    let updateProvider: any UpdateAvailabilityProviding
    let thresholds: DoctorThresholds
    let clock: @Sendable () -> Date

    init(
        configurationContextProvider: any DoctorConfigurationContextProviding = UnavailableConfigurationContextProvider(),
        installedReleaseProvider: any InstalledReleaseFactsProviding = UnavailableInstalledReleaseProvider(),
        permissionProvider: (any PermissionFactsProviding)? = nil,
        keychainPresenceProvider: any DoctorKeychainPresenceProviding = SystemDoctorKeychainPresenceProvider(),
        portProvider: any PortFactsProviding = UnavailablePortProvider(),
        localMCPProvider: any LocalMCPDiagnosticProviding = UnavailableLocalMCPProvider(),
        asyncLocalMCPProvider: (any DoctorAsyncLocalMCPDiagnosticProviding)? = nil,
        lifecycleProvider: any LifecycleFactsProviding = UnavailableLifecycleProvider(),
        remoteConnectorProvider: any RemoteConnectorFactsProviding = UnavailableRemoteProvider(),
        diskSpaceProvider: any DiskSpaceProviding = UnavailableDiskProvider(),
        logDirectoryProvider: any LogDirectoryPermissionsProviding = ReadOnlyLogDirectoryPermissionsProvider(
            directoryURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Mac Orchestrator", isDirectory: true)
        ),
        updateProvider: any UpdateAvailabilityProviding = UnavailableUpdateProvider(),
        thresholds: DoctorThresholds = DoctorThresholds(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configurationContextProvider = configurationContextProvider
        self.installedReleaseProvider = installedReleaseProvider
        self.permissionProvider = permissionProvider ?? SystemManagedRuntimePermissionFactsProvider(
            runtimeDirectory: DiagnosticPathSet.defaultPaths().runtimeDirectory
        )
        self.keychainPresenceProvider = keychainPresenceProvider
        self.portProvider = portProvider
        self.localMCPProvider = localMCPProvider
        self.asyncLocalMCPProvider = asyncLocalMCPProvider
        self.lifecycleProvider = lifecycleProvider
        self.remoteConnectorProvider = remoteConnectorProvider
        self.diskSpaceProvider = diskSpaceProvider
        self.logDirectoryProvider = logDirectoryProvider
        self.updateProvider = updateProvider
        self.thresholds = thresholds
        self.clock = clock
    }
}

struct DoctorEngine {
    private let dependencies: DoctorDependencies

    init(dependencies: DoctorDependencies) {
        self.dependencies = dependencies
    }

    func run() async -> DoctorReport {
        // Configuration is the only source of desired state. Nothing that
        // depends on those decisions is inspected until this snapshot exists.
        let configurationInspection = inspectConfigurationContext()
        let snapshot = configurationInspection.value
        let configurationFacts = snapshot?.facts
        let configuration = snapshot.flatMap {
            DiagnosticChecks.isUsableConfigurationContext($0.facts) ? $0.validatedConfiguration : nil
        }
        let hasValidatedConfiguration = configuration != nil
        let serverDesired = configuration?.process.serverDesired == true
        let remoteDesired = configuration?.process.tunnelDesired == true
            || configuration?.desiredCapabilities["remote.connector"] == true
        let telegramSendDesired = configuration?.desiredCapabilities["telegram.send"] == true

        let installedInspection = inspectInstalledRelease()
        let installedFacts = installedInspection.value
        let permissionInspection = DiagnosticChecks.consumesProtectedBehavior(configuration)
            ? inspectPermissions()
            : DoctorInspection<PermissionFacts>()
        let permissionFacts = permissionInspection.value
        let portInspection = serverDesired ? inspectPort() : DoctorInspection<PortFacts>()
        let portFacts = portInspection.value
        let localMCPInspection = serverDesired ? await inspectLocalMCP() : DoctorInspection<LocalMCPFacts>()
        let localMCPFacts = localMCPInspection.value
        let lifecycleInspection = (serverDesired || remoteDesired)
            ? inspectLifecycle()
            : DoctorInspection<LifecycleFacts>()
        let lifecycleFacts = lifecycleInspection.value
        let keychainInspection = inspectKeychain(
            localDesired: serverDesired,
            remoteDesired: remoteDesired,
            telegramSendDesired: telegramSendDesired,
            hasValidatedConfiguration: hasValidatedConfiguration
        )
        let keychainFacts = keychainInspection.value
        let remoteInspection = remoteDesired ? inspectRemote() : DoctorInspection<RemoteConnectorFacts>()
        let remoteFacts = remoteInspection.value
        let diskInspection = inspectDisk()
        let diskFacts = diskInspection.value
        let logDirectoryInspection = inspectLogDirectory()
        let logDirectoryFacts = logDirectoryInspection.value
        let updateFacts = inspectUpdate()

        var results = [
            DiagnosticChecks.configurationRead(configurationFacts),
            DiagnosticChecks.configurationPermissions(configurationFacts),
            DiagnosticChecks.configurationSchema(configurationFacts),
            DiagnosticChecks.configurationBackup(configurationFacts),
            DiagnosticChecks.configurationRecovery(configurationFacts),
            DiagnosticChecks.configurationGeneration(configurationFacts),
            DiagnosticChecks.configurationMigration(configuration),
            DiagnosticChecks.installationHelper(installedFacts),
            DiagnosticChecks.installationRuntime(installedFacts),
            DiagnosticChecks.installationHelperArchitecture(installedFacts),
            DiagnosticChecks.installationRuntimeArchitecture(installedFacts),
            DiagnosticChecks.installationHelperBundleIdentifier(installedFacts),
            DiagnosticChecks.installationIntegrity(installedFacts),
            DiagnosticChecks.installationVersionMatch(installedFacts),
            DiagnosticChecks.trustCodeSign(installedFacts),
            DiagnosticChecks.permissionsRequester(permissionFacts, configuration: configuration),
            DiagnosticChecks.keychainConnector(serverDesired ? keychainFacts : nil),
            DiagnosticChecks.keychainTelegramSend(keychainFacts, desired: telegramSendDesired),
            DiagnosticChecks.portSelected(portFacts, configuredPort: serverDesired ? configuration?.localMCPPort : nil),
            DiagnosticChecks.mcpLiveness(localMCPFacts, desired: serverDesired),
            DiagnosticChecks.mcpReadiness(localMCPFacts, desired: serverDesired),
            DiagnosticChecks.mcpInventory(localMCPFacts, desired: serverDesired),
            DiagnosticChecks.lifecycleLaunchAgent(lifecycleFacts, desired: hasValidatedConfiguration && (serverDesired || remoteDesired)),
            DiagnosticChecks.lifecycleProcessOwnership(lifecycleFacts, desired: hasValidatedConfiguration && (serverDesired || remoteDesired)),
            DiagnosticChecks.remoteNgrok(
                remoteFacts,
                auth: remoteDesired ? keychainFacts?.presence(for: .ngrokAuthtoken) : nil,
                desired: remoteDesired
            ),
            DiagnosticChecks.remoteNgrokArchitecture(remoteFacts, desired: remoteDesired),
            DiagnosticChecks.remoteNgrokSigning(remoteFacts, desired: remoteDesired),
            DiagnosticChecks.remoteEndpoint(remoteFacts, desired: remoteDesired),
            DiagnosticChecks.updateAvailability(updateFacts),
            DiagnosticChecks.diskFreeSpace(diskFacts, thresholdBytes: dependencies.thresholds.lowDiskBytes),
            DiagnosticChecks.criticalPaths(diskFacts),
            DiagnosticChecks.logDirectoryPermissions(logDirectoryFacts),
            DiagnosticChecks.futureCapability("capability.meridian", title: "Meridian capability"),
            DiagnosticChecks.futureCapability("capability.cloudflare", title: "Cloudflare capability"),
            DiagnosticChecks.futureCapability("capability.telegram-assistant", title: "Telegram Assistant capability"),
        ]
        applyFailure(
            configurationInspection.failureReason,
            to: ["configuration.read"],
            in: &results
        )
        applyFailure(
            installedInspection.failureReason,
            to: ["installation.helper"],
            in: &results
        )
        applyFailure(
            permissionInspection.failureReason,
            to: ["permissions.requester"],
            in: &results
        )
        let keychainFailureTarget: [String]
        if serverDesired {
            keychainFailureTarget = ["keychain.connector"]
        } else if remoteDesired {
            keychainFailureTarget = ["remote.ngrok"]
        } else if telegramSendDesired {
            keychainFailureTarget = ["keychain.telegram-send"]
        } else {
            keychainFailureTarget = []
        }
        applyFailure(keychainInspection.failureReason, to: keychainFailureTarget, in: &results)
        applyFailure(portInspection.failureReason, to: ["port.selected"], in: &results)
        applyFailure(localMCPInspection.failureReason, to: ["mcp.liveness"], in: &results)
        applyFailure(
            lifecycleInspection.failureReason,
            to: ["lifecycle.launch-agent", "lifecycle.process-ownership"],
            in: &results
        )
        applyFailure(remoteInspection.failureReason, to: ["remote.ngrok"], in: &results)
        applyFailure(diskInspection.failureReason, to: ["disk.free-space"], in: &results)
        applyFailure(
            logDirectoryInspection.failureReason,
            to: ["filesystem.log-directory-permissions"],
            in: &results
        )
        results.sort { $0.id < $1.id }
        return DoctorReport(generatedAt: dependencies.clock(), results: results)
    }

    private func inspectConfigurationContext() -> DoctorInspection<DoctorConfigurationSnapshot> {
        do {
            return DoctorInspection(value: try dependencies.configurationContextProvider.inspect())
        } catch {
            return DoctorInspection(failureReason: providerFailureReason(error, subject: "configuration"))
        }
    }

    private func inspectInstalledRelease() -> DoctorInspection<InstalledReleaseFacts> {
        do {
            return DoctorInspection(value: try dependencies.installedReleaseProvider.inspect())
        } catch {
            return DoctorInspection(failureReason: providerFailureReason(error, subject: "installed helper and runtime"))
        }
    }

    private func inspectPermissions() -> DoctorInspection<PermissionFacts> {
        do {
            return DoctorInspection(value: try dependencies.permissionProvider.inspect())
        } catch {
            return DoctorInspection(failureReason: providerFailureReason(error, subject: "managed runtime permissions"))
        }
    }

    private func inspectKeychain(
        localDesired: Bool,
        remoteDesired: Bool,
        telegramSendDesired: Bool,
        hasValidatedConfiguration: Bool
    ) -> DoctorInspection<KeychainPresenceFacts> {
        guard hasValidatedConfiguration else { return DoctorInspection() }
        var items = Set<KeychainPresenceItem>()
        if localDesired { items.insert(.connectorToken) }
        if remoteDesired { items.insert(.ngrokAuthtoken) }
        if telegramSendDesired {
            items.insert(.telegramSendBotToken)
            items.insert(.telegramSendChatID)
        }
        guard !items.isEmpty else { return DoctorInspection() }
        do {
            return DoctorInspection(value: try dependencies.keychainPresenceProvider.inspect(items: items))
        } catch {
            return DoctorInspection(failureReason: providerFailureReason(error, subject: "Keychain presence"))
        }
    }

    private func inspectPort() -> DoctorInspection<PortFacts> {
        do {
            return DoctorInspection(value: try dependencies.portProvider.inspect())
        } catch {
            return DoctorInspection(failureReason: providerFailureReason(error, subject: "selected local port"))
        }
    }

    private func inspectLocalMCP() async -> DoctorInspection<LocalMCPFacts> {
        if let provider = dependencies.asyncLocalMCPProvider {
            do {
                return DoctorInspection(value: try await provider.inspect())
            } catch {
                return DoctorInspection(failureReason: providerFailureReason(error, subject: "local MCP"))
            }
        }
        do {
            return DoctorInspection(value: try dependencies.localMCPProvider.inspect())
        } catch {
            return DoctorInspection(failureReason: providerFailureReason(error, subject: "local MCP"))
        }
    }

    private func inspectLifecycle() -> DoctorInspection<LifecycleFacts> {
        do {
            return DoctorInspection(value: try dependencies.lifecycleProvider.inspect())
        } catch {
            return DoctorInspection(failureReason: providerFailureReason(error, subject: "managed lifecycle"))
        }
    }

    private func inspectRemote() -> DoctorInspection<RemoteConnectorFacts> {
        do {
            return DoctorInspection(value: try dependencies.remoteConnectorProvider.inspect())
        } catch {
            return DoctorInspection(failureReason: providerFailureReason(error, subject: "remote connector"))
        }
    }

    private func inspectDisk() -> DoctorInspection<DiskSpaceFacts> {
        do {
            return DoctorInspection(value: try dependencies.diskSpaceProvider.inspect())
        } catch {
            return DoctorInspection(failureReason: providerFailureReason(error, subject: "free disk space"))
        }
    }

    private func inspectLogDirectory() -> DoctorInspection<LogDirectoryFacts> {
        do {
            return DoctorInspection(value: try dependencies.logDirectoryProvider.inspect())
        } catch {
            return DoctorInspection(failureReason: providerFailureReason(error, subject: "log-directory permissions"))
        }
    }

    private func applyFailure(
        _ reason: String?,
        to ids: [String],
        in results: inout [DiagnosticResult]
    ) {
        guard let reason else { return }
        for index in results.indices where ids.contains(results[index].id) {
            let result = results[index]
            results[index] = DiagnosticResult(
                id: result.id,
                title: result.title,
                status: result.status,
                reason: reason,
                repair: result.repair
            )
        }
    }

    private func providerFailureReason(_ error: Error, subject: String) -> String {
        let detail: String
        if let error = error as? DiagnosticProviderError {
            switch error {
            case .unavailable: detail = "unavailable"
            case .inaccessible: detail = "inaccessible"
            case .unreadable: detail = "unreadable"
            case .malformed: detail = "malformed"
            case .unsupportedSchema: detail = "unsupported schema"
            case .invalid: detail = "invalid"
            case .permissionDenied: detail = "permission denied"
            }
        } else {
            detail = "inspection failed"
        }
        return "Unable to inspect \(subject): \(detail)."
    }

    private func inspectUpdate() -> UpdateAvailabilityFacts? {
        do {
            return try dependencies.updateProvider.inspect()
        } catch DiagnosticProviderError.unavailable {
            return UpdateAvailabilityFacts(status: .unavailable)
        } catch {
            return UpdateAvailabilityFacts(inspectionFailed: true)
        }
    }
}

extension DoctorReport {
    func result(withID id: String) -> DiagnosticResult? {
        results.first { $0.id == id }
    }
}

private struct UnavailableConfigurationContextProvider: DoctorConfigurationContextProviding {
    func inspect() throws -> DoctorConfigurationSnapshot { throw DiagnosticProviderError.unavailable }
}

private struct UnavailableInstalledReleaseProvider: InstalledReleaseFactsProviding {
    func inspect() throws -> InstalledReleaseFacts { throw DiagnosticProviderError.unavailable }
}

private struct UnavailablePortProvider: PortFactsProviding {
    func inspect() throws -> PortFacts { throw DiagnosticProviderError.unavailable }
}

private struct UnavailableLocalMCPProvider: LocalMCPDiagnosticProviding {
    func inspect() throws -> LocalMCPFacts { throw DiagnosticProviderError.unavailable }
}

private struct UnavailableLifecycleProvider: LifecycleFactsProviding {
    func inspect() throws -> LifecycleFacts { throw DiagnosticProviderError.unavailable }
}

private struct UnavailableRemoteProvider: RemoteConnectorFactsProviding {
    func inspect() throws -> RemoteConnectorFacts { throw DiagnosticProviderError.unavailable }
}

private struct UnavailableDiskProvider: DiskSpaceProviding {
    func inspect() throws -> DiskSpaceFacts { throw DiagnosticProviderError.unavailable }
}

private struct UnavailableLogDirectoryProvider: LogDirectoryPermissionsProviding {
    func inspect() throws -> LogDirectoryFacts { throw DiagnosticProviderError.unavailable }
}

private struct UnavailableUpdateProvider: UpdateAvailabilityProviding {
    func inspect() throws -> UpdateAvailabilityFacts { throw DiagnosticProviderError.unavailable }
}
