import Foundation

enum DiagnosticChecks {
    static let expectedHelperBundleIdentifier = "com.jay.mac-orchestrator"

    private enum Text {
        static let verified = "Verified."
        static let notApplicable = "Not applicable for the current configuration."
        static let providerUnavailable = "The diagnostic source was unavailable."
        static let requiredMissing = "A required component is missing or unusable."
        static let invalidConfiguration = "The configuration is missing, unreadable, or invalid."
        static let invalidBackup = "The configuration backup is present but unusable."
        static let recoveryEvidence = "Recovery evidence is present and requires review."
        static let trustUnavailable = "Code-signing trust evidence is incomplete."
        static let adHocTrust = "Ad-hoc signing is supported for this development install, but distribution trust is not established."
        static let permissionRequired = "The managed runtime lacks a required interactive permission."
        static let sessionUnavailable = "An active unlocked console session is required for interactive operations."
        static let requesterProbeVerified = "The managed runtime permission probe reported the requested facts."
        static let keychainAbsent = "The optional Keychain item is not present."
        static let keychainUnavailable = "Keychain presence could not be determined."
        static let malformedPort = "The selected local port is invalid."
        static let portOccupied = "The selected local port is occupied by an unrelated listener."
        static let portInspectionUnavailable = "The selected local port could not be inspected safely."
        static let mcpUnavailable = "The local MCP server could not be verified."
        static let mcpNotReady = "The local MCP server is live but canonical readiness was not verified."
        static let inventoryMismatch = "The local MCP tool inventory does not match the expected current-core inventory."
        static let launchAgentInvalid = "The managed LaunchAgent is missing or invalid."
        static let ownershipInvalid = "Managed process ownership could not be verified safely."
        static let remoteInvalid = "The requested remote connector is missing or invalid."
        static let endpointUnavailable = "The requested remote endpoint is unavailable."
        static let updateUnavailable = "Update discovery is unavailable."
        static let diskUnavailable = "The filesystem free-space observation is unavailable."
        static let diskLow = "Free disk space is below the configured noncritical threshold."
        static let unsafePath = "A critical path is symlinked and cannot be trusted."
        static let logDirectoryUnavailable = "Log-directory permissions could not be determined."
    }

