import Foundation
import XCTest
@testable import MacOrchestrator

final class SupportBundleTests: XCTestCase {
    func testPreviewDescribesEntriesWithoutCollectingOrCreatingArchive() throws {
        let source = RecordingBundleSource(entries: [RecordingBundleSource.doctorReport, RecordingBundleSource.logs])
        let writer = RecordingArchiveWriter()
        let engine = SupportBundleEngine(
            sources: [source],
            clock: FixedSupportBundleClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
            archiveWriter: writer
        )
        let archiveURL = temporaryArchiveURL()

        let plan = engine.preview()

        XCTAssertEqual(source.collectCalls, [])
        XCTAssertEqual(plan.entries.map(\.logicalID), ["doctor-report", "logs"])
        XCTAssertEqual(writer.writeCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertEqual(plan.excludedSensitiveCategories, [
            "api-keys",
            "authorization",
            "bot-token",
            "browser-data",
            "chat-id",
            "clipboard",
            "connector-token",
            "connector-url",
            "credentials",
            "keychain-values",
            "mcp-request-response-bodies",
            "ngrok-credentials",
            "request-response-bodies",
            "secret-material",
            "shell-browser-data",
            "shell-history",
            "telegram-bot-secret",
            "telegram-bot-token",
            "telegram-chat-id",
            "telegram-secret",
            "user-documents"
        ])
    }

    func testCreationUsesExactlyTheApprovedPlan() throws {
        let source = RecordingBundleSource(entries: [RecordingBundleSource.doctorReport, RecordingBundleSource.logs, RecordingBundleSource.config])
        let engine = SupportBundleEngine(
            sources: [source],
            clock: FixedSupportBundleClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
            redactor: SensitiveDataRedactor(exactSecrets: [], homeDirectory: "/Users/synthetic")
        )
        let plan = engine.preview()
        let selected = try plan.selecting(logicalIDs: ["doctor-report"])
        let archive = temporaryArchiveURL()

        _ = try engine.create(plan: selected, to: archive)

        XCTAssertEqual(source.collectCalls, ["doctor-report"])
        let extracted = try extractEntries(from: archive)
        XCTAssertEqual(extracted.map(\.name), ["doctor-report.json"])
    }

    func testNormalTemporaryArchiveCreationAllowsVerifiedMacOSTemporaryAlias() throws {
        let source = RecordingBundleSource(entries: [RecordingBundleSource.doctorReport])
        let engine = SupportBundleEngine(sources: [source])
        let archive = temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: archive) }

        _ = try engine.create(plan: engine.preview(), to: archive)

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testAlteredAndUnknownPlansAreRejectedBeforeCollection() throws {
        let source = RecordingBundleSource(entries: [RecordingBundleSource.doctorReport])
        let engine = SupportBundleEngine(sources: [source])
        let plan = engine.preview()

        let altered = SupportBundlePlan(
            planIdentifier: plan.planIdentifier,
            generatedAt: plan.generatedAt,
            entries: [SupportBundleEntryPlan(
                sourceID: "recording",
                logicalID: "doctor-report",
                archivePath: "outside.txt",
                category: "diagnostic",
                reason: "altered",
                expectedRedaction: "redacted"
            )],
            excludedSensitiveCategories: plan.excludedSensitiveCategories,
            redactionSummary: plan.redactionSummary,
            catalogFingerprint: plan.catalogFingerprint
        )
        let unknown = SupportBundlePlan(
            planIdentifier: "support-v1-unknown",
            generatedAt: plan.generatedAt,
            entries: plan.entries,
            excludedSensitiveCategories: plan.excludedSensitiveCategories,
            redactionSummary: plan.redactionSummary,
            catalogFingerprint: plan.catalogFingerprint
        )

        XCTAssertThrowsError(try engine.create(plan: altered, to: temporaryArchiveURL()))
        XCTAssertThrowsError(try engine.create(plan: unknown, to: temporaryArchiveURL()))
        XCTAssertEqual(source.collectCalls, [])
    }

