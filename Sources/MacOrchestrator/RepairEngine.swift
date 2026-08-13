import Foundation

enum RepairOutcomeStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case repaired = "repaired"
    case notNeeded = "notNeeded"
    case refused = "refused"
    case failed = "failed"
    case requiresUserAction = "requiresUserAction"
}

struct RepairOutcome: Codable, Equatable, Sendable {
    let action: RepairActionID
    let status: RepairOutcomeStatus
    let reason: String

    var safeReason: String { reason }

    init(action: RepairActionID, status: RepairOutcomeStatus, reason: String) {
        self.action = action
        self.status = status
        self.reason = RepairOutcome.safeReason(reason)
    }

    private static func safeReason(_ reason: String) -> String {
        // Outcomes created by RepairEngine use only fixed strings. Keep this
        // initializer defensive for support tooling and test adapters too.
        let lowercased = reason.lowercased()
        let containsUnsafeValue = lowercased.contains("http://")
            || lowercased.contains("https://")
            || lowercased.contains("/users/")
            || lowercased.contains("/private/")
            || lowercased.contains("secret")
            || lowercased.contains("token")
        return containsUnsafeValue ? "The repair result was recorded without sensitive details." : reason
    }
}

extension RepairActionID: CaseIterable {
    static var allCases: [RepairActionID] {
        [
            .retryMCPServer,
            .retryRemoteConnector,
            .openAccessibilitySettings,
            .openScreenRecordingSettings,
            .openAutomationSettings,
            .restoreConfigurationBackup,
            .reassignLocalPort,
            .repairLaunchAgent,
            .rerunVerifiedBootstrap,
        ]
    }
}

struct RepairAdapterResult: Equatable, Sendable {
    let status: RepairOutcomeStatus
    let clientReconfigurationRequired: Bool

    init(status: RepairOutcomeStatus, clientReconfigurationRequired: Bool = false) {
        self.status = status
        self.clientReconfigurationRequired = clientReconfigurationRequired
    }

    static let repaired = RepairAdapterResult(status: .repaired)
    static let notNeeded = RepairAdapterResult(status: .notNeeded)
    static let refused = RepairAdapterResult(status: .refused)
    static let failed = RepairAdapterResult(status: .failed)
    static let requiresUserAction = RepairAdapterResult(status: .requiresUserAction)
}

enum LifecycleRepairTarget: String, Codable, Equatable, Sendable {
    case mcpServer
    case remoteConnector
}

enum PermissionSettingsPane: String, Codable, Equatable, Sendable {
    case accessibility
    case screenRecording
    case automation
}

protocol LifecycleRetrying: Sendable {
    func retry(_ target: LifecycleRepairTarget) async -> RepairAdapterResult
}

protocol PermissionSettingsOpening: Sendable {
    func open(_ pane: PermissionSettingsPane) async -> RepairAdapterResult
}

protocol ConfigurationBackupRestoring: Sendable {
    func restoreValidatedBackup() async -> RepairAdapterResult
}

protocol LocalPortReassigning: Sendable {
    func reassignLocalPort() async -> RepairAdapterResult
}

protocol LaunchAgentRepairing: Sendable {
    func repairManagedLaunchAgent() async -> RepairAdapterResult
}

protocol VerifiedBootstrapHandingOff: Sendable {
    func handoffVerifiedBootstrap() async -> RepairAdapterResult
}

struct RepairDependencies: Sendable {
    let lifecycleRetrying: (any LifecycleRetrying)?
    let permissionSettingsOpening: (any PermissionSettingsOpening)?
    let configurationBackupRestoring: (any ConfigurationBackupRestoring)?
    let localPortReassigning: (any LocalPortReassigning)?
    let launchAgentRepairing: (any LaunchAgentRepairing)?
    let verifiedBootstrapHandingOff: (any VerifiedBootstrapHandingOff)?

    init(
        lifecycleRetrying: (any LifecycleRetrying)? = nil,
        permissionSettingsOpening: (any PermissionSettingsOpening)? = nil,
        configurationBackupRestoring: (any ConfigurationBackupRestoring)? = nil,
        localPortReassigning: (any LocalPortReassigning)? = nil,
        launchAgentRepairing: (any LaunchAgentRepairing)? = nil,
        verifiedBootstrapHandingOff: (any VerifiedBootstrapHandingOff)? = nil
    ) {
        self.lifecycleRetrying = lifecycleRetrying
        self.permissionSettingsOpening = permissionSettingsOpening
        self.configurationBackupRestoring = configurationBackupRestoring
        self.localPortReassigning = localPortReassigning
        self.launchAgentRepairing = launchAgentRepairing
        self.verifiedBootstrapHandingOff = verifiedBootstrapHandingOff
    }
}

struct RepairEngine: Sendable {
    private let dependencies: RepairDependencies

