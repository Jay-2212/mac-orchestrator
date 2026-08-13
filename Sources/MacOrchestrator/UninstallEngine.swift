import Darwin
import Foundation

enum RemovalKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case application
    case ownedProcesses
    case managedRuntime
    case managedRemote
    case caches
    case logsAndSupport
    case supportArtifacts
    case launchAgent
    case configuration
}

enum RemovalIntent: String, Codable, Equatable, Sendable {
    case retain
    case remove
    case notPresent
    case manualActionRequired
}

enum UninstallOutcomeStatus: String, Codable, Equatable, Sendable {
    case removed
    case retained
    case notPresent
    case failedManualActionRequired
}

struct RemovalOptions: Codable, Equatable, Sendable {
    var removeApplication: Bool
    var removeOwnedProcesses: Bool
    var removeManagedRuntime: Bool
    var removeManagedRemote: Bool
    var removeCaches: Bool
    var removeLogsAndSupport: Bool
    var removeLaunchAgent: Bool
    var removeConfiguration: Bool
    var deleteCredentials: Bool

    init(
        removeApplication: Bool = false,
        removeOwnedProcesses: Bool = false,
        removeManagedRuntime: Bool = false,
        removeManagedRemote: Bool = false,
        removeCaches: Bool = false,
        removeLogsAndSupport: Bool = false,
        removeLaunchAgent: Bool = false,
        removeConfiguration: Bool = false,
        deleteCredentials: Bool = false
    ) {
        self.removeApplication = removeApplication
        self.removeOwnedProcesses = removeOwnedProcesses
        self.removeManagedRuntime = removeManagedRuntime
        self.removeManagedRemote = removeManagedRemote
        self.removeCaches = removeCaches
        self.removeLogsAndSupport = removeLogsAndSupport
        self.removeLaunchAgent = removeLaunchAgent
        self.removeConfiguration = removeConfiguration
        self.deleteCredentials = deleteCredentials
    }
}

struct RemovalPlanEntry: Codable, Equatable, Sendable {
    let kind: RemovalKind
    let relativePath: String
    let intent: RemovalIntent
    let reason: String?
}

struct RemovalPlan: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let entries: [RemovalPlanEntry]
    let keychainItemsToDelete: [KeychainItem]
    let providerResourcesUntouched: Bool
    let servicesRemainQuiesced: Bool
}

struct UninstallOutcome: Codable, Equatable, Sendable {
    let kind: RemovalKind
    let relativePath: String
    let status: UninstallOutcomeStatus
    let detail: String?
}

struct UninstallReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let planID: UUID
    let completedAt: Date
    let outcomes: [UninstallOutcome]
    let keychainItemsDeleted: [String]
    let providerResourcesUntouched: Bool

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

enum UninstallError: Error, Equatable, LocalizedError, Sendable {
    case invalidRoot
    case rootOwnershipNotProven
    case rootIsSymlink
    case processOwnershipNotProven

    var errorDescription: String? {
        switch self {
        case .invalidRoot: return "The uninstall project-owned root is invalid."
        case .rootOwnershipNotProven: return "Ownership of the uninstall project-owned root could not be proven."
        case .rootIsSymlink: return "The uninstall project-owned root must not be a symlink."
        case .processOwnershipNotProven: return "Owned process termination was not authorized by a current ownership proof."
        }
    }
}

protocol OwnedProcessRemovalAdapter {
    func removeOwnedProcesses() throws
}

struct NoOwnedProcessRemovalAdapter: OwnedProcessRemovalAdapter {
    func removeOwnedProcesses() throws {
        throw UninstallError.processOwnershipNotProven
    }
}

struct UninstallPathValidator {
    let fileManager: FileManager
    let ownerID: UInt32
    let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        ownerID: UInt32 = getuid(),
        homeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.ownerID = ownerID
        self.homeDirectory = (homeDirectory ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
    }