    func testUnknownSelectionAndRepeatedPreviewsAreRejectedOrIndependent() throws {
        let source = RecordingBundleSource(entries: [RecordingBundleSource.doctorReport])
        let engine = SupportBundleEngine(sources: [source])

        let first = engine.preview()
        let second = engine.preview()

        XCTAssertNotEqual(first.planIdentifier, second.planIdentifier)
        XCTAssertThrowsError(try first.selecting(logicalIDs: ["not-issued"]))

        _ = try engine.create(plan: first, to: temporaryArchiveURL())
        _ = try engine.create(plan: second, to: temporaryArchiveURL())
    }

    func testPreviewMetadataIsRedactedAndSensitiveCategoriesAreExcluded() throws {
        let connectorToken = "connector-secret-preview-123"
        let ngrokToken = "ngrok_preview_token_1234567890"
        let home = ["/Users", "synthetic", "Documents", "private"].joined(separator: "/")
        let connectorURL = "https://connector.example.test/\(connectorToken)/mcp"
        let source = RecordingBundleSource(entries: [
            sourceEntry(
                logicalID: "\(connectorToken)-logical",
                archivePath: "logs/\(connectorToken).log",
                category: "diagnostic",
                reason: "url=\(connectorURL) home=\(home) ngrok_authtoken=\(ngrokToken)",
                expectedRedaction: "secret=\(connectorToken)"
            ),
            sourceEntry(logicalID: "connector-url", archivePath: "connector.json", category: "connector-url"),
            sourceEntry(logicalID: "mcp-body", archivePath: "body.json", category: "MCP request/response bodies"),
            sourceEntry(logicalID: "browser", archivePath: "browser-data.json", category: "shell/browser data"),
            sourceEntry(logicalID: "keychain", archivePath: "keychain-values.json", category: "keychain secret material")
        ])
        let engine = SupportBundleEngine(
            sources: [source],
            redactor: SensitiveDataRedactor(exactSecrets: [connectorToken, ngrokToken], homeDirectory: "/Users/synthetic")
        )

        let plan = engine.preview()
        let publicText = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)

