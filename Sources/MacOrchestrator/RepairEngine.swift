import Foundation
import AppKit
import Darwin

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
        self.reason = RepairOutcome.safeReason(action: action, status: status, reason: reason)
    }

    private static func safeReason(
        action: RepairActionID,
        status: RepairOutcomeStatus,
        reason: String
    ) -> String {
        guard SafeRepairReasons.allowed(
            reason,
            for: action,
            status: status
        ) else {
            return SafeRepairReasons.message(for: action, status: status, clientGuidance: false)
        }
        return String(reason.prefix(SafeRepairReasons.maximumLength))
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

enum SystemSettingsPaneURLs {
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let screenRecording = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let automation = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static func url(for pane: PermissionSettingsPane) -> URL {
        switch pane {
        case .accessibility:
            return accessibility
        case .screenRecording:
            return screenRecording
        case .automation:
            return automation
        }
    }
}

protocol SystemSettingsURLOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

struct WorkspaceSystemSettingsURLOpener: @unchecked Sendable, SystemSettingsURLOpening {
    func open(_ url: URL) async -> Bool {
        NSWorkspace.shared.open(url)
    }
}

struct SystemSettingsPermissionOpener: PermissionSettingsOpening {
    let urlOpening: any SystemSettingsURLOpening

    init(urlOpening: any SystemSettingsURLOpening = WorkspaceSystemSettingsURLOpener()) {
        self.urlOpening = urlOpening
    }

    func open(_ pane: PermissionSettingsPane) async -> RepairAdapterResult {
        let url = SystemSettingsPaneURLs.url(for: pane)
        return await urlOpening.open(url) ? .requiresUserAction : .failed
    }
}

protocol LifecycleRetrying: Sendable {
    func retry(_ target: LifecycleRepairTarget) async -> RepairAdapterResult
}

struct LifecycleOwnershipFacts: Equatable, Sendable {
    let mcpServerOwned: Bool
    let remoteConnectorOwned: Bool
}

struct OwnershipGuardedLifecycleHandoff: LifecycleRetrying {
    let ownership: LifecycleOwnershipFacts

    func retry(_ target: LifecycleRepairTarget) async -> RepairAdapterResult {
        let owned: Bool
        switch target {
        case .mcpServer:
            owned = ownership.mcpServerOwned
        case .remoteConnector:
            owned = ownership.remoteConnectorOwned
        }
        return owned ? .requiresUserAction : .refused
    }
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
        permissionSettingsOpening: (any PermissionSettingsOpening)? = SystemSettingsPermissionOpener(),
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
    static let maximumLength = 160

    static func allowed(
        _ reason: String,
        for action: RepairActionID,
        status: RepairOutcomeStatus
    ) -> Bool {
        guard reason.count <= maximumLength else { return false }
        if reason == message(for: action, status: status, clientGuidance: false) {
            return true
        }
        return action == .reassignLocalPort
            && status == .repaired
            && reason == message(for: action, status: status, clientGuidance: true)
    }

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

private enum NonFollowingPathGuard {
    static func isSafe(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { return false }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var current = URL(fileURLWithPath: "/", isDirectory: true)

        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component), isDirectory: index < components.count - 1)

            var metadata = stat()
            if lstat(current.path, &metadata) == 0 {
                let mode = UInt32(metadata.st_mode)
                if mode & UInt32(S_IFMT) == UInt32(S_IFLNK) {
                    guard VerifiedMacOSSystemAlias.isAllowed(current) else {
                        return false
                    }
                    continue
                }
                if index < components.count - 1,
                   mode & UInt32(S_IFMT) != UInt32(S_IFDIR) {
                    return false
                }
            } else if errno == ENOENT {
                // The remaining descendants cannot exist while this component is absent.
                // They may be created by an explicitly bounded repair and are rechecked after creation.
                return true
            } else {
                return false
            }
        }

        return true
    }
}

private enum VerifiedMacOSSystemAlias {
    static func isAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let expectedTarget: String
        switch path {
        case "/var":
            expectedTarget = "/private/var"
        case "/tmp":
            expectedTarget = "/private/tmp"
        default:
            return false
        }

        return url.resolvingSymlinksInPath().standardizedFileURL.path == expectedTarget
    }
}

struct ConfigurationStoreBackupRestorer: @unchecked Sendable, ConfigurationBackupRestoring {
    let store: ConfigurationStore
    let expectedOwnerID: String

    init(store: ConfigurationStore, expectedOwnerID: String) {
        self.store = store
        self.expectedOwnerID = expectedOwnerID
    }

