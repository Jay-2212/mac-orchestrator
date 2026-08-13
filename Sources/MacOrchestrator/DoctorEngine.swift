import Foundation

struct DoctorThresholds: Equatable, Sendable {
    let lowDiskBytes: Int64?

    init(lowDiskBytes: Int64? = nil) {
        self.lowDiskBytes = lowDiskBytes
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
    let configurationProvider: any ConfigurationDiagnosticProviding
    let configuration: AppConfiguration?
    let installedReleaseProvider: any InstalledReleaseFactsProviding
    let permissionProvider: any PermissionFactsProviding
    let keychainPresenceProvider: any KeychainPresenceProviding
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
        configurationProvider: any ConfigurationDiagnosticProviding = UnavailableConfigurationProvider(),
        configuration: AppConfiguration? = nil,
        installedReleaseProvider: any InstalledReleaseFactsProviding = UnavailableInstalledReleaseProvider(),
        permissionProvider: any PermissionFactsProviding = UnavailablePermissionProvider(),
        keychainPresenceProvider: any KeychainPresenceProviding = UnavailableKeychainPresenceProvider(),
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
        self.configurationProvider = configurationProvider
        self.configuration = configuration
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
        let configurationFacts = inspectConfiguration()
        let installedFacts = inspectInstalledRelease()
        let permissionFacts = inspectPermissions()
        let keychainFacts = inspectKeychain()
        let portFacts = inspectPort()
        let localMCPFacts = await inspectLocalMCP()
        let lifecycleFacts = inspectLifecycle()
        let remoteFacts = inspectRemote()
        let diskFacts = inspectDisk()
        let updateFacts = inspectUpdate()

        let usableConfiguration = configurationFacts?.primary.valid == true
            ? dependencies.configuration
            : nil
        let serverDesired = usableConfiguration?.process.serverDesired ?? true
        let remoteDesired = (usableConfiguration?.process.tunnelDesired == true)
            || (usableConfiguration?.desiredCapabilities["remote.connector"] == true)
            || (remoteFacts?.desired == true)

        var results = [
            DiagnosticChecks.configurationRead(configurationFacts),
            DiagnosticChecks.configurationPermissions(configurationFacts),
            DiagnosticChecks.configurationSchema(configurationFacts),
            DiagnosticChecks.configurationBackup(configurationFacts),
            DiagnosticChecks.configurationRecovery(configurationFacts),
            DiagnosticChecks.configurationGeneration(configurationFacts),
            DiagnosticChecks.configurationMigration(usableConfiguration),
            DiagnosticChecks.installationHelper(installedFacts),
            DiagnosticChecks.installationRuntime(installedFacts),
            DiagnosticChecks.installationIntegrity(installedFacts),
            DiagnosticChecks.installationVersionMatch(installedFacts),
            DiagnosticChecks.trustCodeSign(installedFacts),
            DiagnosticChecks.permissionsRequester(permissionFacts, configuration: usableConfiguration),
            DiagnosticChecks.keychainConnector(keychainFacts),
            DiagnosticChecks.portSelected(portFacts, configuredPort: usableConfiguration?.localMCPPort),
            DiagnosticChecks.mcpLiveness(localMCPFacts, desired: serverDesired),
            DiagnosticChecks.mcpReadiness(localMCPFacts, desired: serverDesired),
            DiagnosticChecks.mcpInventory(localMCPFacts, desired: serverDesired),
            DiagnosticChecks.lifecycleLaunchAgent(lifecycleFacts, desired: serverDesired || remoteDesired),
            DiagnosticChecks.lifecycleProcessOwnership(lifecycleFacts, desired: serverDesired || remoteDesired),
            DiagnosticChecks.remoteNgrok(
                remoteFacts,
                auth: keychainFacts?.presence(for: .ngrokAuthtoken),
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

    private func inspectConfiguration() -> ConfigurationDiagnosticFacts? {
        try? dependencies.configurationProvider.inspect()
    }

    private func inspectInstalledRelease() -> InstalledReleaseFacts? {
        try? dependencies.installedReleaseProvider.inspect()
    }

    private func inspectPermissions() -> PermissionFacts? {
        try? dependencies.permissionProvider.inspect()
    }

    private func inspectKeychain() -> KeychainPresenceFacts? {
        try? dependencies.keychainPresenceProvider.inspect()
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

private struct UnavailableConfigurationProvider: ConfigurationDiagnosticProviding {
    func inspect() throws -> ConfigurationDiagnosticFacts { throw DiagnosticProviderError.unavailable }
}

private struct UnavailableInstalledReleaseProvider: InstalledReleaseFactsProviding {
    func inspect() throws -> InstalledReleaseFacts { throw DiagnosticProviderError.unavailable }
}

private struct UnavailablePermissionProvider: PermissionFactsProviding {
    func inspect() throws -> PermissionFacts { throw DiagnosticProviderError.unavailable }
}

private struct UnavailableKeychainPresenceProvider: KeychainPresenceProviding {
    func inspect() throws -> KeychainPresenceFacts { throw DiagnosticProviderError.unavailable }
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