        XCTAssertFalse(publicText.contains(connectorToken))
        XCTAssertFalse(publicText.contains(connectorURL))
        XCTAssertFalse(publicText.contains(ngrokToken))
        XCTAssertFalse(publicText.contains(home))
        XCTAssertEqual(plan.entries.map(\.logicalID), ["<redacted>-logical"])
        XCTAssertEqual(source.collectCalls, [])
    }

    func testProductionSupportBundleRedactsUnlabelledKnownSecretFromArchive() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs/Mac Orchestrator", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let secret = "opaque-current-connector-secret-928374"
        try Data("event payload=\(secret)\n".utf8)
            .write(to: logs.appendingPathComponent("app.log"))

        let keychain = KeychainStore(client: SupportBundleKeychainClient(values: [
            KeychainItem.connectorToken.key: secret
        ]))
        let report = DoctorReport(generatedAt: Date(timeIntervalSince1970: 1), results: [])
        let engine = TerminalCommand.makeSupportBundleEngine(
            report: report,
            keychain: keychain,
            supportDirectory: root,
            homeDirectory: home
        )
        let plan = engine.preview()
        let archive = root.appendingPathComponent("support.zip")

        _ = try engine.create(plan: plan, to: archive)

        let extracted = try extractEntries(from: archive)
        let archiveText = extracted
            .map { String(decoding: $0.data, as: UTF8.self) }
            .joined(separator: "\n")
        XCTAssertFalse(archiveText.contains(secret))
        XCTAssertTrue(archiveText.contains("<redacted>"))
    }

    func testSensitiveEntryIsNotCollectedEvenWhenSelectedByPublishedID() throws {
        let source = RecordingBundleSource(entries: [RecordingBundleSource.doctorReport, RecordingBundleSource.credential, RecordingBundleSource.telegramBotToken])
        let engine = SupportBundleEngine(sources: [source])
        let plan = engine.preview()

        XCTAssertThrowsError(try plan.selecting(logicalIDs: ["credentials"]))
        XCTAssertThrowsError(try plan.selecting(logicalIDs: ["telegram-bot-token"]))
        XCTAssertEqual(source.collectCalls, [])
    }

    func testCollectorRawPathMustMatchIssuedSourceBeforeRedaction() throws {
        let token = "path-secret-token"
        let source = RecordingBundleSource(entries: [sourceEntry(
            logicalID: "path-entry",
            archivePath: "logs/\(token).log",
            data: Data("safe".utf8),
            collectedArchivePath: "logs/other-secret-token.log"
        )])
        let engine = SupportBundleEngine(
            sources: [source],
            redactor: SensitiveDataRedactor(exactSecrets: [token], homeDirectory: nil)
        )

        XCTAssertThrowsError(try engine.create(
            plan: engine.preview(),
            to: temporaryArchiveURL()
        ))
        XCTAssertEqual(source.collectCalls, ["path-entry"])
    }

    func testUnsafePathsDuplicatesAndMaliciousFilenamesFailClosed() throws {
        let pathCases = ["../escape.txt", "/absolute.txt", "folder/../escape.txt", "folder//file.txt"]
        for path in pathCases {
            let source = RecordingBundleSource(entries: [sourceEntry(
                logicalID: "malicious",
                archivePath: path
            )])
            let engine = SupportBundleEngine(sources: [source])
            let plan = engine.preview()
            XCTAssertThrowsError(try engine.create(plan: plan, to: temporaryArchiveURL()), "path \(path)")
        }

        let duplicate = RecordingBundleSource(entries: [
            sourceEntry(logicalID: "one", archivePath: "same.txt"),
            sourceEntry(logicalID: "two", archivePath: "same.txt")
        ])
        let duplicateEngine = SupportBundleEngine(sources: [duplicate])
        XCTAssertThrowsError(try duplicateEngine.create(
            plan: duplicateEngine.preview(),
            to: temporaryArchiveURL()
        ))
    }

    func testSymlinkSourcesAndSourceEscapesAreRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real.txt")
        let link = root.appendingPathComponent("link.txt")
        try Data("safe".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let symlinkSource = RecordingBundleSource(entries: [
            sourceEntry(
                logicalID: "symlink",
                archivePath: "symlink.txt",
                sourceURL: link,
                approvedRoot: root
            )
        ])
        let symlinkEngine = SupportBundleEngine(sources: [symlinkSource])
        XCTAssertThrowsError(try symlinkEngine.create(
            plan: symlinkEngine.preview(),
            to: temporaryArchiveURL()
        ))

        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let escapeSource = RecordingBundleSource(entries: [
            sourceEntry(
                logicalID: "escape",
                archivePath: "escape.txt",
                sourceURL: outside,
                approvedRoot: root.appendingPathComponent("approved", isDirectory: true)
            )
        ])
        let escapeEngine = SupportBundleEngine(sources: [escapeSource])
        XCTAssertThrowsError(try escapeEngine.create(
            plan: escapeEngine.preview(),
            to: temporaryArchiveURL()
        ))

        let foreignParent = root.appendingPathComponent("foreign-parent", isDirectory: true)
        let approved = root.appendingPathComponent("approved", isDirectory: true)
        try FileManager.default.createDirectory(at: foreignParent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: false)
        let foreignSource = foreignParent.appendingPathComponent("foreign.txt")
        try Data("foreign".utf8).write(to: foreignSource)
        let symlinkedRoot = root.appendingPathComponent("symlinked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkedRoot, withDestinationURL: foreignParent)
        let ancestorEngine = SupportBundleEngine(sources: [RecordingBundleSource(entries: [
            sourceEntry(
                logicalID: "ancestor",
                archivePath: "ancestor.txt",
                sourceURL: symlinkedRoot.appendingPathComponent("foreign.txt"),
                approvedRoot: symlinkedRoot
            )
        ])])
        XCTAssertThrowsError(try ancestorEngine.create(
            plan: ancestorEngine.preview(),
            to: temporaryArchiveURL()
        ))

        let destinationParent = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: false)
        let destinationTarget = root.appendingPathComponent("destination-target", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationTarget, withIntermediateDirectories: false)
        let destinationLink = root.appendingPathComponent("destination-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: destinationLink, withDestinationURL: destinationTarget)
        let destinationEngine = SupportBundleEngine(sources: [RecordingBundleSource(entries: [RecordingBundleSource.doctorReport])])
        XCTAssertThrowsError(try destinationEngine.create(
            plan: destinationEngine.preview(),
            to: destinationLink.appendingPathComponent("bundle.zip")
        ))
    }

    func testArchiveWriterRejectsUnexpectedAndSymlinkedStagedEntries() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let approved = staging.appendingPathComponent("approved.txt")
        try Data("approved".utf8).write(to: approved)
        let unexpected = staging.appendingPathComponent("unexpected.txt")
        try Data("unexpected".utf8).write(to: unexpected)
        let destination = root.appendingPathComponent("bundle.zip")

        XCTAssertThrowsError(try DittoSupportBundleArchiveWriter().write(
            stagingDirectory: staging,
            entries: [SupportBundleArchiveEntry(archivePath: "approved.txt", data: Data("approved".utf8))],
            to: destination
        ))

        try FileManager.default.removeItem(at: unexpected)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: unexpected, withDestinationURL: outside)
        XCTAssertThrowsError(try DittoSupportBundleArchiveWriter().write(
            stagingDirectory: staging,
            entries: [SupportBundleArchiveEntry(archivePath: "approved.txt", data: Data("approved".utf8))],
            to: root.appendingPathComponent("second.zip")
        ))
    }

    func testArchiveWriterSetsFinalArchivePermissionsToOwnerOnly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data("approved".utf8).write(to: staging.appendingPathComponent("approved.txt"))
        let destination = root.appendingPathComponent("bundle.zip")

        try DittoSupportBundleArchiveWriter().write(
            stagingDirectory: staging,
            entries: [SupportBundleArchiveEntry(archivePath: "approved.txt", data: Data("approved".utf8))],
            to: destination
        )

        var info = stat()
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testDecodedArchiveContainsNoPlantedSecretsOrPrivatePaths() throws {
        let connectorToken = "capability-token-synthetic-123"
        let ngrokToken = "2f7b8e3c9a1d4e6f8a0b2c4d6e8f0a1b"
        let connectorURL = "https://connector.example.test/\(connectorToken)/mcp?token=\(connectorToken)"
        let privatePath = ["/Users", "synthetic", "Documents", "private.txt"].joined(separator: "/")
        let payload = """
        {"authorization":"Bearer \(connectorToken)","connectorURL":"\(connectorURL)","token":"\(connectorToken)","path":"\(privatePath)","nested":{"secret":"\(ngrokToken)"}}
        """
        let log = "remote=\(connectorURL) ngrok_authtoken=\(ngrokToken) path=\(privatePath)"
        let source = RecordingBundleSource(entries: [
            sourceEntry(logicalID: "doctor-report", archivePath: "doctor-report.json", data: Data(payload.utf8)),
            sourceEntry(logicalID: "logs", archivePath: "logs/current.log", data: Data(log.utf8)),
            sourceEntry(
                logicalID: "rotated-log",
                archivePath: "logs/\(connectorToken).log",
                data: Data(log.utf8)
            )
        ])
        let engine = SupportBundleEngine(
            sources: [source],
            redactor: SensitiveDataRedactor(
                exactSecrets: [connectorToken, ngrokToken, "token" + "-" + "synthetic"],
                homeDirectory: "/Users/synthetic"
            )
        )
        let archive = try engine.create(plan: engine.preview(), to: temporaryArchiveURL())
        let extracted = try extractEntries(from: archive)

        XCTAssertFalse(extracted.isEmpty)
        for entry in extracted {
            XCTAssertFalse(entry.name.contains(connectorToken), entry.name)
            XCTAssertFalse(entry.name.contains(ngrokToken), entry.name)
            XCTAssertFalse(entry.name.contains("/Users/synthetic"), entry.name)
            let text = String(decoding: entry.data, as: UTF8.self)
            XCTAssertFalse(text.contains(connectorToken), entry.name)
            XCTAssertFalse(text.contains(ngrokToken), entry.name)
            XCTAssertFalse(text.contains("/Users/synthetic"), entry.name)
            XCTAssertFalse(text.contains(connectorURL), entry.name)
        }
    }

    func testPreviewDoesNotCollectSensitiveCategoriesOrCreateArchive() {
        let source = RecordingBundleSource(entries: [RecordingBundleSource.doctorReport, RecordingBundleSource.credential])
        let engine = SupportBundleEngine(sources: [source])
        let plan = engine.preview()

        XCTAssertFalse(plan.entries.contains { $0.category == "credentials" })
        XCTAssertEqual(plan.entries.map(\.logicalID), ["doctor-report"])
        XCTAssertEqual(source.collectCalls, [])
    }

    private func sourceEntry(
        logicalID: String,
        archivePath: String,
        data: Data = Data("fixture".utf8),
        category: String = "diagnostic",
        reason: String = "deterministic fixture",
        expectedRedaction: String = "canonical redaction",
        sourceURL: URL? = nil,
        approvedRoot: URL? = nil,
        collectedArchivePath: String? = nil
    ) -> FixtureEntry {
        FixtureEntry(
            plan: SupportBundleEntryPlan(
                sourceID: "recording",
                logicalID: logicalID,
                archivePath: archivePath,
                category: category,
                reason: reason,
                expectedRedaction: expectedRedaction,
                approximateSizeBytes: data.count
            ),
            data: data,
            sourceURL: sourceURL,
            approvedRoot: approvedRoot,
            collectedArchivePath: collectedArchivePath
        )
    }

    private func temporaryArchiveURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("support-bundle-test-\(UUID().uuidString).zip")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("support-bundle-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func extractEntries(from archive: URL) throws -> [(name: String, data: Data)] {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var result: [(name: String, data: Data)] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            XCTAssertNotEqual(values.isSymbolicLink, true, "archive contains a symlink: \(url.path)")
            guard values.isDirectory != true else { continue }
            let relative = try relativePath(of: url, under: directory)
            result.append((relative, try Data(contentsOf: url)))
        }
        return result.sorted { $0.name < $1.name }
    }

    private func relativePath(of file: URL, under directory: URL) throws -> String {
        let rootPaths = [
            directory.path,
            directory.standardizedFileURL.path,
            directory.resolvingSymlinksInPath().standardizedFileURL.path
        ]
        let filePaths = [
            file.path,
            file.standardizedFileURL.path,
            file.resolvingSymlinksInPath().standardizedFileURL.path
        ]
        for root in rootPaths {
            for path in filePaths where path.hasPrefix(root + "/") {
                return String(path.dropFirst(root.count + 1))
            }
        }
        throw NSError(domain: "SupportBundleTests", code: 1)
    }
}