    func validateRoot(_ root: URL) throws {
        guard root.isFileURL,
              root.path.hasPrefix("/"),
              root.path != "/",
              root.standardizedFileURL != homeDirectory else {
            throw UninstallError.invalidRoot
        }
        let broadLibrary = homeDirectory.appendingPathComponent("Library", isDirectory: true).standardizedFileURL
        let broadApplicationSupport = broadLibrary.appendingPathComponent("Application Support", isDirectory: true).standardizedFileURL
        guard root.standardizedFileURL != broadLibrary,
              root.standardizedFileURL != broadApplicationSupport,
              let attributes = try? fileManager.attributesOfItem(atPath: root.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeDirectory else {
            throw UninstallError.invalidRoot
        }
        guard !isSymlink(root) else { throw UninstallError.rootIsSymlink }
        guard isOwned(root) else { throw UninstallError.rootOwnershipNotProven }
    }

    /// Validates a known product-owned path whose parent is outside the
    /// Application Support tree. The path must equal the expected production
    /// location; callers cannot turn arbitrary configuration into a deletion
    /// root.
    func safeKnownPath(_ path: URL, expected: URL, directory: Bool) -> Bool {
        let normalizedPath = path.standardizedFileURL
        let normalizedExpected = expected.standardizedFileURL
        guard normalizedPath == normalizedExpected,
              normalizedPath.path.hasPrefix(homeDirectory.path + "/"),
              !isSymlink(homeDirectory),
              isOwned(homeDirectory) else { return false }

        var current = homeDirectory
        let relative = String(normalizedExpected.path.dropFirst(homeDirectory.path.count))
            .split(separator: "/")
        for component in relative {
            current.appendPathComponent(String(component), isDirectory: false)
            guard !isSymlink(current) else { return false }
            if fileManager.fileExists(atPath: current.path), !isOwned(current) { return false }
        }
        guard fileManager.fileExists(atPath: normalizedExpected.path) else { return true }
        return isExpectedTarget(normalizedExpected, directory: directory)
            && isOwnedProjectTree(normalizedExpected)
    }

    func safeRemovalPath(_ path: URL, inside root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let pathPath = path.standardizedFileURL.path
        guard pathPath != rootPath,
              pathPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            return false
        }

        // Validate the nearest existing container as well as every path
        // component. This keeps a missing-but-owned root safe while rejecting
        // symlinked or non-owned containers before any recursive removal.
        var container = root.standardizedFileURL
        while container.path != "/" && !fileManager.fileExists(atPath: container.path) {
            guard !isSymlink(container) else { return false }
            container.deleteLastPathComponent()
        }
        guard container.path != "/", !isSymlink(container), isOwned(container) else {
            return false
        }

        var current = root
        let relative = String(pathPath.dropFirst(rootPath.count)).split(separator: "/")
        for component in relative {
            current.appendPathComponent(String(component), isDirectory: false)
            if isSymlink(current) { return false }
            if fileManager.fileExists(atPath: current.path), !isOwned(current) { return false }
        }
        return !fileManager.fileExists(atPath: path.path) || isOwnedProjectTree(path)
    }