    func restoreValidatedBackup() async -> RepairAdapterResult {
        guard !expectedOwnerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused
        }
        guard NonFollowingPathGuard.isSafe(store.configurationURL),
              NonFollowingPathGuard.isSafe(store.backupURL) else {
            return .refused
        }

        let primary = readValidatedConfiguration(at: store.configurationURL)
        let backup = readValidatedConfiguration(at: store.backupURL)
        if primary != nil {
            return .notNeeded
        }
        guard let backup else {
            return .refused
        }
        guard backup.ownerID == expectedOwnerID else {
            return .refused
        }

        // The read-only checks above establish the owner and validation boundary.
        // ConfigurationStore.load() then performs its existing recovery semantics,
        // including preserving malformed primary bytes as .corrupt evidence.
        do {
            _ = try store.load()
            return .repaired
        } catch {
            return .failed
        }
    }

    private func readValidatedConfiguration(at url: URL) -> AppConfiguration? {
        guard NonFollowingPathGuard.isSafe(url) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(AppConfiguration.self, from: data) else {
            return nil
        }
        return try? decoded.validated()
    }
}

enum LocalPortOccupancy: Equatable, Sendable {
    case free
    case occupiedUnrelated
    case occupiedOwned(ownerID: String)
    case unknown
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

    init(currentPort: Int, candidatePort: Int, expectedOwnerID: String) {
        self.currentPort = currentPort
        self.candidatePort = candidatePort
        self.expectedOwnerID = expectedOwnerID
    }
}

struct SafeLocalPortReassigner: LocalPortReassigning {
    let request: LocalPortReassignmentRequest
    let occupancy: any LocalPortOccupancyChecking
    let configuration: any CanonicalLocalPortUpdating

    func reassignLocalPort() async -> RepairAdapterResult {
        guard !request.expectedOwnerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused
        }
        guard (1...65535).contains(request.currentPort),
              (1...65535).contains(request.candidatePort) else {
            return .refused
        }
        guard request.currentPort != request.candidatePort else {
            return .refused
        }
        switch await occupancy.inspect(port: request.currentPort) {
        case let .occupiedOwned(ownerID) where ownerID == request.expectedOwnerID:
            break
        case .occupiedUnrelated:
            break
        default:
            return .refused
        }
        guard case .free = await occupancy.inspect(port: request.candidatePort) else {
            return .refused
        }
        guard case .free = await occupancy.inspect(port: request.candidatePort) else {
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
    let targetSafe: Bool
    let targetExists: Bool

    init(
        exactLabel: Bool,
        exactPath: Bool,
        exactContract: Bool,
        ownedByMacOrchestrator: Bool = false,
        targetSafe: Bool = false,
        targetExists: Bool = false
    ) {
        self.exactLabel = exactLabel
        self.exactPath = exactPath
        self.exactContract = exactContract
        self.ownedByMacOrchestrator = ownedByMacOrchestrator
            && exactLabel
            && exactPath
            && exactContract
        self.targetSafe = targetSafe
        self.targetExists = targetExists
    }

    var repairableTarget: Bool {
        ownedByMacOrchestrator || (targetSafe && (!targetExists || (exactLabel && exactPath)))
    }
}

struct ManagedLaunchAgentContract: Equatable, Sendable {
    static let label = "com.jay.mac-orchestrator"
    static let executablePath = "/Applications/Mac Orchestrator.app/Contents/MacOS/MacOrchestrator"

    let homeDirectory: URL
    let launchAgentURL: URL
    let executableURL: URL
    let launcherLogURL: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let normalizedHome = homeDirectory.standardizedFileURL
        self.homeDirectory = normalizedHome
        self.launchAgentURL = normalizedHome
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(Self.label + ".plist", isDirectory: false)
        self.executableURL = URL(fileURLWithPath: Self.executablePath)
        self.launcherLogURL = normalizedHome
            .appendingPathComponent("Library/Logs/Mac Orchestrator", isDirectory: true)
            .appendingPathComponent("launcher.log", isDirectory: false)
    }

    var propertyList: [String: Any] {
        [
            "Label": Self.label,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": launcherLogURL.path,
            "StandardErrorPath": launcherLogURL.path,
        ]
    }

    func matches(_ object: Any) -> Bool {
        guard let plist = object as? [String: Any],
              Set(plist.keys) == Set(propertyList.keys),
              plist["Label"] as? String == Self.label,
              plist["ProgramArguments"] as? [String] == [executableURL.path],
              plist["RunAtLoad"] as? Bool == true,
              plist["ThrottleInterval"] as? Int == 5,
              plist["ProcessType"] as? String == "Interactive",
              plist["LimitLoadToSessionType"] as? String == "Aqua",
              plist["StandardOutPath"] as? String == launcherLogURL.path,
              plist["StandardErrorPath"] as? String == launcherLogURL.path,
              let keepAlive = plist["KeepAlive"] as? [String: Any],
              Set(keepAlive.keys) == ["SuccessfulExit"],
              keepAlive["SuccessfulExit"] as? Bool == false else {
            return false
        }
        return true
    }