private struct FixedSupportBundleClock: SupportBundleClock {
    let now: Date
}

private struct FixtureEntry: Sendable {
    let plan: SupportBundleEntryPlan
    let data: Data
    let sourceURL: URL?
    let approvedRoot: URL?
    let collectedArchivePath: String?
}

private final class RecordingBundleSource: @unchecked Sendable, SupportBundleSource {
    let sourceID = "recording"
    private let entries: [FixtureEntry]
    private let lock = NSLock()
    private(set) var collectCalls: [String] = []

    init(entries: [FixtureEntry]) {
        self.entries = entries
    }

    static var doctorReport: FixtureEntry {
        FixtureEntry(
            plan: SupportBundleEntryPlan(
                sourceID: "recording",
                logicalID: "doctor-report",
                archivePath: "doctor-report.json",
                category: "diagnostic",
                reason: "serialized doctor result",
                expectedRedaction: "canonical redaction",
                approximateSizeBytes: 42
            ),
            data: Data("{\"status\":\"pass\"}".utf8),
            sourceURL: nil,
            approvedRoot: nil,
            collectedArchivePath: nil
        )
    }

    static var logs: FixtureEntry {
        FixtureEntry(
            plan: SupportBundleEntryPlan(
                sourceID: "recording",
                logicalID: "logs",
                archivePath: "logs/current.log",
                category: "logs",
                reason: "limited sanitized log excerpt",
                expectedRedaction: "canonical redaction",
                approximateSizeBytes: 20
            ),
            data: Data("safe log".utf8),
            sourceURL: nil,
            approvedRoot: nil,
            collectedArchivePath: nil
        )
    }

