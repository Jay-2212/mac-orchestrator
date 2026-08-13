import Foundation
import Darwin

struct SupportBundleRedactionSummary: Codable, Equatable, Sendable {
    let appliedTransforms: [String]
    let excludedSensitiveCategories: [String]

    init(
        appliedTransforms: [String] = [
            "exact-secret-replacement",
            "connector-url-and-route-redaction",
            "structured-secret-field-redaction",
            "home-path-normalization"
        ],
        excludedSensitiveCategories: [String] = [
            "api-keys",
            "authorization",
            "bot-token",
            "chat-id",
            "credentials",
            "keychain-values",
            "clipboard",
            "user-documents",
            "shell-history",
            "shell-browser-data",
            "browser-data",
            "connector-url",
            "connector-token",
            "ngrok-credentials",
            "request-response-bodies",
            "mcp-request-response-bodies",
            "secret-material",
            "telegram-bot-secret",
            "telegram-bot-token",
            "telegram-chat-id",
            "telegram-secret"
        ]
    ) {
        self.appliedTransforms = appliedTransforms.sorted()
        self.excludedSensitiveCategories = excludedSensitiveCategories.sorted()
    }
}

struct SupportBundleEntryPlan: Codable, Equatable, Sendable {
    let sourceID: String
    let logicalID: String
    let archivePath: String
    let category: String
    let reason: String
    let expectedRedaction: String
    let approximateSizeBytes: Int?

    init(
        sourceID: String,
        logicalID: String,
        archivePath: String,
        category: String,
        reason: String,
        expectedRedaction: String,
        approximateSizeBytes: Int? = nil
    ) {
        self.sourceID = sourceID
        self.logicalID = logicalID
        self.archivePath = archivePath
        self.category = category
        self.reason = reason
        self.expectedRedaction = expectedRedaction
        self.approximateSizeBytes = approximateSizeBytes
    }
}

enum SupportBundleSelectionError: Error, Equatable, LocalizedError, Sendable {
    case unknownLogicalIDs([String])

    var errorDescription: String? {
        switch self {
        case .unknownLogicalIDs:
            return "Support-bundle selection contains an unknown logical entry."
        }
    }
}

struct SupportBundlePlan: Codable, Equatable, Sendable {
    let planIdentifier: String
    let generatedAt: Date
    let entries: [SupportBundleEntryPlan]
    let excludedSensitiveCategories: [String]
    let redactionSummary: SupportBundleRedactionSummary
    let selectedLogicalIDs: [String]?
    let catalogFingerprint: String

    init(
        planIdentifier: String,
        generatedAt: Date,
        entries: [SupportBundleEntryPlan],
        excludedSensitiveCategories: [String],
        redactionSummary: SupportBundleRedactionSummary,
        selectedLogicalIDs: [String]? = nil,
        catalogFingerprint: String? = nil
    ) {
        self.planIdentifier = planIdentifier
        self.generatedAt = generatedAt
        self.entries = entries
        self.excludedSensitiveCategories = excludedSensitiveCategories.sorted()
        self.redactionSummary = redactionSummary
        self.selectedLogicalIDs = selectedLogicalIDs?.sorted()
        self.catalogFingerprint = catalogFingerprint ?? Self.fingerprint(for: entries)
    }

    func selecting(logicalIDs: [String]) throws -> SupportBundlePlan {
        let requested = Set(logicalIDs)
        let known = Set(entries.map(\.logicalID))
        let unknown = requested.subtracting(known).sorted()
        guard unknown.isEmpty else {
            throw SupportBundleSelectionError.unknownLogicalIDs(unknown)
        }
        let selectedEntries = entries.filter { requested.contains($0.logicalID) }
        let selectedIDs = selectedEntries.map(\.logicalID).sorted()
        return SupportBundlePlan(
            planIdentifier: planIdentifier,
            generatedAt: generatedAt,
            entries: selectedEntries,
            excludedSensitiveCategories: excludedSensitiveCategories,
            redactionSummary: redactionSummary,
            selectedLogicalIDs: selectedIDs,
            catalogFingerprint: catalogFingerprint
        )
    }

