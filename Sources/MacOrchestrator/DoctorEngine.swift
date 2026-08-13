import Foundation

struct DoctorThresholds: Equatable, Sendable {
    let lowDiskBytes: Int64?

    init(lowDiskBytes: Int64? = nil) {
        self.lowDiskBytes = lowDiskBytes
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

protocol DoctorKeychainPresenceProviding {
    func inspect(items: Set<KeychainPresenceItem>) throws -> KeychainPresenceFacts
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
    let updateProvider: any UpdateAvailabilityProviding
    let thresholds: DoctorThresholds
    let clock: @Sendable () -> Date

    init(
        configurationContextProvider: any DoctorConfigurationContextProviding = UnavailableConfigurationContextProvider(),
        installedReleaseProvider: any InstalledReleaseFactsProviding = UnavailableInstalledReleaseProvider(),
        permissionProvider: any PermissionFactsProviding = UnavailablePermissionProvider(),
        keychainPresenceProvider: any DoctorKeychainPresenceProviding = UnavailableDoctorKeychainProvider(),
        portProvider: any PortFactsProviding = UnavailablePortProvider(),
        localMCPProvider: any LocalMCPDiagnosticProviding = UnavailableLocalMCPProvider(),
        asyncLocalMCPProvider: (any DoctorAsyncLocalMCPDiagnosticProviding)? = nil,
        lifecycleProvider: any LifecycleFactsProviding = UnavailableLifecycleProvider(),
        remoteConnectorProvider: any RemoteConnectorFactsProviding = UnavailableRemoteProvider(),
        diskSpaceProvider: any DiskSpaceProviding = UnavailableDiskProvider(),
        updateProvider: any UpdateAvailabilityProviding = UnavailableUpdateProvider(),
        thresholds: DoctorThresholds = DoctorThresholds(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configurationContextProvider = configurationContextProvider
        self.installedReleaseProvider = installedReleaseProvider
        self.permissionProvider = permissionProvider
        self.keychainPresenceProvider = keychainPresenceProvider
        self.portProvider = portProvider
        self.localMCPProvider = localMCPProvider
        self.asyncLocalMCPProvider = asyncLocalMCPProvider
        self.lifecycleProvider = lifecycleProvider
        self.remoteConnectorProvider = remoteConnectorProvider
        self.diskSpaceProvider = diskSpaceProvider
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
        let snapshot = inspectConfigurationContext()
        let configurationFacts = snapshot?.facts
        let configuration = snapshot.flatMap {
            DiagnosticChecks.isUsableConfigurationFile($0.facts.primary) ? $0.validatedConfiguration : nil
        }
        let hasValidatedConfiguration = configuration != nil
        let serverDesired = configuration?.process.serverDesired == true
        let remoteDesired = configuration?.process.tunnelDesired == true
            || configuration?.desiredCapabilities["remote.connector"] == true

        let installedFacts = inspectInstalledRelease()
        let permissionFacts = hasValidatedConfiguration ? inspectPermissions() : nil
        let portFacts = serverDesired ? inspectPort() : nil
        let localMCPFacts = serverDesired ? await inspectLocalMCP() : nil
        let lifecycleFacts = (serverDesired || remoteDesired) ? inspectLifecycle() : nil
        let keychainFacts = inspectKeychain(
            localDesired: serverDesired,
            remoteDesired: remoteDesired,
            hasValidatedConfiguration: hasValidatedConfiguration
        )
        let remoteFacts = remoteDesired ? inspectRemote() : nil
        let diskFacts = inspectDisk()
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
            DiagnosticChecks.installationIntegrity(installedFacts),
            DiagnosticChecks.installationVersionMatch(installedFacts),
            DiagnosticChecks.trustCodeSign(installedFacts),
            DiagnosticChecks.permissionsRequester(permissionFacts, configuration: configuration),
            DiagnosticChecks.keychainConnector(serverDesired ? keychainFacts : nil),
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
            DiagnosticChecks.remoteEndpoint(remoteFacts, desired: remoteDesired),
            DiagnosticChecks.updateAvailability(updateFacts),
            DiagnosticChecks.diskFreeSpace(diskFacts, thresholdBytes: dependencies.thresholds.lowDiskBytes),
            DiagnosticChecks.criticalPaths(diskFacts),
            DiagnosticChecks.futureCapability("capability.meridian", title: "Meridian capability"),
            DiagnosticChecks.futureCapability("capability.cloudflare", title: "Cloudflare capability"),
            DiagnosticChecks.futureCapability("capability.telegram-assistant", title: "Telegram Assistant capability"),
        ]
        results.sort { $0.id < $1.id }
        return DoctorReport(generatedAt: dependencies.clock(), results: results)
    }

    private func inspectConfigurationContext() -> DoctorConfigurationSnapshot? {
        try? dependencies.configurationContextProvider.inspect()
    }

    private func inspectInstalledRelease() -> InstalledReleaseFacts? {
        try? dependencies.installedReleaseProvider.inspect()
    }

    private func inspectPermissions() -> PermissionFacts? {
        try? dependencies.permissionProvider.inspect()
    }

    private func inspectKeychain(
        localDesired: Bool,
        remoteDesired: Bool,
        hasValidatedConfiguration: Bool
    ) -> KeychainPresenceFacts? {
        guard hasValidatedConfiguration else { return nil }
        var items = Set<KeychainPresenceItem>()
        if localDesired { items.insert(.connectorToken) }
        if remoteDesired { items.insert(.ngrokAuthtoken) }
        guard !items.isEmpty else { return nil }
        return try? dependencies.keychainPresenceProvider.inspect(items: items)
    }

    private func inspectPort() -> PortFacts? {
        try? dependencies.portProvider.inspect()
    }

    private func inspectLocalMCP() async -> LocalMCPFacts? {
        if let provider = dependencies.asyncLocalMCPProvider {
            return try? await provider.inspect()
        }
        return try? dependencies.localMCPProvider.inspect()
    }

    private func inspectLifecycle() -> LifecycleFacts? {
        try? dependencies.lifecycleProvider.inspect()
    }

    private func inspectRemote() -> RemoteConnectorFacts? {
        try? dependencies.remoteConnectorProvider.inspect()
    }

    private func inspectDisk() -> DiskSpaceFacts? {
        try? dependencies.diskSpaceProvider.inspect()
    }

    private func inspectUpdate() -> UpdateAvailabilityFacts? {
        try? dependencies.updateProvider.inspect()
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

private struct UnavailablePermissionProvider: PermissionFactsProviding {
    func inspect() throws -> PermissionFacts { throw DiagnosticProviderError.unavailable }
}

private struct UnavailableDoctorKeychainProvider: DoctorKeychainPresenceProviding {
    func inspect(items: Set<KeychainPresenceItem>) throws -> KeychainPresenceFacts {
        throw DiagnosticProviderError.unavailable
    }
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

private struct UnavailableUpdateProvider: UpdateAvailabilityProviding {
    func inspect() throws -> UpdateAvailabilityFacts { throw DiagnosticProviderError.unavailable }
}
