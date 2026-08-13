import Foundation
import Security
import Darwin

enum DiagnosticProviderError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case inaccessible
    case unreadable
    case malformed
    case unsupportedSchema
    case invalid
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The diagnostic source is unavailable."
        case .inaccessible:
            return "The diagnostic source is inaccessible."
        case .unreadable:
            return "The diagnostic source could not be read."
        case .malformed:
            return "The diagnostic source is malformed."
        case .unsupportedSchema:
            return "The diagnostic source uses an unsupported schema."
        case .invalid:
            return "The diagnostic source contains invalid values."
        case .permissionDenied:
            return "Permission was denied while inspecting the diagnostic source."
        }
    }
}

enum ConfigurationFileObservationState: String, Codable, Equatable, Sendable {
    case missing
    case readable
    case malformed
    case unsupported
    case invalid
    case valid
    case inaccessible
}

typealias ConfigurationFileState = ConfigurationFileObservationState

struct ConfigurationFileFacts: Codable, Equatable, Sendable {
    let exists: Bool
    let readable: Bool
    let valid: Bool
    let state: ConfigurationFileObservationState
    let schemaVersion: Int?
    let generation: Int?
    let mode: UInt16?
    let isSymlink: Bool
    let byteCount: Int?

    init(
        exists: Bool = false,
        readable: Bool = false,
        valid: Bool = false,
        state: ConfigurationFileObservationState = .missing,
        schemaVersion: Int? = nil,
        generation: Int? = nil,
        mode: UInt16? = nil,
        isSymlink: Bool = false,
        byteCount: Int? = nil
    ) {
        self.exists = exists
        self.readable = readable
        self.valid = valid
        self.state = state
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.mode = mode
        self.isSymlink = isSymlink
        self.byteCount = byteCount
    }
}

struct ConfigurationDiagnosticFacts: Codable, Equatable, Sendable {
    let directoryExists: Bool
    let directoryMode: UInt16?
    let directoryIsSymlink: Bool
    let directoryPathSafe: Bool
    let primary: ConfigurationFileFacts
    let backup: ConfigurationFileFacts
    let corruptEvidenceCount: Int

    init(
        directoryExists: Bool = false,
        directoryMode: UInt16? = nil,
        directoryIsSymlink: Bool = false,
        directoryPathSafe: Bool = true,
        primary: ConfigurationFileFacts = ConfigurationFileFacts(),
        backup: ConfigurationFileFacts = ConfigurationFileFacts(),
        corruptEvidenceCount: Int = 0
    ) {
        self.directoryExists = directoryExists
        self.directoryMode = directoryMode
        self.directoryIsSymlink = directoryIsSymlink
        self.directoryPathSafe = directoryPathSafe
        self.primary = primary
        self.backup = backup
        self.corruptEvidenceCount = corruptEvidenceCount
    }
}

protocol ConfigurationDiagnosticProviding {
    func inspect() throws -> ConfigurationDiagnosticFacts
}

struct ReadOnlyConfigurationDiagnosticProvider: ConfigurationDiagnosticProviding {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let decoder: JSONDecoder

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func inspect() throws -> ConfigurationDiagnosticFacts {
        let directoryMetadata = metadata(for: directoryURL)
        let primaryURL = directoryURL.appendingPathComponent("config.json", isDirectory: false)
        let backupURL = directoryURL.appendingPathComponent("config.json.backup", isDirectory: false)

        var corruptEvidenceCount = 0
        if directoryMetadata.exists && !directoryMetadata.isSymlink {
            do {
                let entries = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                corruptEvidenceCount = entries.reduce(into: 0) { count, entry in
                    if entry.lastPathComponent.hasPrefix("config.json.corrupt") {
                        count += 1
                    }
                }
            } catch {
                throw DiagnosticProviderError.inaccessible
            }
        }

        return ConfigurationDiagnosticFacts(
            directoryExists: directoryMetadata.exists,
            directoryMode: directoryMetadata.mode,
            directoryIsSymlink: directoryMetadata.isSymlink,
            directoryPathSafe: DiagnosticPathSafety.isSafe(directoryURL),
            primary: inspectFile(primaryURL),
            backup: inspectFile(backupURL),
            corruptEvidenceCount: corruptEvidenceCount
        )
    }