    private static func fingerprint(for entries: [SupportBundleEntryPlan]) -> String {
        let canonical = entries
            .sorted { $0.logicalID < $1.logicalID }
            .map {
                [
                    $0.sourceID,
                    $0.logicalID,
                    $0.archivePath,
                    $0.category,
                    $0.reason,
                    $0.expectedRedaction,
                    $0.approximateSizeBytes.map(String.init) ?? ""
                ].joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{1E}")

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

protocol SupportBundleClock: Sendable {
    var now: Date { get }
}

struct SystemSupportBundleClock: SupportBundleClock {
    var now: Date { Date() }
}

protocol SupportBundleSourceDescribing: Sendable {
    var sourceID: String { get }
    func describeEntries() -> [SupportBundleEntryPlan]
}

protocol SupportBundleSourceCollecting: Sendable {
    func collect(logicalID: String) throws -> SupportBundleCollectedEntry
}

protocol SupportBundleSource: SupportBundleSourceDescribing, SupportBundleSourceCollecting {}

struct SupportBundleCollectedEntry: Sendable {
    let archivePath: String
    let data: Data
    let sourceURL: URL?
    let approvedRoot: URL?

    init(
        archivePath: String,
        data: Data,
        sourceURL: URL? = nil,
        approvedRoot: URL? = nil
    ) {
        self.archivePath = archivePath
        self.data = data
        self.sourceURL = sourceURL
        self.approvedRoot = approvedRoot
    }
}

struct SupportBundleArchiveEntry: Equatable, Sendable {
    let archivePath: String
    let data: Data
}

protocol SupportBundleArchiveWriting: Sendable {
    func write(
        stagingDirectory: URL,
        entries: [SupportBundleArchiveEntry],
        to destination: URL
    ) throws
}

enum SupportBundleError: Error, Equatable, LocalizedError, Sendable {
    case invalidPlan(String)
    case unsafeArchivePath(String)
    case unsafeSource(String)
    case duplicateArchivePath(String)
    case sourceUnavailable(String)
    case archiveAlreadyExists(String)
    case archiveWriteFailed

    var errorDescription: String? {
        switch self {
        case .invalidPlan(let reason):
            return "Invalid support-bundle plan: \(reason)"
        case .unsafeArchivePath:
            return "Support-bundle entry has an unsafe archive path."
        case .unsafeSource:
            return "Support-bundle source is outside its approved root or uses a symlink."
        case .duplicateArchivePath:
            return "Support-bundle entries contain a duplicate archive path."
        case .sourceUnavailable:
            return "Support-bundle source could not collect the approved entry."
        case .archiveAlreadyExists:
            return "Support-bundle destination already exists."
        case .archiveWriteFailed:
            return "Support-bundle archive creation failed."
        }
    }
}

struct DittoSupportBundleArchiveWriter: SupportBundleArchiveWriting {
    func write(
        stagingDirectory: URL,
        entries: [SupportBundleArchiveEntry],
        to destination: URL
    ) throws {
        try validateStagingContents(stagingDirectory: stagingDirectory, entries: entries)
        try validateDestination(destination)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            "--norsrc",
            stagingDirectory.path,
            destination.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SupportBundleError.archiveWriteFailed
        }

        guard process.terminationStatus == 0,
              isRegularFile(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw SupportBundleError.archiveWriteFailed
        }
        do {
            try setSecurePermissions(destination, mode: 0o600)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw SupportBundleError.archiveWriteFailed
        }
    }

    private func validateStagingContents(
        stagingDirectory: URL,
        entries: [SupportBundleArchiveEntry]
    ) throws {
        guard isDirectory(stagingDirectory), hasNoSymlinkAncestors(stagingDirectory) else {
            throw SupportBundleError.archiveWriteFailed
        }

        var expected: [String: Data] = [:]
        for entry in entries {
            let path = try validatedArchivePath(entry.archivePath)
            guard expected.updateValue(entry.data, forKey: path) == nil else {
                throw SupportBundleError.duplicateArchivePath(path)
            }
        }

        var actual: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw SupportBundleError.archiveWriteFailed
        }
        while let url = enumerator.nextObject() as? URL {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw SupportBundleError.archiveWriteFailed
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK {
                throw SupportBundleError.archiveWriteFailed
            }
            if type == S_IFDIR {
                continue
            }
            guard type == S_IFREG else {
                throw SupportBundleError.archiveWriteFailed
            }
            let relative = String(url.path.dropFirst(stagingDirectory.path.count + 1))
            let path = try validatedArchivePath(relative)
            guard actual[path] == nil else {
                throw SupportBundleError.duplicateArchivePath(path)
            }
            actual[path] = try Data(contentsOf: url)
        }
        guard actual.count == expected.count,
              actual.keys.sorted() == expected.keys.sorted(),
              actual.allSatisfy({ expected[$0.key] == $0.value }) else {
            throw SupportBundleError.archiveWriteFailed
        }
    }

    private func validateDestination(_ url: URL) throws {
        guard url.path.hasPrefix("/") else {
            throw SupportBundleError.archiveWriteFailed
        }
        try validateExistingPathComponents(url.deletingLastPathComponent(), requireDirectory: true)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            throw SupportBundleError.archiveWriteFailed
        }
        guard errno == ENOENT else {
            throw SupportBundleError.archiveWriteFailed
        }
    }