    func isExpectedTarget(_ path: URL, directory: Bool) -> Bool {
        guard fileManager.fileExists(atPath: path.path), !isSymlink(path),
              let attributes = try? fileManager.attributesOfItem(atPath: path.path),
              let type = attributes[.type] as? FileAttributeType else {
            return !fileManager.fileExists(atPath: path.path)
        }
        return directory ? type == .typeDirectory : type == .typeRegular
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func isOwned(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let value = attributes[.ownerAccountID] as? NSNumber else {
            return false
        }
        return value.uint32Value == ownerID
    }

    private func isOwnedProjectTree(_ root: URL) -> Bool {
        guard isOwned(root), !isSymlink(root),
              let attributes = try? fileManager.attributesOfItem(atPath: root.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        guard type == .typeDirectory else { return type == .typeRegular }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        for case let item as URL in enumerator {
            guard !isSymlink(item), isOwned(item),
                  let itemAttributes = try? fileManager.attributesOfItem(atPath: item.path),
                  let itemType = itemAttributes[.type] as? FileAttributeType,
                  itemType == .typeDirectory || itemType == .typeRegular else {
                return false
            }
        }
        return true
    }
}

final class UninstallEngine {
    let supportDirectory: URL
    let logsDirectory: URL
    let homeDirectory: URL
    private let keychain: KeychainStore
    private let lifecycle: MaintenanceLifecycleAdapter
    private let fileManager: FileManager
    private let pathValidator: UninstallPathValidator
    private let faultInjector: MaintenanceFaultInjector
    private let processRemoval: OwnedProcessRemovalAdapter
    private let launchAgentURL: URL
    private let uninstallReceiptURL: URL

    init(
        supportDirectory: URL,
        logsDirectory: URL,
        keychain: KeychainStore,
        lifecycle: MaintenanceLifecycleAdapter,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        faultInjector: MaintenanceFaultInjector = NoMaintenanceFaultInjector(),
        processRemoval: OwnedProcessRemovalAdapter = NoOwnedProcessRemovalAdapter(),
        launchAgentURL: URL? = nil
    ) throws {
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.logsDirectory = logsDirectory.standardizedFileURL
        self.homeDirectory = (homeDirectory ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
        self.keychain = keychain
        self.lifecycle = lifecycle
        self.fileManager = fileManager
        self.pathValidator = UninstallPathValidator(fileManager: fileManager, homeDirectory: self.homeDirectory)
        self.faultInjector = faultInjector
        self.processRemoval = processRemoval
        self.launchAgentURL = (launchAgentURL ?? self.homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.jay.mac-orchestrator.plist", isDirectory: false)).standardizedFileURL
        self.uninstallReceiptURL = self.supportDirectory
            .appendingPathComponent("install", isDirectory: true)
            .appendingPathComponent("uninstall-receipt.json", isDirectory: false)
        try pathValidator.validateRoot(self.supportDirectory)
        let expectedLaunchAgentURL = self.homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.jay.mac-orchestrator.plist", isDirectory: false)
            .standardizedFileURL
        let expectedLogsDirectory = self.homeDirectory
            .appendingPathComponent("Library/Logs/Mac Orchestrator", isDirectory: true)
            .standardizedFileURL
        guard self.launchAgentURL == expectedLaunchAgentURL else {
            throw UninstallError.invalidRoot
        }
        guard pathValidator.safeKnownPath(self.logsDirectory, expected: expectedLogsDirectory, directory: true) else {
            throw UninstallError.invalidRoot
        }
        guard pathValidator.safeKnownPath(self.launchAgentURL, expected: expectedLaunchAgentURL, directory: false) else {
            throw UninstallError.invalidRoot
        }
    }

    func plan(options: RemovalOptions) throws -> RemovalPlan {
        let appURL = supportDirectory.appendingPathComponent("app", isDirectory: true)
        let runtimeURL = supportDirectory.appendingPathComponent("runtime", isDirectory: true)
        let remoteURL = supportDirectory.appendingPathComponent("remote", isDirectory: true)
        let cachesURL = supportDirectory.appendingPathComponent("caches", isDirectory: true)
        let configurationURL = supportDirectory.appendingPathComponent("config.json", isDirectory: false)
        let entries = [
            makeEntry(kind: .application, url: appURL, relativePath: "app", remove: options.removeApplication),
            makeEntry(
                kind: .ownedProcesses,
                url: supportDirectory.appendingPathComponent("owned-processes.json", isDirectory: false),
                relativePath: "owned-processes.json",
                remove: options.removeOwnedProcesses
            ),
            makeEntry(kind: .managedRuntime, url: runtimeURL, relativePath: "runtime", remove: options.removeManagedRuntime),
            makeEntry(kind: .managedRemote, url: remoteURL, relativePath: "remote", remove: options.removeManagedRemote),
            makeEntry(kind: .caches, url: cachesURL, relativePath: "caches", remove: options.removeCaches),
            makeEntry(kind: .logsAndSupport, url: logsDirectory, relativePath: relativePath(of: logsDirectory), remove: options.removeLogsAndSupport),
            makeEntry(
                kind: .supportArtifacts,
                url: supportDirectory.appendingPathComponent("install", isDirectory: true),
                relativePath: "install",
                remove: options.removeLogsAndSupport
            ),
            makeEntry(kind: .configuration, url: configurationURL, relativePath: "config.json", remove: options.removeConfiguration),
            makeEntry(kind: .launchAgent, url: launchAgentURL, relativePath: "LaunchAgents/com.jay.mac-orchestrator.plist", remove: options.removeLaunchAgent),
        ]
        let keychainItems: [KeychainItem] = options.deleteCredentials ? [
            .connectorToken,
            .ngrokAuthtoken,
            .telegramSendBotToken,
            .telegramSendChatID,
            .currentMeridianIngestToken,
            .meridianIngestTokenAlias,
            .meridianTelegramBotToken,
            .meridianTelegramWebhookSecret,
        ] : []
        let terminalKinds: Set<RemovalKind> = [
            .application, .ownedProcesses, .managedRuntime, .managedRemote,
            .supportArtifacts, .configuration, .launchAgent,
        ]
        let servicesRemainQuiesced = entries.contains { entry in
            entry.intent == .remove && terminalKinds.contains(entry.kind)
        } || !keychainItems.isEmpty
        return RemovalPlan(
            id: UUID(),
            createdAt: Date(),
            entries: entries,
            keychainItemsToDelete: keychainItems,
            providerResourcesUntouched: true,
            servicesRemainQuiesced: servicesRemainQuiesced
        )
    }

    func apply(_ plan: RemovalPlan) -> UninstallReceipt {
        var outcomes: [UninstallOutcome] = []
        var deletedKeychainItems: [String] = []
        let destructiveEntries = plan.entries.filter { $0.intent == .remove }
        var servicesQuiesced = false

        let requiresMaintenanceQuiesce = !destructiveEntries.isEmpty
            || !plan.keychainItemsToDelete.isEmpty

        if requiresMaintenanceQuiesce {
            do {
                _ = try lifecycle.quiesce()
                servicesQuiesced = true
            } catch {
                let detail = "Maintenance could not be quiesced: \(error.localizedDescription)"
                outcomes.append(contentsOf: plan.entries.map { entry in
                    switch entry.intent {
                    case .remove:
                        return UninstallOutcome(
                            kind: entry.kind,
                            relativePath: entry.relativePath,
                            status: .failedManualActionRequired,
                            detail: detail
                        )
                    case .retain:
                        return UninstallOutcome(kind: entry.kind, relativePath: entry.relativePath, status: .retained, detail: nil)
                    case .notPresent:
                        return UninstallOutcome(kind: entry.kind, relativePath: entry.relativePath, status: .notPresent, detail: nil)
                    case .manualActionRequired:
                        return UninstallOutcome(kind: entry.kind, relativePath: entry.relativePath, status: .failedManualActionRequired, detail: entry.reason)
                    }
                })
                outcomes.append(contentsOf: plan.keychainItemsToDelete.map {
                    UninstallOutcome(
                        kind: .configuration,
                        relativePath: "Keychain/\($0.key)",
                        status: .failedManualActionRequired,
                        detail: "Credential deletion was not attempted because maintenance could not be quiesced."
                    )
                })
            }
        }

        if outcomes.isEmpty {
            for entry in plan.entries {
                switch entry.intent {
                case .retain:
                    outcomes.append(UninstallOutcome(kind: entry.kind, relativePath: entry.relativePath, status: .retained, detail: nil))
                case .notPresent:
                    outcomes.append(UninstallOutcome(kind: entry.kind, relativePath: entry.relativePath, status: .notPresent, detail: nil))
                case .manualActionRequired:
                    outcomes.append(UninstallOutcome(kind: entry.kind, relativePath: entry.relativePath, status: .failedManualActionRequired, detail: entry.reason))
                case .remove:
                    do {
                        try faultInjector.check(.uninstallBeforeRemoval)
                        if entry.kind == .ownedProcesses {
                            try processRemoval.removeOwnedProcesses()
                            try faultInjector.check(.uninstallAfterRemoval)
                            outcomes.append(UninstallOutcome(kind: entry.kind, relativePath: entry.relativePath, status: .removed, detail: nil))
                            continue
                        }
                        let url = url(for: entry)
                        guard safeRemovalPath(for: entry, url: url) else {
                            throw UninstallError.invalidRoot
                        }
                        if entry.kind == .launchAgent {
                            try lifecycle.removeManagedLaunchAgent()
                        }
                        if fileManager.fileExists(atPath: url.path) {
                            try fileManager.removeItem(at: url)
                            try faultInjector.check(.uninstallAfterRemoval)
                            outcomes.append(UninstallOutcome(kind: entry.kind, relativePath: entry.relativePath, status: .removed, detail: nil))
                        } else {
                            outcomes.append(UninstallOutcome(kind: entry.kind, relativePath: entry.relativePath, status: .notPresent, detail: nil))
                        }
                    } catch {
                        outcomes.append(UninstallOutcome(kind: entry.kind, relativePath: entry.relativePath, status: .failedManualActionRequired, detail: error.localizedDescription))
                    }
                }
            }
        }

        if plan.keychainItemsToDelete.isEmpty {
            // No credential deletion is the deliberate default.
        } else if outcomes.allSatisfy({ $0.status != .failedManualActionRequired }) {
            for item in plan.keychainItemsToDelete {
                do {
                    try keychain.delete(item)
                    deletedKeychainItems.append(item.key)
                } catch {
                    outcomes.append(UninstallOutcome(
                        kind: .configuration,
                        relativePath: "Keychain/\(item.key)",
                        status: .failedManualActionRequired,
                        detail: "Keychain item could not be deleted: \(error.localizedDescription)"
                    ))
                }
            }
        }

        if servicesQuiesced && !plan.servicesRemainQuiesced {
            do { try lifecycle.restore() } catch {
                outcomes.append(UninstallOutcome(
                    kind: .launchAgent,
                    relativePath: "maintenance",
                    status: .failedManualActionRequired,
                    detail: "Maintenance restore failed: \(error.localizedDescription)"
                ))
            }
        }

        let receipt = UninstallReceipt(
            schemaVersion: 1,
            planID: plan.id,
            completedAt: Date(),
            outcomes: outcomes,
            keychainItemsDeleted: deletedKeychainItems.sorted(),
            providerResourcesUntouched: true
        )
        do {
            try writeReceipt(receipt)
            return receipt
        } catch {
            return UninstallReceipt(
                schemaVersion: receipt.schemaVersion,
                planID: receipt.planID,
                completedAt: receipt.completedAt,
                outcomes: receipt.outcomes + [UninstallOutcome(
                    kind: .supportArtifacts,
                    relativePath: "install/uninstall-receipt.json",
                    status: .failedManualActionRequired,
                    detail: "The uninstall completed, but its receipt could not be stored safely."
                )],
                keychainItemsDeleted: receipt.keychainItemsDeleted,
                providerResourcesUntouched: receipt.providerResourcesUntouched
            )
        }
    }

    private func makeEntry(kind: RemovalKind, url: URL, relativePath: String, remove: Bool) -> RemovalPlanEntry {
        guard fileManager.fileExists(atPath: url.path) else {
            return RemovalPlanEntry(
                kind: kind,
                relativePath: relativePath,
                intent: remove ? .notPresent : .retain,
                reason: nil
            )
        }
        guard safeRemovalPath(for: kind, url: url),
              pathValidator.isExpectedTarget(url, directory: expectsDirectory(kind)) else {
            return RemovalPlanEntry(kind: kind, relativePath: relativePath, intent: .manualActionRequired, reason: "Path is outside the project-owned root, symlinked, or not owned by the current user.")
        }
        return RemovalPlanEntry(kind: kind, relativePath: relativePath, intent: remove ? .remove : .retain, reason: nil)
    }

    private func url(for entry: RemovalPlanEntry) -> URL {
        switch entry.kind {
        case .application: return supportDirectory.appendingPathComponent("app", isDirectory: true)
        case .ownedProcesses: return supportDirectory.appendingPathComponent("owned-processes.json", isDirectory: false)
        case .managedRuntime: return supportDirectory.appendingPathComponent("runtime", isDirectory: true)
        case .managedRemote: return supportDirectory.appendingPathComponent("remote", isDirectory: true)
        case .caches: return supportDirectory.appendingPathComponent("caches", isDirectory: true)
        case .logsAndSupport: return logsDirectory
        case .supportArtifacts: return supportDirectory.appendingPathComponent("install", isDirectory: true)
        case .configuration: return supportDirectory.appendingPathComponent("config.json", isDirectory: false)
        case .launchAgent: return launchAgentURL
        }
    }

    private func safeRemovalPath(for entry: RemovalPlanEntry, url: URL) -> Bool {
        safeRemovalPath(for: entry.kind, url: url)
    }

    private func safeRemovalPath(for kind: RemovalKind, url: URL) -> Bool {
        if kind == .launchAgent {
            return pathValidator.safeKnownPath(url, expected: launchAgentURL, directory: false)
        }
        if kind == .logsAndSupport {
            let expected = homeDirectory.appendingPathComponent("Library/Logs/Mac Orchestrator", isDirectory: true)
            return pathValidator.safeKnownPath(url, expected: expected, directory: true)
        }
        return pathValidator.safeRemovalPath(url, inside: supportDirectory)
    }

    private func expectsDirectory(_ kind: RemovalKind) -> Bool {
        switch kind {
        case .application, .managedRuntime, .managedRemote, .caches, .logsAndSupport, .supportArtifacts:
            return true
        case .launchAgent, .configuration, .ownedProcesses:
            return false
        }
    }

    private func relativePath(of url: URL) -> String {
        let root = supportDirectory.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        if path.hasPrefix(homeDirectory.path + "/") {
            return "~/" + String(path.dropFirst(homeDirectory.path.count + 1))
        }
        return url.lastPathComponent
    }

    private func writeReceipt(_ receipt: UninstallReceipt) throws {
        guard pathValidator.safeRemovalPath(uninstallReceiptURL, inside: supportDirectory) else {
            throw UninstallError.invalidRoot
        }
        let directory = uninstallReceiptURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard pathValidator.safeRemovalPath(uninstallReceiptURL, inside: supportDirectory) else {
            throw UninstallError.invalidRoot
        }
        let temporary = directory.appendingPathComponent(".uninstall-receipt.\(UUID().uuidString).tmp")
        guard !isSymlink(temporary), !isSymlink(uninstallReceiptURL) else {
            throw UninstallError.invalidRoot
        }
        try receipt.encoded().write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: uninstallReceiptURL.path) {
            _ = try fileManager.replaceItemAt(uninstallReceiptURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: uninstallReceiptURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: uninstallReceiptURL.path)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