    init(dependencies: RepairDependencies) {
        self.dependencies = dependencies
    }

    func execute(_ action: RepairActionID) async -> RepairOutcome {
        switch action {
        case .retryMCPServer:
            guard let adapter = dependencies.lifecycleRetrying else {
                return outcome(for: action, status: .refused)
            }
            return outcome(
                for: action,
                result: await adapter.retry(.mcpServer)
            )
        case .retryRemoteConnector:
            guard let adapter = dependencies.lifecycleRetrying else {
                return outcome(for: action, status: .refused)
            }
            return outcome(
                for: action,
                result: await adapter.retry(.remoteConnector)
            )
        case .openAccessibilitySettings:
            return await executePermission(action, pane: .accessibility)
        case .openScreenRecordingSettings:
            return await executePermission(action, pane: .screenRecording)
        case .openAutomationSettings:
            return await executePermission(action, pane: .automation)
        case .restoreConfigurationBackup:
            guard let adapter = dependencies.configurationBackupRestoring else {
                return outcome(for: action, status: .refused)
            }
            return outcome(
                for: action,
                result: await adapter.restoreValidatedBackup()
            )
        case .reassignLocalPort:
            guard let adapter = dependencies.localPortReassigning else {
                return outcome(for: action, status: .refused)
            }
            return outcome(
                for: action,
                result: await adapter.reassignLocalPort()
            )
        case .repairLaunchAgent:
            guard let adapter = dependencies.launchAgentRepairing else {
                return outcome(for: action, status: .refused)
            }
            return outcome(
                for: action,
                result: await adapter.repairManagedLaunchAgent()
            )
        case .rerunVerifiedBootstrap:
            guard let adapter = dependencies.verifiedBootstrapHandingOff else {
                return outcome(for: action, status: .refused)
            }
            return outcome(
                for: action,
                result: await adapter.handoffVerifiedBootstrap()
            )
        }
    }

    private func executePermission(
        _ action: RepairActionID,
        pane: PermissionSettingsPane
    ) async -> RepairOutcome {
        guard let adapter = dependencies.permissionSettingsOpening else {
            return outcome(for: action, status: .refused)
        }
        let result = await adapter.open(pane)
        let status: RepairOutcomeStatus
        switch result.status {
        case .repaired, .requiresUserAction:
            status = .requiresUserAction
        case .notNeeded, .refused, .failed:
            status = result.status
        }
        return outcome(for: action, status: status)
    }

    private func outcome(
        for action: RepairActionID,
        result: RepairAdapterResult
    ) -> RepairOutcome {
        var status = result.status
        if action == .reassignLocalPort,
           result.status == .repaired,
           result.clientReconfigurationRequired {
            status = .repaired
        }
        return outcome(for: action, status: status, clientGuidance: result.clientReconfigurationRequired)
    }

    private func outcome(
        for action: RepairActionID,
        status: RepairOutcomeStatus,
        clientGuidance: Bool = false
    ) -> RepairOutcome {
        RepairOutcome(
            action: action,
            status: status,
            reason: SafeRepairReasons.message(
                for: action,
                status: status,
                clientGuidance: clientGuidance
            )
        )
    }
}

private enum SafeRepairReasons {
    static func message(
        for action: RepairActionID,
        status: RepairOutcomeStatus,
        clientGuidance: Bool
    ) -> String {
        switch status {
        case .notNeeded:
            return "No repair was needed."
        case .refused:
            return "Repair was refused because its ownership or precondition was not verified."
        case .failed:
            return "The requested repair failed safely; review Doctor diagnostics."
        case .requiresUserAction:
            switch action {
            case .openAccessibilitySettings, .openScreenRecordingSettings, .openAutomationSettings:
                return "Open the requested System Settings pane, grant access, then run Doctor again."
            case .rerunVerifiedBootstrap:
                return "Verified bootstrap handoff is ready; follow the pinned release installation guidance."
            default:
                return "User action is required; review Doctor guidance and run Doctor again."
            }
        case .repaired:
            if clientGuidance {
                return "The local port was reassigned; configured clients must use the new port."
            }
            switch action {
            case .repairLaunchAgent:
                return "The Mac Orchestrator LaunchAgent contract was repaired."
            case .restoreConfigurationBackup:
                return "The validated configuration backup was restored and the prior primary was preserved."
            case .rerunVerifiedBootstrap:
                return "The verified bootstrap handoff was prepared."
            default:
                return "The requested Mac Orchestrator repair completed."
            }
        }
    }
}

struct ConfigurationStoreBackupRestorer: @unchecked Sendable, ConfigurationBackupRestoring {
    let store: ConfigurationStore

    init(store: ConfigurationStore) {
        self.store = store
    }