    private func inspectFile(_ url: URL) -> ConfigurationFileFacts {
        let fileMetadata = metadata(for: url)
        guard fileMetadata.exists else {
            return ConfigurationFileFacts()
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return ConfigurationFileFacts(
                exists: true,
                state: .inaccessible,
                mode: fileMetadata.mode,
                isSymlink: fileMetadata.isSymlink
            )
        }

        do {
            let configuration = try decoder.decode(AppConfiguration.self, from: data)
            do {
                let validated = try configuration.validated()
                return ConfigurationFileFacts(
                    exists: true,
                    readable: true,
                    valid: true,
                    state: .valid,
                    schemaVersion: validated.schemaVersion,
                    generation: validated.generation,
                    mode: fileMetadata.mode,
                    isSymlink: fileMetadata.isSymlink,
                    byteCount: data.count
                )
            } catch let error as ConfigurationValidationError {
                let state: ConfigurationFileObservationState
                if case .unsupportedSchemaVersion = error {
                    state = .unsupported
                } else {
                    state = .invalid
                }
                return ConfigurationFileFacts(
                    exists: true,
                    readable: true,
                    state: state,
                    schemaVersion: configuration.schemaVersion,
                    generation: configuration.generation,
                    mode: fileMetadata.mode,
                    isSymlink: fileMetadata.isSymlink,
                    byteCount: data.count
                )
            }
        } catch {
            return ConfigurationFileFacts(
                exists: true,
                readable: true,
                state: .malformed,
                mode: fileMetadata.mode,
                isSymlink: fileMetadata.isSymlink,
                byteCount: data.count
            )
        }
    }

    private func metadata(for url: URL) -> FileMetadata {
        var statBuffer = stat()
        guard lstat(url.path, &statBuffer) == 0 else {
            return FileMetadata()
        }

        let rawMode = UInt32(statBuffer.st_mode)
        return FileMetadata(
            exists: true,
            mode: UInt16(rawMode & 0o7777),
            isSymlink: (rawMode & UInt32(S_IFMT)) == UInt32(S_IFLNK)
        )
    }

    private struct FileMetadata {
        let exists: Bool
        let mode: UInt16?
        let isSymlink: Bool

        init(exists: Bool = false, mode: UInt16? = nil, isSymlink: Bool = false) {
            self.exists = exists
            self.mode = mode
            self.isSymlink = isSymlink
        }
    }
}

enum KeychainPresence: String, Codable, Equatable, Sendable {
    case present
    case absent
    case inaccessible
}

enum KeychainPresenceItem: String, Codable, CaseIterable, Hashable, Sendable {
    case connectorToken
    case ngrokAuthtoken
    case telegramSendBotToken
    case telegramSendChatID
    case meridianTelegramBotToken
    case meridianTelegramWebhookSecret

    var keychainItem: KeychainItem? {
        switch self {
        case .connectorToken:
            return .connectorToken
        case .ngrokAuthtoken:
            return .ngrokAuthtoken
        case .telegramSendBotToken:
            return .telegramSendBotToken
        case .telegramSendChatID:
            return .telegramSendChatID
        case .meridianTelegramBotToken:
            return .meridianTelegramBotToken
        case .meridianTelegramWebhookSecret:
            return .meridianTelegramWebhookSecret
        }
    }
}

struct KeychainPresenceQuery: Equatable, Sendable {
    let item: KeychainPresenceItem
    let service: String
    let account: String
    let requestsData: Bool

    init(item: KeychainPresenceItem, service: String, account: String, requestsData: Bool = false) {
        self.item = item
        self.service = service
        self.account = account
        self.requestsData = requestsData
    }
}

protocol KeychainPresenceQuerying {
    func query(_ request: KeychainPresenceQuery) -> KeychainPresence
}

struct SystemKeychainPresenceQuery: KeychainPresenceQuerying {
    func query(_ request: KeychainPresenceQuery) -> KeychainPresence {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: request.service,
            kSecAttrAccount as String: request.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            return .present
        }
        if status == errSecItemNotFound {
            return .absent
        }
        return .inaccessible
    }
}

struct KeychainPresenceFacts: Codable, Equatable, Sendable {
    let states: [KeychainPresenceItem: KeychainPresence]

    init(states: [KeychainPresenceItem: KeychainPresence] = [:]) {
        self.states = states
    }

    func presence(for item: KeychainPresenceItem) -> KeychainPresence? {
        states[item]
    }
}

protocol KeychainPresenceProviding {
    func inspect() throws -> KeychainPresenceFacts
}

protocol SelectiveKeychainPresenceProviding: KeychainPresenceProviding {
    func inspect(items: Set<KeychainPresenceItem>) throws -> KeychainPresenceFacts
}

struct ReadOnlySystemKeychainPresenceProvider: SelectiveKeychainPresenceProviding {
    private let querying: KeychainPresenceQuerying