    private func validateExistingPathComponents(_ url: URL, requireDirectory: Bool) throws {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { throw SupportBundleError.archiveWriteFailed }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                throw SupportBundleError.archiveWriteFailed
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                guard VerifiedMacOSSystemAlias.isAllowed(current) else {
                    throw SupportBundleError.archiveWriteFailed
                }
                continue
            }
            if requireDirectory {
                guard (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw SupportBundleError.archiveWriteFailed
                }
            }
        }
    }

    private func hasNoSymlinkAncestors(_ url: URL) -> Bool {
        do {
            try validateExistingPathComponents(url, requireDirectory: false)
            return true
        } catch {
            return false
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private func setSecurePermissions(_ url: URL, mode: mode_t) throws {
        guard chmod(url.path, mode) == 0 else { throw SupportBundleError.archiveWriteFailed }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & 0o777) == mode else {
            throw SupportBundleError.archiveWriteFailed
        }
    }

    private func validatedArchivePath(_ path: String) throws -> String {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0") else {
            throw SupportBundleError.unsafeArchivePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SupportBundleError.unsafeArchivePath(path)
        }
        return components.joined(separator: "/")
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

final class SupportBundleEngine: @unchecked Sendable {
    private struct IssuedEntry: Sendable {
        let original: SupportBundleEntryPlan
        let published: SupportBundleEntryPlan
    }

    private struct IssuedPlan: Sendable {
        let plan: SupportBundlePlan
        let entriesByPublishedLogicalID: [String: IssuedEntry]
    }

    private final class IssuedPlans: @unchecked Sendable {
        let lock = NSLock()
        var plans: [String: IssuedPlan] = [:]

        func insert(_ plan: IssuedPlan) {
            lock.lock()
            plans[plan.plan.planIdentifier] = plan
            lock.unlock()
        }

        func get(_ identifier: String) -> IssuedPlan? {
            lock.lock()
            defer { lock.unlock() }
            return plans[identifier]
        }
    }

    private let sources: [any SupportBundleSource]
    private let clock: any SupportBundleClock
    private let redactor: SensitiveDataRedactor
    private let archiveWriter: any SupportBundleArchiveWriting
    private let issuedPlans = IssuedPlans()

    init(
        sources: [any SupportBundleSource],
        clock: any SupportBundleClock = SystemSupportBundleClock(),
        redactor: SensitiveDataRedactor = SensitiveDataRedactor(
            exactSecrets: [],
            homeDirectory: NSHomeDirectory()
        ),
        archiveWriter: any SupportBundleArchiveWriting = DittoSupportBundleArchiveWriter()
    ) {
        self.sources = sources
        self.clock = clock
        self.redactor = redactor
        self.archiveWriter = archiveWriter
    }

    func preview() -> SupportBundlePlan {
        let generatedAt = clock.now
        let originals = sources
            .flatMap { $0.describeEntries() }
            .filter { !Self.isExcludedSensitiveCategory($0.category) }
            .sorted {
                if $0.logicalID == $1.logicalID {
                    return $0.archivePath < $1.archivePath
                }
                return $0.logicalID < $1.logicalID
            }
        var publishedLogicalIDs = Set<String>()
        var publishedSourceIDs = Set<String>()
        let issuedEntries = originals.enumerated().map { index, original in
            let logicalID = uniquePublishedValue(redactor.redact(original.logicalID), index: index, used: &publishedLogicalIDs)
            let sourceID = uniquePublishedValue(redactor.redact(original.sourceID), index: index, used: &publishedSourceIDs)
            return IssuedEntry(
                original: original,
                published: SupportBundleEntryPlan(
                    sourceID: sourceID,
                    logicalID: logicalID,
                    archivePath: redactor.redactedPath(original.archivePath),
                    category: redactor.redact(original.category),
                    reason: redactor.redact(original.reason),
                    expectedRedaction: redactor.redact(original.expectedRedaction),
                    approximateSizeBytes: original.approximateSizeBytes
                )
            )
        }
        let descriptors = issuedEntries.map(\.published)
        let redactionSummary = SupportBundleRedactionSummary()
        let fingerprint = SupportBundlePlan(
            planIdentifier: "placeholder",
            generatedAt: generatedAt,
            entries: descriptors,
            excludedSensitiveCategories: redactionSummary.excludedSensitiveCategories,
            redactionSummary: redactionSummary
        ).catalogFingerprint
        let plan = SupportBundlePlan(
            planIdentifier: "support-v1-\(UUID().uuidString)",
            generatedAt: generatedAt,
            entries: descriptors,
            excludedSensitiveCategories: redactionSummary.excludedSensitiveCategories,
            redactionSummary: redactionSummary,
            catalogFingerprint: fingerprint
        )
        issuedPlans.insert(IssuedPlan(
            plan: plan,
            entriesByPublishedLogicalID: Dictionary(uniqueKeysWithValues: issuedEntries.map { ($0.published.logicalID, $0) })
        ))
        return plan
    }

    private func uniquePublishedValue(_ value: String, index: Int, used: inout Set<String>) -> String {
        guard !used.contains(value) else {
            var candidate = "\(value)-\(index)"
            var suffix = index
            while !used.insert(candidate).inserted {
                suffix += 1
                candidate = "\(value)-\(suffix)"
            }
            return candidate
        }
        used.insert(value)
        return value
    }

    private static func isExcludedSensitiveCategory(_ category: String) -> Bool {
        let normalized = category
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
        let exact = [
            "apikey",
            "authorization",
            "authtoken",
            "bottoken",
            "chatid",
            "chatsecret",
            "credential",
            "credentials",
            "keychain",
            "keychainvalue",
            "keychainvalues",
            "clipboard",
            "shellhistory",
            "requestbody",
            "requestbodies",
            "responsebody",
            "responsebodies",
            "requestresponsebody",
            "requestresponsebodies",
            "mcpbody",
            "mcpbodies",
            "mcprequestbody",
            "mcprequestbodies",
            "mcpresponsebody",
            "mcpresponsebodies",
            "mcprequestresponsebodies",
            "userdocument",
            "userdocuments",
            "browserdata",
            "browserhistory",
            "shellbrowserdata",
            "connectorurl",
            "connectortoken",
            "connectorsecret",
            "password",
            "privatekey",
            "secret",
            "secretmaterial",
            "telegrambottoken",
            "telegrambotsecret",
            "telegramchatid",
            "telegramsecret",
            "ngrokcredential",
            "ngrokcredentials",
            "ngrokauthtoken",
            "shellbrowserhistory"
        ]
        return exact.contains(normalized) || [
            "apikey",
            "authorization",
            "authtoken",
            "bottoken",
            "chatid",
            "chatsecret",
            "credential",
            "keychain",
            "clipboard",
            "shellhistory",
            "shellbrowser",
            "browser",
            "userdocument",
            "requestbody",
            "responsebody",
            "requestresponse",
            "mcpbody",
            "connectorurl",
            "connectortoken",
            "connectorsecret",
            "password",
            "privatekey",
            "secret",
            "secretmaterial",
            "telegram",
            "ngrokcredential",
            "ngrokauthtoken"
        ].contains(where: normalized.contains)
    }

    @discardableResult
    func create(plan: SupportBundlePlan, to destination: URL) throws -> URL {
        guard let issued = issuedPlans.get(plan.planIdentifier) else {
            throw SupportBundleError.invalidPlan("plan was not issued by this engine")
        }
        try validate(plan: plan, against: issued)
        try validateDestination(destination)

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOrchestrator-support-\(UUID().uuidString)", isDirectory: true)
        var result: Result<URL, Error>
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try setSecurePermissions(stagingDirectory, mode: 0o700)

            let archiveEntries = try collect(plan: plan, issued: issued, into: stagingDirectory)
            try archiveWriter.write(
                stagingDirectory: stagingDirectory,
                entries: archiveEntries,
                to: destination
            )
            result = .success(destination)
        } catch let error as SupportBundleError {
            result = .failure(error)
        } catch {
            result = .failure(SupportBundleError.archiveWriteFailed)
        }
        guard (try? FileManager.default.removeItem(at: stagingDirectory)) != nil else {
            throw SupportBundleError.archiveWriteFailed
        }
        return try result.get()
    }

    private func validate(plan: SupportBundlePlan, against issued: IssuedPlan) throws {
        guard plan.planIdentifier == issued.plan.planIdentifier,
              plan.generatedAt == issued.plan.generatedAt,
              plan.catalogFingerprint == issued.plan.catalogFingerprint,
              plan.excludedSensitiveCategories == issued.plan.excludedSensitiveCategories,
              plan.redactionSummary == issued.plan.redactionSummary else {
            throw SupportBundleError.invalidPlan("plan metadata was altered")
        }

        let allEntries = issued.plan.entries
        let expectedEntries: [SupportBundleEntryPlan]
        if let selected = plan.selectedLogicalIDs {
            guard selected == Array(Set(selected)).sorted(),
                  Set(selected).count == selected.count else {
                throw SupportBundleError.invalidPlan("selection metadata was altered")
            }
            expectedEntries = allEntries.filter { selected.contains($0.logicalID) }
        } else {
            expectedEntries = allEntries
        }
        guard plan.entries == expectedEntries else {
            throw SupportBundleError.invalidPlan("entries do not match the issued selection")
        }

        try validateEntries(plan.entries)
    }

    private func validateEntries(_ entries: [SupportBundleEntryPlan]) throws {
        var logicalIDs = Set<String>()
        var archivePaths = Set<String>()
        for entry in entries {
            guard logicalIDs.insert(entry.logicalID).inserted else {
                throw SupportBundleError.invalidPlan("duplicate logical entry")
            }
            let safePath = try validatedArchivePath(entry.archivePath)
            guard archivePaths.insert(safePath).inserted else {
                throw SupportBundleError.duplicateArchivePath(safePath)
            }
        }
    }

    private func collect(
        plan: SupportBundlePlan,
        issued: IssuedPlan,
        into stagingDirectory: URL
    ) throws -> [SupportBundleArchiveEntry] {
        let sourcesByID = Dictionary(grouping: sources, by: \.sourceID)
        var archiveEntries: [SupportBundleArchiveEntry] = []
        var archivePaths = Set<String>()

        for entry in plan.entries {
            guard let issuedEntry = issued.entriesByPublishedLogicalID[entry.logicalID],
                  let source = sourcesByID[issuedEntry.original.sourceID], source.count == 1,
                  let source = source.first else {
                throw SupportBundleError.sourceUnavailable(entry.logicalID)
            }
            let collected: SupportBundleCollectedEntry
            do {
                collected = try source.collect(logicalID: issuedEntry.original.logicalID)
            } catch {
                throw SupportBundleError.sourceUnavailable(entry.logicalID)
            }
            guard collected.archivePath == issuedEntry.original.archivePath else {
                throw SupportBundleError.invalidPlan("collector returned an unapproved archive path")
            }
            guard redactor.redactedPath(collected.archivePath) == entry.archivePath else {
                throw SupportBundleError.invalidPlan("collector returned an unapproved archive path")
            }
            try validateSource(collected)

            let archivePath = try validatedArchivePath(entry.archivePath)
            guard archivePaths.insert(archivePath).inserted else {
                throw SupportBundleError.duplicateArchivePath(archivePath)
            }
            let redactedData = redact(collected.data, archivePath: archivePath)
            let fileURL = stagingDirectory.appendingPathComponent(archivePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try setSecurePermissions(fileURL.deletingLastPathComponent(), mode: 0o700)
            try redactedData.write(to: fileURL, options: [.atomic])
            try setSecurePermissions(fileURL, mode: 0o600)
            archiveEntries.append(SupportBundleArchiveEntry(archivePath: archivePath, data: redactedData))
        }
        return archiveEntries
    }

    private func redact(_ data: Data, archivePath: String) -> Data {
        if archivePath.lowercased().hasSuffix(".json"), let redactedJSON = redactor.redactJSON(data) {
            return redactedJSON
        }
        return Data(redactor.redact(String(decoding: data, as: UTF8.self)).utf8)
    }

    private func validateSource(_ collected: SupportBundleCollectedEntry) throws {
        guard let sourceURL = collected.sourceURL else { return }
        guard let approvedRoot = collected.approvedRoot,
              isWithin(sourceURL, root: approvedRoot),
              isAbsoluteExistingDirectory(approvedRoot),
              isAbsoluteExistingRegularFile(sourceURL),
              hasNoSymlinkComponents(sourceURL, through: approvedRoot) else {
            throw SupportBundleError.unsafeSource(sourceURL.path)
        }
    }

    private func validateDestination(_ destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        guard destination.path.hasPrefix("/"),
              validateNoSymlinkExistingComponents(parent, requireDirectory: true) else {
            throw SupportBundleError.unsafeSource(parent.path)
        }
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            throw SupportBundleError.archiveAlreadyExists(destination.path)
        }
        guard errno == ENOENT else { throw SupportBundleError.unsafeSource(destination.path) }
    }

    private func validatedArchivePath(_ path: String) throws -> String {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0") else {
            throw SupportBundleError.unsafeArchivePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SupportBundleError.unsafeArchivePath(path)
        }
        return components.joined(separator: "/")
    }

    private func isWithin(_ url: URL, root: URL) -> Bool {
        let file = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return file.hasPrefix(rootPath + "/")
    }

    private func hasNoSymlinkComponents(_ url: URL, through root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return false }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        guard validateNoSymlinkExistingComponents(URL(fileURLWithPath: rootPath), requireDirectory: true) else {
            return false
        }
        var current = URL(fileURLWithPath: rootPath, isDirectory: true)
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: false)
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  (info.st_mode & S_IFMT) != S_IFLNK else { return false }
        }
        return true
    }

    private func validateNoSymlinkExistingComponents(_ url: URL, requireDirectory: Bool) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { return false }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in path.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            var info = stat()
            guard lstat(current.path, &info) == 0 else { return false }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                guard VerifiedMacOSSystemAlias.isAllowed(current) else { return false }
                continue
            }
            if requireDirectory && (info.st_mode & S_IFMT) != S_IFDIR { return false }
        }
        return true
    }

    private func isAbsoluteExistingDirectory(_ url: URL) -> Bool {
        guard url.path.hasPrefix("/"), validateNoSymlinkExistingComponents(url, requireDirectory: true) else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func isAbsoluteExistingRegularFile(_ url: URL) -> Bool {
        guard url.path.hasPrefix("/") else { return false }
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private func setSecurePermissions(_ url: URL, mode: mode_t) throws {
        guard chmod(url.path, mode) == 0 else { throw SupportBundleError.archiveWriteFailed }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & 0o777) == mode else {
            throw SupportBundleError.archiveWriteFailed
        }
    }
}
