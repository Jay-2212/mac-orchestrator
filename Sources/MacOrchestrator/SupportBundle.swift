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
            "credentials",
            "keychain-values",
            "user-documents",
            "clipboard",
            "shell-history",
            "request-response-bodies"
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

    func selecting(logicalIDs: [String]) -> SupportBundlePlan {
        let requested = Set(logicalIDs)
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
        guard FileManager.default.fileExists(atPath: stagingDirectory.path),
              !FileManager.default.fileExists(atPath: destination.path),
              isDirectory(stagingDirectory) else {
            throw SupportBundleError.archiveWriteFailed
        }

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
            throw SupportBundleError.archiveWriteFailed
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}

final class SupportBundleEngine: @unchecked Sendable {
    private final class IssuedPlans: @unchecked Sendable {
        let lock = NSLock()
        var plans: [String: SupportBundlePlan] = [:]

        func insert(_ plan: SupportBundlePlan) {
            lock.lock()
            plans[plan.planIdentifier] = plan
            lock.unlock()
        }

        func get(_ identifier: String) -> SupportBundlePlan? {
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
        let descriptors = sources
            .flatMap { $0.describeEntries() }
            .filter { !Self.isExcludedSensitiveCategory($0.category) }
            .sorted {
                if $0.logicalID == $1.logicalID {
                    return $0.archivePath < $1.archivePath
                }
                return $0.logicalID < $1.logicalID
            }
        let redactionSummary = SupportBundleRedactionSummary()
        let fingerprint = SupportBundlePlan(
            planIdentifier: "placeholder",
            generatedAt: generatedAt,
            entries: descriptors,
            excludedSensitiveCategories: redactionSummary.excludedSensitiveCategories,
            redactionSummary: redactionSummary
        ).catalogFingerprint
        let plan = SupportBundlePlan(
            planIdentifier: "support-v1-\(fingerprint)",
            generatedAt: generatedAt,
            entries: descriptors,
            excludedSensitiveCategories: redactionSummary.excludedSensitiveCategories,
            redactionSummary: redactionSummary,
            catalogFingerprint: fingerprint
        )
        issuedPlans.insert(plan)
        return plan
    }

    private static func isExcludedSensitiveCategory(_ category: String) -> Bool {
        let normalized = category
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
        return [
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
            "userdocument",
            "userdocuments"
        ].contains(normalized)
    }

    @discardableResult
    func create(plan: SupportBundlePlan, to destination: URL) throws -> URL {
        guard let issued = issuedPlans.get(plan.planIdentifier) else {
            throw SupportBundleError.invalidPlan("plan was not issued by this engine")
        }
        try validate(plan: plan, against: issued)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SupportBundleError.archiveAlreadyExists(destination.path)
        }
        try validateDestination(destination)

        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOrchestrator-support-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDirectory)
        }
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            _ = chmod(stagingDirectory.path, mode_t(0o700))

            let archiveEntries = try collect(plan: plan, issued: issued, into: stagingDirectory)
            try archiveWriter.write(
                stagingDirectory: stagingDirectory,
                entries: archiveEntries,
                to: destination
            )
            return destination
        } catch let error as SupportBundleError {
            throw error
        } catch {
            throw SupportBundleError.archiveWriteFailed
        }
    }

    private func validate(plan: SupportBundlePlan, against issued: SupportBundlePlan) throws {
        guard plan.planIdentifier == issued.planIdentifier,
              plan.generatedAt == issued.generatedAt,
              plan.catalogFingerprint == issued.catalogFingerprint,
              plan.excludedSensitiveCategories == issued.excludedSensitiveCategories,
              plan.redactionSummary == issued.redactionSummary else {
            throw SupportBundleError.invalidPlan("plan metadata was altered")
        }

        let allEntries = issued.entries
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
        issued: SupportBundlePlan,
        into stagingDirectory: URL
    ) throws -> [SupportBundleArchiveEntry] {
        let sourcesByID = Dictionary(grouping: sources, by: \.sourceID)
        var archiveEntries: [SupportBundleArchiveEntry] = []
        var archivePaths = Set<String>()

        for entry in plan.entries {
            guard let source = sourcesByID[entry.sourceID], source.count == 1,
                  let source = source.first else {
                throw SupportBundleError.sourceUnavailable(entry.logicalID)
            }
            let collected: SupportBundleCollectedEntry
            do {
                collected = try source.collect(logicalID: entry.logicalID)
            } catch {
                throw SupportBundleError.sourceUnavailable(entry.logicalID)
            }
            guard collected.archivePath == entry.archivePath else {
                throw SupportBundleError.invalidPlan("collector returned an unapproved archive path")
            }
            try validateSource(collected)

            let archivePath = try validatedArchivePath(redactor.redact(entry.archivePath))
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
            try redactedData.write(to: fileURL, options: [.atomic])
            _ = chmod(fileURL.path, mode_t(0o600))
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
              hasNoSymlinkComponents(sourceURL, through: approvedRoot) else {
            throw SupportBundleError.unsafeSource(sourceURL.path)
        }
    }

    private func validateDestination(_ destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        var info = stat()
        guard stat(parent.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              !isSymlink(parent) else {
            throw SupportBundleError.unsafeSource(parent.path)
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
        var current = URL(fileURLWithPath: rootPath, isDirectory: true)
        if isSymlink(current) { return false }
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: false)
            if isSymlink(current) { return false }
        }
        return true
    }

    private func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }
}