    private static let currentCoreItems: [KeychainPresenceItem] = [
        .connectorToken,
        .ngrokAuthtoken,
        .telegramSendBotToken,
        .telegramSendChatID,
    ]

    init(querying: KeychainPresenceQuerying = SystemKeychainPresenceQuery()) {
        self.querying = querying
    }

    func inspect() throws -> KeychainPresenceFacts {
        try inspect(items: Set(Self.currentCoreItems))
    }

    func inspect(items: Set<KeychainPresenceItem>) throws -> KeychainPresenceFacts {
        var states = [KeychainPresenceItem: KeychainPresence]()
        for item in Self.currentCoreItems where items.contains(item) {
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

typealias SystemKeychainPresenceProvider = ReadOnlySystemKeychainPresenceProvider

struct CodeSignFacts: Codable, Equatable, Sendable {
    let bundleIdentifier: String?
    let version: String?
    let architecture: String?
    let isSigned: Bool
    let isAdHoc: Bool
    let developerIDTrusted: Bool?
    let receiptAvailable: Bool
    let integrityAvailable: Bool

    init(
        bundleIdentifier: String? = nil,
        version: String? = nil,
        architecture: String? = nil,
        isSigned: Bool = false,
        isAdHoc: Bool = false,
        developerIDTrusted: Bool? = nil,
        receiptAvailable: Bool = false,
        integrityAvailable: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.architecture = architecture
        self.isSigned = isSigned
        self.isAdHoc = isAdHoc
        self.developerIDTrusted = developerIDTrusted
        self.receiptAvailable = receiptAvailable
        self.integrityAvailable = integrityAvailable
    }
}

struct RuntimeFacts: Codable, Equatable, Sendable {
    let runtimePresent: Bool
    let architecture: String?
    let version: String?
    let markerPresent: Bool
    let payloadPresent: Bool
    let structurallyValid: Bool

    init(
        runtimePresent: Bool = false,
        architecture: String? = nil,
        version: String? = nil,
        markerPresent: Bool = false,
        payloadPresent: Bool = false,
        structurallyValid: Bool = false
    ) {
        self.runtimePresent = runtimePresent
        self.architecture = architecture
        self.version = version
        self.markerPresent = markerPresent
        self.payloadPresent = payloadPresent
        self.structurallyValid = structurallyValid
    }
}

struct InstalledReleaseFacts: Codable, Equatable, Sendable {
    let releaseVersion: String?
    let helper: CodeSignFacts
    let runtime: RuntimeFacts
    let helperPresent: Bool
    let ownershipMarkerPresent: Bool

    init(
        releaseVersion: String? = nil,
        helper: CodeSignFacts = CodeSignFacts(),
        runtime: RuntimeFacts = RuntimeFacts(),
        helperPresent: Bool = false,
        ownershipMarkerPresent: Bool = false
    ) {
        self.releaseVersion = releaseVersion
        self.helper = helper
        self.runtime = runtime
        self.helperPresent = helperPresent
        self.ownershipMarkerPresent = ownershipMarkerPresent
    }
}

protocol InstalledReleaseFactsProviding {
    func inspect() throws -> InstalledReleaseFacts
}

struct PermissionFacts: Codable, Equatable, Sendable {
    let accessibility: Bool
    let screenRecording: Bool
    let automation: Bool
    let activeConsole: Bool
    let sessionLocked: Bool
    let requesterIsManagedRuntime: Bool

    init(
        accessibility: Bool = false,
        screenRecording: Bool = false,
        automation: Bool = false,
        activeConsole: Bool = false,
        sessionLocked: Bool = false,
        requesterIsManagedRuntime: Bool = false
    ) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.automation = automation
        self.activeConsole = activeConsole
        self.sessionLocked = sessionLocked
        self.requesterIsManagedRuntime = requesterIsManagedRuntime
    }
}

protocol PermissionFactsProviding {
    func inspect() throws -> PermissionFacts
}

struct PortFacts: Codable, Equatable, Sendable {
    let port: Int
    let inspectionAvailable: Bool
    let listenerPresent: Bool
    let listenerOwned: Bool
    let listenerPID: Int32?
    let pidReuseDetected: Bool

    init(
        port: Int = 0,
        inspectionAvailable: Bool = true,
        listenerPresent: Bool = false,
        listenerOwned: Bool = false,
        listenerPID: Int32? = nil,
        pidReuseDetected: Bool = false
    ) {
        self.port = port
        self.inspectionAvailable = inspectionAvailable
        self.listenerPresent = listenerPresent
        self.listenerOwned = listenerOwned
        self.listenerPID = listenerPID
        self.pidReuseDetected = pidReuseDetected
    }
}

protocol PortFactsProviding {
    func inspect() throws -> PortFacts
}

struct LifecycleFacts: Codable, Equatable, Sendable {
    let serverDesired: Bool
    let remoteDesired: Bool
    let launchAgentPresent: Bool
    let launchAgentValid: Bool
    let serviceRunning: Bool
    let ownedProcessCount: Int
    let serverPID: Int32?
    let tunnelPID: Int32?
    let ownershipMarkerPresent: Bool
    let duplicateOwnedProcesses: Bool
    let duplicateHelperInstances: Bool
    let pidReuseDetected: Bool

    init(
        serverDesired: Bool = true,
        remoteDesired: Bool = true,
        launchAgentPresent: Bool = false,
        launchAgentValid: Bool = false,
        serviceRunning: Bool = false,
        ownedProcessCount: Int = 0,
        serverPID: Int32? = nil,
        tunnelPID: Int32? = nil,
        ownershipMarkerPresent: Bool = false,
        duplicateOwnedProcesses: Bool = false,
        duplicateHelperInstances: Bool = false,
        pidReuseDetected: Bool = false
    ) {
        self.serverDesired = serverDesired
        self.remoteDesired = remoteDesired
        self.launchAgentPresent = launchAgentPresent
        self.launchAgentValid = launchAgentValid
        self.serviceRunning = serviceRunning
        self.ownedProcessCount = ownedProcessCount
        self.serverPID = serverPID
        self.tunnelPID = tunnelPID
        self.ownershipMarkerPresent = ownershipMarkerPresent
        self.duplicateOwnedProcesses = duplicateOwnedProcesses
        self.duplicateHelperInstances = duplicateHelperInstances
        self.pidReuseDetected = pidReuseDetected
    }
}

protocol LifecycleFactsProviding {
    func inspect() throws -> LifecycleFacts
}

struct LocalMCPFacts: Codable, Equatable, Sendable {
    let livenessVerified: Bool
    let readinessVerified: Bool
    let sessionEstablished: Bool
    let safeCallSucceeded: Bool
    let expectedTools: Set<String>
    let exposedTools: Set<String>
    let expectedCapabilityGroups: Set<String>
    let exposedCapabilityGroups: Set<String>

    init(
        livenessVerified: Bool = false,
        readinessVerified: Bool = false,
        sessionEstablished: Bool = false,
        safeCallSucceeded: Bool = false,
        expectedTools: Set<String> = [],
        exposedTools: Set<String> = [],
        expectedCapabilityGroups: Set<String> = [],
        exposedCapabilityGroups: Set<String> = []
    ) {
        self.livenessVerified = livenessVerified
        self.readinessVerified = readinessVerified
        self.sessionEstablished = sessionEstablished
        self.safeCallSucceeded = safeCallSucceeded
        self.expectedTools = expectedTools
        self.exposedTools = exposedTools
        self.expectedCapabilityGroups = expectedCapabilityGroups
        self.exposedCapabilityGroups = exposedCapabilityGroups
    }
}

protocol LocalMCPDiagnosticProviding {
    func inspect() throws -> LocalMCPFacts
}

struct RemoteConnectorFacts: Codable, Equatable, Sendable {
    let desired: Bool
    let binaryPresent: Bool
    let binaryArchitecture: String?
    let originalVendorSigning: Bool?
    let configurationPresent: Bool
    let endpointAvailable: Bool
    let endpointCount: Int
    let ownershipMarkerPresent: Bool

    init(
        desired: Bool = false,
        binaryPresent: Bool = false,
        configurationPresent: Bool = false,
        endpointAvailable: Bool = false,
        endpointCount: Int = 0,
        ownershipMarkerPresent: Bool = false,
        binaryArchitecture: String? = nil,
        originalVendorSigning: Bool? = nil
    ) {
        self.desired = desired
        self.binaryPresent = binaryPresent
        self.binaryArchitecture = binaryArchitecture
        self.originalVendorSigning = originalVendorSigning
        self.configurationPresent = configurationPresent
        self.endpointAvailable = endpointAvailable
        self.endpointCount = endpointCount
        self.ownershipMarkerPresent = ownershipMarkerPresent
    }
}

struct LogDirectoryFacts: Codable, Equatable, Sendable {
    let inspectionAvailable: Bool
    let exists: Bool
    let isDirectory: Bool
    let pathSafe: Bool
    let mode: UInt16?

    init(
        inspectionAvailable: Bool = false,
        exists: Bool = false,
        isDirectory: Bool = false,
        pathSafe: Bool = true,
        mode: UInt16? = nil
    ) {
        self.inspectionAvailable = inspectionAvailable
        self.exists = exists
        self.isDirectory = isDirectory
        self.pathSafe = pathSafe
        self.mode = mode
    }
}

protocol LogDirectoryPermissionsProviding {
    func inspect() throws -> LogDirectoryFacts
}

struct ReadOnlyLogDirectoryPermissionsProvider: LogDirectoryPermissionsProviding {
    let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func inspect() throws -> LogDirectoryFacts {
        guard DiagnosticPathSafety.isSafe(directoryURL) else {
            return LogDirectoryFacts(inspectionAvailable: true, exists: true, pathSafe: false)
        }
        var metadata = stat()
        guard lstat(directoryURL.path, &metadata) == 0 else {
            if errno == ENOENT {
                return LogDirectoryFacts(inspectionAvailable: true)
            }
            return LogDirectoryFacts()
        }
        let rawMode = UInt32(metadata.st_mode)
        return LogDirectoryFacts(
            inspectionAvailable: true,
            exists: true,
            isDirectory: rawMode & UInt32(S_IFMT) == UInt32(S_IFDIR),
            pathSafe: rawMode & UInt32(S_IFMT) != UInt32(S_IFLNK),
            mode: UInt16(rawMode & 0o7777)
        )
    }
}

protocol RemoteConnectorFactsProviding {
    func inspect() throws -> RemoteConnectorFacts
}

struct DiskSpaceFacts: Codable, Equatable, Sendable {
    let filesystemAccessible: Bool
    let availableBytes: Int64?
    let thresholdBytes: Int64?
    let criticalPathSymlinkCount: Int

    init(
        filesystemAccessible: Bool = false,
        availableBytes: Int64? = nil,
        thresholdBytes: Int64? = nil,
        criticalPathSymlinkCount: Int = 0
    ) {
        self.filesystemAccessible = filesystemAccessible
        self.availableBytes = availableBytes
        self.thresholdBytes = thresholdBytes
        self.criticalPathSymlinkCount = criticalPathSymlinkCount
    }
}

protocol DiskSpaceProviding {
    func inspect() throws -> DiskSpaceFacts
}

enum UpdateAvailability: String, Codable, Equatable, Sendable {
    case available
    case current
    case unavailable
}

struct UpdateAvailabilityFacts: Codable, Equatable, Sendable {
    let status: UpdateAvailability
    let currentVersion: String?
    let availableVersion: String?
    let inspectionFailed: Bool

    init(
        status: UpdateAvailability = .unavailable,
        currentVersion: String? = nil,
        availableVersion: String? = nil,
        inspectionFailed: Bool = false
    ) {
        self.status = status
        self.currentVersion = currentVersion
        self.availableVersion = availableVersion
        self.inspectionFailed = inspectionFailed
    }
}

protocol UpdateAvailabilityProviding {
    func inspect() throws -> UpdateAvailabilityFacts
}

enum DiagnosticPathSafety {
    static func isSafe(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/"), path != "/tmp" else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component), isDirectory: index < components.count - 1)
            var metadata = stat()
            if lstat(current.path, &metadata) == 0 {
                let mode = UInt32(metadata.st_mode)
                if mode & UInt32(S_IFMT) == UInt32(S_IFLNK) {
                    guard VerifiedMacOSSystemAlias.isAllowed(current) else { return false }
                    continue
                }
                if index < components.count - 1, mode & UInt32(S_IFMT) != UInt32(S_IFDIR) {
                    return false
                }
            } else if errno != ENOENT {
                return false
            }
        }
        return true
    }
}

enum VerifiedMacOSSystemAlias {
    static func isAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let visiblePath: String
        let targetPath: String
        switch path {
        case "/var", "/private/var":
            visiblePath = "/var"
            targetPath = "/private/var"
        case "/tmp", "/private/tmp":
            visiblePath = "/tmp"
            targetPath = "/private/tmp"
        default:
            return false
        }

        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        let mode = UInt32(metadata.st_mode) & UInt32(S_IFMT)
        if mode == UInt32(S_IFLNK) {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path),
                  destination == targetPath || destination == String(targetPath.dropFirst()) else {
                return false
            }
            var targetMetadata = stat()
            return lstat(targetPath, &targetMetadata) == 0
                && UInt32(targetMetadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR)
        }
        return mode == UInt32(S_IFDIR) && (path == visiblePath || path == targetPath)
    }
}