    func propertyListData() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
    }
}

protocol LaunchAgentOwnershipInspecting: Sendable {
    func inspect(_ contract: ManagedLaunchAgentContract) -> LaunchAgentOwnershipFacts
}

protocol ExactLaunchAgentContractWriting: Sendable {
    func writeExactManagedContract(_ contract: ManagedLaunchAgentContract) async -> RepairAdapterResult
}

protocol ManagedLaunchAgentReloading: Sendable {
    func reloadManagedLaunchAgent(_ contract: ManagedLaunchAgentContract) async -> RepairAdapterResult
}

struct ManagedLaunchAgentRepairer: LaunchAgentRepairing {
    let contract: ManagedLaunchAgentContract
    let ownership: any LaunchAgentOwnershipInspecting
    let writer: any ExactLaunchAgentContractWriting

    init(
        contract: ManagedLaunchAgentContract = ManagedLaunchAgentContract(),
        ownership: any LaunchAgentOwnershipInspecting,
        writer: any ExactLaunchAgentContractWriting
    ) {
        self.contract = contract
        self.ownership = ownership
        self.writer = writer
    }

    func repairManagedLaunchAgent() async -> RepairAdapterResult {
        let facts = ownership.inspect(contract)
        guard facts.repairableTarget else {
            return .refused
        }
        return await writer.writeExactManagedContract(contract)
    }
}

struct FileSystemLaunchAgentOwnershipInspector: @unchecked Sendable, LaunchAgentOwnershipInspecting {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func inspect(_ contract: ManagedLaunchAgentContract) -> LaunchAgentOwnershipFacts {
        let targetSafe = areContractPathsSafe(contract)
        let targetExists = targetSafe && fileManager.fileExists(atPath: contract.launchAgentURL.path)
        guard targetSafe, targetExists,
              let data = try? Data(contentsOf: contract.launchAgentURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return LaunchAgentOwnershipFacts(
                exactLabel: false,
                exactPath: false,
                exactContract: false,
                targetSafe: targetSafe,
                targetExists: targetExists
            )
        }
        let plist = object as? [String: Any]
        let exactLabel = plist?["Label"] as? String == ManagedLaunchAgentContract.label
        let exactPath = targetSafe
            && plist?["ProgramArguments"] as? [String] == [contract.executableURL.path]
        let exactContract = contract.matches(object)
        return LaunchAgentOwnershipFacts(
            exactLabel: exactLabel,
            exactPath: exactPath,
            exactContract: exactContract,
            ownedByMacOrchestrator: exactLabel && exactPath && exactContract,
            targetSafe: targetSafe,
            targetExists: targetExists
        )
    }

    private func areContractPathsSafe(_ contract: ManagedLaunchAgentContract) -> Bool {
        NonFollowingPathGuard.isSafe(contract.homeDirectory)
            && NonFollowingPathGuard.isSafe(contract.launchAgentURL)
            && NonFollowingPathGuard.isSafe(contract.launcherLogURL)
    }
}

struct FileSystemManagedLaunchAgentWriter: @unchecked Sendable, ExactLaunchAgentContractWriting {
    let fileManager: FileManager
    let reloader: any ManagedLaunchAgentReloading

    init(
        fileManager: FileManager = .default,
        reloader: any ManagedLaunchAgentReloading
    ) {
        self.fileManager = fileManager
        self.reloader = reloader
    }

    func writeExactManagedContract(_ contract: ManagedLaunchAgentContract) async -> RepairAdapterResult {
        let parentURL = contract.launchAgentURL.deletingLastPathComponent()
        guard areContractPathsSafe(contract) else {
            return .refused
        }
        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            guard areContractPathsSafe(contract) else {
                return .refused
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parentURL.path)
            let data = try contract.propertyListData()
            try data.write(to: contract.launchAgentURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: contract.launchAgentURL.path)
            let reloadResult = await reloader.reloadManagedLaunchAgent(contract)
            return reloadResult
        } catch {
            return .failed
        }
    }

    private func areContractPathsSafe(_ contract: ManagedLaunchAgentContract) -> Bool {
        NonFollowingPathGuard.isSafe(contract.homeDirectory)
            && NonFollowingPathGuard.isSafe(contract.launchAgentURL)
            && NonFollowingPathGuard.isSafe(contract.launcherLogURL)
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