    func restoreValidatedBackup() async -> RepairAdapterResult {
        let provider = ReadOnlyConfigurationDiagnosticProvider(
            directoryURL: store.configurationURL.deletingLastPathComponent()
        )
        guard let facts = try? provider.inspect() else {
            return .failed
        }
        if facts.primary.state == .valid {
            return .notNeeded
        }
        guard facts.backup.state == .valid else {
            return .refused
        }

        // ConfigurationStore.load() validates the backup before promotion and
        // preserves a malformed primary as config.json.corrupt evidence.
        do {
            _ = try store.load()
            return .repaired
        } catch {
            return .failed
        }
    }
}

enum LocalPortOccupancy: Equatable, Sendable {
    case free
    case occupiedUnrelated
    case occupiedOwned(ownerID: String)
}

protocol LocalPortOccupancyChecking: Sendable {
    func inspect(port: Int) async -> LocalPortOccupancy
}

protocol CanonicalLocalPortUpdating: Sendable {
    func updateLocalMCPPort(_ port: Int) async throws
}

struct LocalPortReassignmentRequest: Equatable, Sendable {
    let currentPort: Int
    let candidatePort: Int
    let expectedOwnerID: String
    let observedOwnerID: String

    init(currentPort: Int, candidatePort: Int, expectedOwnerID: String, observedOwnerID: String) {
        self.currentPort = currentPort
        self.candidatePort = candidatePort
        self.expectedOwnerID = expectedOwnerID
        self.observedOwnerID = observedOwnerID
    }
}

struct SafeLocalPortReassigner: LocalPortReassigning {
    let request: LocalPortReassignmentRequest
    let occupancy: any LocalPortOccupancyChecking
    let configuration: any CanonicalLocalPortUpdating

    func reassignLocalPort() async -> RepairAdapterResult {
        guard request.expectedOwnerID == request.observedOwnerID,
              !request.expectedOwnerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused
        }
        guard (1...65535).contains(request.currentPort),
              (1...65535).contains(request.candidatePort) else {
            return .refused
        }
        guard request.currentPort != request.candidatePort else {
            return .notNeeded
        }
        guard case .free = await occupancy.inspect(port: request.candidatePort) else {
            // No process termination contract exists here by design. An
            // occupied candidate is never made free by killing its listener.
            return .refused
        }
        do {
            try await configuration.updateLocalMCPPort(request.candidatePort)
            return RepairAdapterResult(status: .repaired, clientReconfigurationRequired: true)
        } catch {
            return .failed
        }
    }
}

struct ConfigurationStorePortUpdater: @unchecked Sendable, CanonicalLocalPortUpdating {
    let store: ConfigurationStore

    func updateLocalMCPPort(_ port: Int) async throws {
        _ = try store.update { configuration in
            configuration.localMCPPort = port
        }
    }
}

struct LaunchAgentOwnershipFacts: Equatable, Sendable {
    let exactLabel: Bool
    let exactPath: Bool
    let exactContract: Bool
    let ownedByMacOrchestrator: Bool

    init(
        exactLabel: Bool,
        exactPath: Bool,
        exactContract: Bool,
        ownedByMacOrchestrator: Bool = true
    ) {
        self.exactLabel = exactLabel
        self.exactPath = exactPath
        self.exactContract = exactContract
        self.ownedByMacOrchestrator = ownedByMacOrchestrator
    }
}

protocol LaunchAgentOwnershipInspecting: Sendable {
    func inspect() -> LaunchAgentOwnershipFacts
}

protocol ExactLaunchAgentContractWriting: Sendable {
    func writeExactManagedContract() async -> RepairAdapterResult
}

struct ManagedLaunchAgentRepairer: LaunchAgentRepairing {
    let ownership: any LaunchAgentOwnershipInspecting
    let writer: any ExactLaunchAgentContractWriting

    func repairManagedLaunchAgent() async -> RepairAdapterResult {
        let facts = ownership.inspect()
        guard facts.exactLabel,
              facts.exactPath,
              facts.exactContract,
              facts.ownedByMacOrchestrator else {
            return .refused
        }
        return await writer.writeExactManagedContract()
    }
}

struct VerifiedBootstrapContext: Equatable, Sendable {
    let releasePinned: Bool
    let artifactVerified: Bool
    let helperOwned: Bool

    init(releasePinned: Bool, artifactVerified: Bool, helperOwned: Bool) {
        self.releasePinned = releasePinned
        self.artifactVerified = artifactVerified
        self.helperOwned = helperOwned
    }
}

struct PinnedVerifiedBootstrapHandoff: VerifiedBootstrapHandingOff {
    let context: VerifiedBootstrapContext

    func handoffVerifiedBootstrap() async -> RepairAdapterResult {
        guard context.releasePinned, context.artifactVerified, context.helperOwned else {
            return .refused
        }
        return .requiresUserAction
    }
}