    static var config: FixtureEntry {
        FixtureEntry(
            plan: SupportBundleEntryPlan(
                sourceID: "recording",
                logicalID: "config",
                archivePath: "configuration.json",
                category: "configuration",
                reason: "sanitized configuration",
                expectedRedaction: "canonical redaction",
                approximateSizeBytes: 24
            ),
            data: Data("{\"enabled\":true}".utf8),
            sourceURL: nil,
            approvedRoot: nil,
            collectedArchivePath: nil
        )
    }

    static var credential: FixtureEntry {
        FixtureEntry(
            plan: SupportBundleEntryPlan(
                sourceID: "recording",
                logicalID: "credentials",
                archivePath: "credentials.json",
                category: "credentials",
                reason: "must never be collected",
                expectedRedaction: "excluded"
            ),
            data: Data("{\"token\":\"must-not-appear\"}".utf8),
            sourceURL: nil,
            approvedRoot: nil,
            collectedArchivePath: nil
        )
    }

    static var telegramBotToken: FixtureEntry {
        FixtureEntry(
            plan: SupportBundleEntryPlan(
                sourceID: "recording",
                logicalID: "telegram-bot-token",
                archivePath: "telegram.json",
                category: "Telegram bot token",
                reason: "must never be collected",
                expectedRedaction: "excluded"
            ),
            data: Data("bot-token-must-not-appear".utf8),
            sourceURL: nil,
            approvedRoot: nil,
            collectedArchivePath: nil
        )
    }

    func describeEntries() -> [SupportBundleEntryPlan] {
        entries.map(\.plan)
    }

    func collect(logicalID: String) throws -> SupportBundleCollectedEntry {
        lock.lock()
        collectCalls.append(logicalID)
        lock.unlock()
        guard let entry = entries.first(where: { $0.plan.logicalID == logicalID }) else {
            throw SupportBundleError.sourceUnavailable(logicalID)
        }
        return SupportBundleCollectedEntry(
            archivePath: entry.collectedArchivePath ?? entry.plan.archivePath,
            data: entry.data,
            sourceURL: entry.sourceURL,
            approvedRoot: entry.approvedRoot
        )
    }
}

private final class RecordingArchiveWriter: @unchecked Sendable, SupportBundleArchiveWriting {
    private(set) var writeCalls = 0

    func write(
        stagingDirectory: URL,
        entries: [SupportBundleArchiveEntry],
        to destination: URL
    ) throws {
        writeCalls += 1
    }
}

private final class SupportBundleKeychainClient: KeychainClient {
    let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func read(service: String, account: String) throws -> String? {
        values[KeychainItem.key(service: service, account: account)]
    }

    func create(value: String, service: String, account: String) throws {}
    func update(value: String, service: String, account: String) throws {}
}