    static func configurationRead(_ facts: ConfigurationDiagnosticFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("configuration.read", "Configuration read", .fail, Text.providerUnavailable)
        }
        guard isUsableConfigurationContext(facts) else {
            return result(
                "configuration.read",
                "Configuration read",
                .fail,
                Text.invalidConfiguration
            )
        }
        return result("configuration.read", "Configuration read", .pass, Text.verified)
    }

    static func configurationPermissions(_ facts: ConfigurationDiagnosticFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("configuration.permissions", "Configuration permissions", .fail, Text.providerUnavailable)
        }
        guard isUsableConfigurationDirectory(facts),
              let directoryMode = facts.directoryMode, privateMode(directoryMode) else {
            return result("configuration.permissions", "Configuration permissions", .fail, "Configuration support permissions are unsafe.")
        }
        let primary = facts.primary
        guard primary.exists, !primary.isSymlink, let primaryMode = primary.mode, privateMode(primaryMode) else {
            return result("configuration.permissions", "Configuration permissions", .fail, "Configuration file permissions are unsafe.")
        }
        if facts.backup.exists,
           (facts.backup.isSymlink || facts.backup.mode.map(privateMode) != true) {
            return result("configuration.permissions", "Configuration permissions", .fail, "Configuration file permissions are unsafe.")
        }
        return result("configuration.permissions", "Configuration permissions", .pass, Text.verified)
    }

    static func configurationSchema(_ facts: ConfigurationDiagnosticFacts?) -> DiagnosticResult {
        guard let facts, let schemaVersion = facts.primary.schemaVersion else {
            return result("configuration.schema", "Configuration schema", .fail, Text.invalidConfiguration)
        }
        if facts.primary.state == .unsupported || schemaVersion != AppConfiguration.currentSchemaVersion {
            return result("configuration.schema", "Configuration schema", .fail, "The configuration schema is unsupported.")
        }
        guard isUsableConfigurationContext(facts) else {
            return result("configuration.schema", "Configuration schema", .fail, Text.invalidConfiguration)
        }
        return result("configuration.schema", "Configuration schema", .pass, Text.verified)
    }

    static func configurationBackup(_ facts: ConfigurationDiagnosticFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("configuration.backup", "Configuration backup", .skip, Text.providerUnavailable)
        }
        guard isUsableConfigurationDirectory(facts) else {
            return result("configuration.backup", "Configuration backup", .warn, Text.unsafePath)
        }
        let backup = facts.backup
        guard backup.exists else {
            return result("configuration.backup", "Configuration backup", .skip, "No configuration backup is present.")
        }
        guard isUsableConfigurationFile(backup) else {
            return result("configuration.backup", "Configuration backup", .warn, Text.invalidBackup)
        }
        return result("configuration.backup", "Configuration backup", .pass, Text.verified)
    }

    static func configurationRecovery(_ facts: ConfigurationDiagnosticFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("configuration.recovery", "Configuration recovery", .skip, Text.providerUnavailable)
        }
        let primaryUsable = isUsableConfigurationContext(facts)
        let backupUsable = isUsableConfigurationDirectory(facts) && isUsableConfigurationFile(facts.backup)
        guard isUsableConfigurationDirectory(facts) else {
            return result("configuration.recovery", "Configuration recovery", .fail, Text.unsafePath)
        }
        if !primaryUsable && backupUsable {
            return result(
                "configuration.recovery",
                "Configuration recovery",
                .warn,
                "A valid configuration backup can recover the primary configuration.",
                repair: .restoreConfigurationBackup
            )
        }
        if facts.corruptEvidenceCount > 0 {
            return result("configuration.recovery", "Configuration recovery", .warn, Text.recoveryEvidence)
        }
        if !primaryUsable {
            return result("configuration.recovery", "Configuration recovery", .fail, Text.requiredMissing)
        }
        return result("configuration.recovery", "Configuration recovery", .pass, Text.verified)
    }

    static func configurationGeneration(_ facts: ConfigurationDiagnosticFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("configuration.generation", "Configuration generation", .skip, Text.providerUnavailable)
        }
        guard isUsableConfigurationContext(facts), let generation = facts.primary.generation, generation >= 1 else {
            return result("configuration.generation", "Configuration generation", .fail, Text.invalidConfiguration)
        }
        if isUsableConfigurationFile(facts.backup), let backupGeneration = facts.backup.generation, backupGeneration > generation {
            return result(
                "configuration.generation",
                "Configuration generation",
                .warn,
                "The backup is newer than the primary configuration."
            )
        }
        return result("configuration.generation", "Configuration generation", .pass, Text.verified)
    }

    static func configurationMigration(_ configuration: AppConfiguration?) -> DiagnosticResult {
        guard let configuration else {
            return result("configuration.migration", "Configuration migration", .skip, "No decoded configuration facts are available.")
        }
        if configuration.onboarding.legacyPlaintextCleanupPending || !configuration.onboarding.migrationMarkers.isEmpty {
            return result("configuration.migration", "Configuration migration", .warn, "Migration evidence is present and requires review.")
        }
        return result("configuration.migration", "Configuration migration", .pass, Text.verified)
    }

    static func installationHelper(_ facts: InstalledReleaseFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("installation.helper", "Installed helper", .fail, Text.providerUnavailable, repair: .rerunVerifiedBootstrap)
        }
        guard facts.helperPresent else {
            return result("installation.helper", "Installed helper", .fail, Text.requiredMissing, repair: .rerunVerifiedBootstrap)
        }
        return result("installation.helper", "Installed helper", .pass, Text.verified)
    }

    static func installationRuntime(_ facts: InstalledReleaseFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("installation.runtime", "Managed runtime", .fail, Text.providerUnavailable, repair: .rerunVerifiedBootstrap)
        }
        guard facts.runtime.runtimePresent, facts.runtime.markerPresent, facts.runtime.payloadPresent,
              facts.runtime.structurallyValid else {
            return result("installation.runtime", "Managed runtime", .fail, Text.requiredMissing, repair: .rerunVerifiedBootstrap)
        }
        return result("installation.runtime", "Managed runtime", .pass, Text.verified)
    }

    static func installationHelperArchitecture(_ facts: InstalledReleaseFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("installation.helper-architecture", "Helper architecture", .fail, Text.providerUnavailable, repair: .rerunVerifiedBootstrap)
        }
        guard facts.helperPresent else {
            return result("installation.helper-architecture", "Helper architecture", .fail, Text.requiredMissing, repair: .rerunVerifiedBootstrap)
        }
        guard let architecture = facts.helper.architecture else {
            return result("installation.helper-architecture", "Helper architecture", .warn, "The helper architecture could not be determined.")
        }
        guard architecture == "arm64" else {
            return result("installation.helper-architecture", "Helper architecture", .fail, "The installed helper is not arm64.", repair: .rerunVerifiedBootstrap)
        }
        return result("installation.helper-architecture", "Helper architecture", .pass, Text.verified)
    }

    static func installationRuntimeArchitecture(_ facts: InstalledReleaseFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("installation.runtime-architecture", "Managed runtime architecture", .fail, Text.providerUnavailable, repair: .rerunVerifiedBootstrap)
        }
        guard facts.runtime.runtimePresent else {
            return result("installation.runtime-architecture", "Managed runtime architecture", .fail, Text.requiredMissing, repair: .rerunVerifiedBootstrap)
        }
        guard let architecture = facts.runtime.architecture else {
            return result("installation.runtime-architecture", "Managed runtime architecture", .warn, "The managed runtime architecture could not be determined.")
        }
        guard architecture == "arm64" else {
            return result("installation.runtime-architecture", "Managed runtime architecture", .fail, "The managed runtime is not arm64.", repair: .rerunVerifiedBootstrap)
        }
        return result("installation.runtime-architecture", "Managed runtime architecture", .pass, Text.verified)
    }

    static func installationHelperBundleIdentifier(_ facts: InstalledReleaseFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("installation.helper-bundle-id", "Helper bundle identifier", .fail, Text.providerUnavailable, repair: .rerunVerifiedBootstrap)
        }
        guard facts.helperPresent else {
            return result("installation.helper-bundle-id", "Helper bundle identifier", .fail, Text.requiredMissing, repair: .rerunVerifiedBootstrap)
        }
        guard let bundleIdentifier = facts.helper.bundleIdentifier else {
            return result("installation.helper-bundle-id", "Helper bundle identifier", .warn, "The helper bundle identifier could not be determined.")
        }
        guard bundleIdentifier == expectedHelperBundleIdentifier else {
            return result("installation.helper-bundle-id", "Helper bundle identifier", .fail, "The helper bundle identifier does not match the current Mac Orchestrator helper.", repair: .rerunVerifiedBootstrap)
        }
        return result("installation.helper-bundle-id", "Helper bundle identifier", .pass, Text.verified)
    }

    static func installationIntegrity(_ facts: InstalledReleaseFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("installation.integrity", "Installation integrity", .skip, Text.providerUnavailable)
        }
        guard facts.helper.integrityAvailable else {
            return result("installation.integrity", "Installation integrity", .warn, Text.trustUnavailable)
        }
        guard facts.helper.receiptAvailable else {
            return result("installation.integrity", "Installation integrity", .warn, "Installation receipt evidence is unavailable.")
        }
        return result("installation.integrity", "Installation integrity", .pass, Text.verified)
    }

    static func installationVersionMatch(_ facts: InstalledReleaseFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("installation.version-match", "Installation versions", .skip, Text.providerUnavailable)
        }
        guard let release = facts.releaseVersion, let helper = facts.helper.version, let runtime = facts.runtime.version else {
            return result("installation.version-match", "Installation versions", .warn, "Installation version evidence is incomplete.")
        }
        guard release == helper, release == runtime else {
            return result("installation.version-match", "Installation versions", .fail, "Installed component versions do not match.", repair: .rerunVerifiedBootstrap)
        }
        return result("installation.version-match", "Installation versions", .pass, Text.verified)
    }

    static func trustCodeSign(_ facts: InstalledReleaseFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("trust.codesign", "Code-signing trust", .warn, Text.trustUnavailable)
        }
        guard facts.helper.isSigned else {
            return result("trust.codesign", "Code-signing trust", .fail, "The installed helper is not code signed.", repair: .rerunVerifiedBootstrap)
        }
        if facts.helper.isAdHoc {
            return result("trust.codesign", "Code-signing trust", .warn, Text.adHocTrust)
        }
        if facts.helper.developerIDTrusted == false {
            return result("trust.codesign", "Code-signing trust", .fail, "Developer ID trust could not be established.", repair: .rerunVerifiedBootstrap)
        }
        if facts.helper.developerIDTrusted == nil {
            return result("trust.codesign", "Code-signing trust", .warn, Text.trustUnavailable)
        }
        return result("trust.codesign", "Code-signing trust", .pass, Text.verified)
    }

    static func permissionsRequester(_ facts: PermissionFacts?, configuration: AppConfiguration?) -> DiagnosticResult {
        guard let configuration else {
            return result("permissions.requester", "Requester permissions", .skip, "Requester permissions require validated configuration.")
        }
        guard consumesProtectedBehavior(configuration) else {
            return result("permissions.requester", "Requester permissions", .skip, "No configured local protected behavior consumes requester permissions.")
        }
        guard let facts else {
            return result("permissions.requester", "Requester permissions", .warn, Text.providerUnavailable)
        }
        guard facts.requesterIsManagedRuntime else {
            return result("permissions.requester", "Requester permissions", .skip, "The managed runtime is not the observed requester.")
        }
        guard facts.activeConsole, !facts.sessionLocked else {
            return result("permissions.requester", "Requester permissions", .fail, Text.sessionUnavailable)
        }
        let capabilities = configuration.desiredCapabilities
        if capabilities["mac.ui"] == true && !facts.accessibility {
            return result("permissions.requester", "Requester permissions", .fail, Text.permissionRequired, repair: .openAccessibilitySettings)
        }
        if capabilities["mac.screenOcr"] == true && !facts.screenRecording {
            return result("permissions.requester", "Requester permissions", .fail, Text.permissionRequired, repair: .openScreenRecordingSettings)
        }
        if capabilities["mac.ui"] == true && !facts.automation {
            return result("permissions.requester", "Requester permissions", .fail, Text.permissionRequired, repair: .openAutomationSettings)
        }
        return result("permissions.requester", "Requester permissions", .pass, Text.requesterProbeVerified)
    }

    static func keychainConnector(_ facts: KeychainPresenceFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("keychain.connector", "Connector Keychain presence", .skip, Text.keychainUnavailable)
        }
        switch facts.presence(for: .connectorToken) {
        case .present:
            return result("keychain.connector", "Connector Keychain presence", .pass, Text.verified)
        case .absent, nil:
            return result("keychain.connector", "Connector Keychain presence", .skip, Text.keychainAbsent)
        case .inaccessible:
            return result("keychain.connector", "Connector Keychain presence", .warn, Text.keychainUnavailable)
        }
    }

    static func keychainTelegramSend(_ facts: KeychainPresenceFacts?, desired: Bool) -> DiagnosticResult {
        guard desired else {
            return result("keychain.telegram-send", "Telegram Send Keychain presence", .skip, Text.notApplicable)
        }
        guard let facts else {
            return result("keychain.telegram-send", "Telegram Send Keychain presence", .warn, Text.keychainUnavailable)
        }
        let token = facts.presence(for: .telegramSendBotToken)
        let chatID = facts.presence(for: .telegramSendChatID)
        if token == .inaccessible || chatID == .inaccessible || token == nil || chatID == nil {
            return result("keychain.telegram-send", "Telegram Send Keychain presence", .warn, Text.keychainUnavailable)
        }
        if token == .absent || chatID == .absent {
            return result("keychain.telegram-send", "Telegram Send Keychain presence", .fail, "Telegram Send is enabled but a required Keychain item is absent.")
        }
        return result("keychain.telegram-send", "Telegram Send Keychain presence", .pass, Text.verified)
    }

    static func portSelected(_ facts: PortFacts?, configuredPort: Int?) -> DiagnosticResult {
        guard let configuredPort else {
            return result("port.selected", "Selected local port", .skip, "The selected port requires validated configuration.")
        }
        guard let facts else {
            return result("port.selected", "Selected local port", .fail, Text.providerUnavailable, repair: .reassignLocalPort)
        }
        guard (1...65535).contains(configuredPort) else {
            return result("port.selected", "Selected local port", .fail, Text.malformedPort, repair: .reassignLocalPort)
        }
        guard facts.inspectionAvailable else {
            return result("port.selected", "Selected local port", .warn, Text.portInspectionUnavailable, repair: .reassignLocalPort)
        }
        if facts.pidReuseDetected || (facts.listenerPresent && !facts.listenerOwned) {
            return result("port.selected", "Selected local port", .fail, Text.portOccupied, repair: .reassignLocalPort)
        }
        return result("port.selected", "Selected local port", .pass, Text.verified)
    }

    static func mcpLiveness(_ facts: LocalMCPFacts?, desired: Bool) -> DiagnosticResult {
        guard desired else { return result("mcp.liveness", "Local MCP liveness", .skip, Text.notApplicable) }
        guard let facts, facts.livenessVerified else {
            return result("mcp.liveness", "Local MCP liveness", .fail, Text.mcpUnavailable, repair: .retryMCPServer)
        }
        return result("mcp.liveness", "Local MCP liveness", .pass, Text.verified)
    }

    static func mcpReadiness(_ facts: LocalMCPFacts?, desired: Bool) -> DiagnosticResult {
        guard desired else { return result("mcp.readiness", "Local MCP readiness", .skip, Text.notApplicable) }
        guard let facts, facts.livenessVerified else {
            return result("mcp.readiness", "Local MCP readiness", .skip, "Readiness requires verified local liveness.")
        }
        guard facts.readinessVerified, facts.sessionEstablished, facts.safeCallSucceeded else {
            return result("mcp.readiness", "Local MCP readiness", .fail, Text.mcpNotReady, repair: .retryMCPServer)
        }
        return result("mcp.readiness", "Local MCP readiness", .pass, Text.verified)
    }

    static func mcpInventory(_ facts: LocalMCPFacts?, desired: Bool) -> DiagnosticResult {
        guard desired else { return result("mcp.inventory", "Local MCP inventory", .skip, Text.notApplicable) }
        guard let facts,
              facts.livenessVerified,
              facts.readinessVerified,
              facts.sessionEstablished,
              facts.safeCallSucceeded else {
            return result("mcp.inventory", "Local MCP inventory", .skip, "Inventory requires complete canonical local readiness.")
        }
        guard facts.expectedTools == facts.exposedTools,
              facts.expectedCapabilityGroups == facts.exposedCapabilityGroups else {
            return result("mcp.inventory", "Local MCP inventory", .fail, Text.inventoryMismatch, repair: .retryMCPServer)
        }
        return result("mcp.inventory", "Local MCP inventory", .pass, Text.verified)
    }

    static func lifecycleLaunchAgent(_ facts: LifecycleFacts?, desired: Bool) -> DiagnosticResult {
        guard desired else { return result("lifecycle.launch-agent", "LaunchAgent", .skip, Text.notApplicable) }
        guard let facts, facts.launchAgentPresent, facts.launchAgentValid else {
            return result("lifecycle.launch-agent", "LaunchAgent", .fail, Text.launchAgentInvalid, repair: .repairLaunchAgent)
        }
        return result("lifecycle.launch-agent", "LaunchAgent", .pass, Text.verified)
    }

    static func lifecycleProcessOwnership(_ facts: LifecycleFacts?, desired: Bool) -> DiagnosticResult {
        guard desired else { return result("lifecycle.process-ownership", "Process ownership", .skip, Text.notApplicable) }
        guard let facts else {
            return result("lifecycle.process-ownership", "Process ownership", .fail, Text.providerUnavailable, repair: .retryMCPServer)
        }
        guard facts.serviceRunning,
              facts.ownedProcessCount > 0,
              facts.ownershipMarkerPresent,
              !facts.duplicateOwnedProcesses,
              !facts.pidReuseDetected else {
            return result("lifecycle.process-ownership", "Process ownership", .fail, Text.ownershipInvalid, repair: .retryMCPServer)
        }
        return result("lifecycle.process-ownership", "Process ownership", .pass, Text.verified)
    }

    static func remoteNgrok(_ facts: RemoteConnectorFacts?, auth: KeychainPresence?, desired: Bool) -> DiagnosticResult {
        guard desired else { return result("remote.ngrok", "Remote ngrok", .skip, Text.notApplicable) }
        guard let facts else {
            return result("remote.ngrok", "Remote ngrok", .fail, Text.providerUnavailable, repair: .retryRemoteConnector)
        }
        guard facts.binaryPresent, facts.configurationPresent, facts.ownershipMarkerPresent else {
            return result("remote.ngrok", "Remote ngrok", .fail, Text.remoteInvalid, repair: .retryRemoteConnector)
        }
        switch auth {
        case .present:
            return result("remote.ngrok", "Remote ngrok", .pass, Text.verified)
        case .absent, nil:
            return result("remote.ngrok", "Remote ngrok", .fail, Text.remoteInvalid, repair: .retryRemoteConnector)
        case .inaccessible:
            return result("remote.ngrok", "Remote ngrok", .warn, Text.keychainUnavailable, repair: .retryRemoteConnector)
        }
    }

    static func remoteNgrokArchitecture(_ facts: RemoteConnectorFacts?, desired: Bool) -> DiagnosticResult {
        guard desired else {
            return result("remote.ngrok-architecture", "Remote ngrok architecture", .skip, Text.notApplicable)
        }
        guard let facts else {
            return result("remote.ngrok-architecture", "Remote ngrok architecture", .fail, Text.providerUnavailable, repair: .retryRemoteConnector)
        }
        guard facts.binaryPresent else {
            return result("remote.ngrok-architecture", "Remote ngrok architecture", .fail, Text.remoteInvalid, repair: .retryRemoteConnector)
        }
        guard let architecture = facts.binaryArchitecture else {
            return result("remote.ngrok-architecture", "Remote ngrok architecture", .warn, "The ngrok binary architecture could not be determined.")
        }
        guard architecture == "arm64" else {
            return result("remote.ngrok-architecture", "Remote ngrok architecture", .fail, "The installed ngrok binary is not arm64.", repair: .retryRemoteConnector)
        }
        return result("remote.ngrok-architecture", "Remote ngrok architecture", .pass, Text.verified)
    }

    static func remoteNgrokSigning(_ facts: RemoteConnectorFacts?, desired: Bool) -> DiagnosticResult {
        guard desired else {
            return result("remote.ngrok-signing", "Remote ngrok vendor signing", .skip, Text.notApplicable)
        }
        guard let facts else {
            return result("remote.ngrok-signing", "Remote ngrok vendor signing", .fail, Text.providerUnavailable, repair: .retryRemoteConnector)
        }
        guard facts.binaryPresent else {
            return result("remote.ngrok-signing", "Remote ngrok vendor signing", .fail, Text.remoteInvalid, repair: .retryRemoteConnector)
        }
        guard let originalVendorSigning = facts.originalVendorSigning else {
            return result("remote.ngrok-signing", "Remote ngrok vendor signing", .warn, "Original ngrok vendor signing could not be determined.")
        }
        guard originalVendorSigning else {
            return result("remote.ngrok-signing", "Remote ngrok vendor signing", .warn, "Original ngrok vendor signing was not established.")
        }
        return result("remote.ngrok-signing", "Remote ngrok vendor signing", .pass, Text.verified)
    }

    static func remoteEndpoint(_ facts: RemoteConnectorFacts?, desired: Bool) -> DiagnosticResult {
        guard desired else { return result("remote.endpoint", "Remote endpoint", .skip, Text.notApplicable) }
        guard let facts else {
            return result("remote.endpoint", "Remote endpoint", .fail, Text.providerUnavailable, repair: .retryRemoteConnector)
        }
        // The configured upstream is the trust boundary. Other endpoints in
        // the Agent API response are unrelated; their presence must not turn
        // an otherwise exact match into a failure.
        guard facts.endpointAvailable, facts.endpointCount > 0 else {
            return result("remote.endpoint", "Remote endpoint", .fail, Text.endpointUnavailable, repair: .retryRemoteConnector)
        }
        return result("remote.endpoint", "Remote endpoint", .pass, Text.verified)
    }

    static func updateAvailability(_ facts: UpdateAvailabilityFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("update.availability", "Update availability", .skip, Text.updateUnavailable)
        }
        if facts.inspectionFailed {
            return result("update.availability", "Update availability", .warn, "Update discovery failed safely; trust was not established.")
        }
        switch facts.status {
        case .unavailable:
            return result("update.availability", "Update availability", .skip, Text.updateUnavailable)
        case .current:
            return result("update.availability", "Update availability", .pass, Text.verified)
        case .available:
            return result("update.availability", "Update availability", .warn, "A newer version is available.")
        }
    }

    static func diskFreeSpace(_ facts: DiskSpaceFacts?, thresholdBytes: Int64?) -> DiagnosticResult {
        guard let facts, facts.filesystemAccessible else {
            return result("disk.free-space", "Free disk space", .fail, Text.diskUnavailable)
        }
        guard let available = facts.availableBytes, let threshold = thresholdBytes ?? facts.thresholdBytes else {
            return result("disk.free-space", "Free disk space", .skip, Text.diskUnavailable)
        }
        if available < threshold {
            return result("disk.free-space", "Free disk space", .warn, Text.diskLow)
        }
        return result("disk.free-space", "Free disk space", .pass, Text.verified)
    }

    static func criticalPaths(_ facts: DiskSpaceFacts?) -> DiagnosticResult {
        guard let facts else {
            return result("filesystem.critical-paths", "Critical filesystem paths", .skip, Text.providerUnavailable)
        }
        guard facts.criticalPathSymlinkCount == 0 else {
            return result("filesystem.critical-paths", "Critical filesystem paths", .fail, Text.unsafePath)
        }
        return result("filesystem.critical-paths", "Critical filesystem paths", .pass, Text.verified)
    }

    static func logDirectoryPermissions(_ facts: LogDirectoryFacts?) -> DiagnosticResult {
        guard let facts, facts.inspectionAvailable else {
            return result("filesystem.log-directory-permissions", "Log-directory permissions", .skip, Text.logDirectoryUnavailable)
        }
        guard facts.pathSafe else {
            return result("filesystem.log-directory-permissions", "Log-directory permissions", .fail, Text.unsafePath)
        }
        guard facts.exists else {
            return result("filesystem.log-directory-permissions", "Log-directory permissions", .skip, "The log directory is not present.")
        }
        guard facts.isDirectory, let mode = facts.mode, privateMode(mode) else {
            return result("filesystem.log-directory-permissions", "Log-directory permissions", .fail, "Log-directory permissions are unsafe.")
        }
        return result("filesystem.log-directory-permissions", "Log-directory permissions", .pass, Text.verified)
    }

    static func futureCapability(_ id: String, title: String) -> DiagnosticResult {
        result(id, title, .skip, "This capability is not implemented in the current core.")
    }

    private static func result(
        _ id: String,
        _ title: String,
        _ status: DiagnosticStatus,
        _ reason: String,
        repair: RepairActionID? = nil
    ) -> DiagnosticResult {
        DiagnosticResult(
            id: id,
            title: title,
            status: status,
            reason: reason,
            repair: repair.map { descriptor(for: $0) }
        )
    }

    private static func descriptor(for id: RepairActionID) -> RepairActionDescriptor {
        switch id {
        case .retryMCPServer:
            return RepairActionDescriptor(id: id, title: "Retry local MCP server", guidance: "Retry the managed local MCP lifecycle and run Doctor again.")
        case .retryRemoteConnector:
            return RepairActionDescriptor(id: id, title: "Retry remote connector", guidance: "Retry the managed remote connector and run Doctor again.")
        case .openAccessibilitySettings:
            return RepairActionDescriptor(id: id, title: "Review Accessibility permission", guidance: "Review the managed requester in System Settings.")
        case .openScreenRecordingSettings:
            return RepairActionDescriptor(id: id, title: "Review Screen Recording permission", guidance: "Review the managed requester in System Settings.")
        case .openAutomationSettings:
            return RepairActionDescriptor(id: id, title: "Review Automation permission", guidance: "Review the managed requester in System Settings.")
        case .restoreConfigurationBackup:
            return RepairActionDescriptor(id: id, title: "Review configuration backup", guidance: "Review the validated backup before explicitly restoring it.")
        case .reassignLocalPort:
            return RepairActionDescriptor(id: id, title: "Reassign local port", guidance: "Choose a free local port without terminating the occupying process.")
        case .repairLaunchAgent:
            return RepairActionDescriptor(id: id, title: "Repair LaunchAgent", guidance: "Review and explicitly repair the managed LaunchAgent contract.")
        case .rerunVerifiedBootstrap:
            return RepairActionDescriptor(id: id, title: "Rerun verified bootstrap", guidance: "Use the pinned, verified bootstrap recovery path.")
        }
    }

    private static func privateMode(_ mode: UInt16) -> Bool {
        mode & 0o077 == 0
    }

    static func isUsableConfigurationFile(_ file: ConfigurationFileFacts) -> Bool {
        file.exists
            && file.readable
            && file.valid
            && file.state == .valid
            && !file.isSymlink
            && file.schemaVersion == AppConfiguration.currentSchemaVersion
    }

    static func isUsableConfigurationContext(_ facts: ConfigurationDiagnosticFacts) -> Bool {
        isUsableConfigurationDirectory(facts)
            && isUsableConfigurationFile(facts.primary)
    }

    static func isUsableConfigurationDirectory(_ facts: ConfigurationDiagnosticFacts) -> Bool {
        (facts.directoryExists || (facts.directoryMode == nil && (facts.primary.exists || facts.backup.exists)))
            && !facts.directoryIsSymlink
            && facts.directoryPathSafe
    }

    static func consumesProtectedBehavior(_ configuration: AppConfiguration?) -> Bool {
        guard let configuration, configuration.process.serverDesired else { return false }
        return configuration.desiredCapabilities["mac.ui"] == true
            || configuration.desiredCapabilities["mac.screenOcr"] == true
    }
}
