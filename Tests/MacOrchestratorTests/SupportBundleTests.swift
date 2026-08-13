import Foundation
import XCTest
@testable import MacOrchestrator

final class SupportBundleTests: XCTestCase {
    func testPreviewDescribesEntriesWithoutCollectingOrCreatingArchive() throws {
        let source = RecordingBundleSource(entries: [.doctorReport, .logs])
        let writer = RecordingArchiveWriter()
        let engine = SupportBundleEngine(
            sources: [source],
            clock: FixedSupportBundleClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
            archiveWriter: writer
        )
        let archiveURL = temporaryArchiveURL()

        let plan = engine.preview()

        XCTAssertEqual(source.collectCalls, [])
        XCTAssertEqual(plan.entries.map(\.logicalID), ["doctor-report", "logs"])
        XCTAssertEqual(writer.writeCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertEqual(plan.excludedSensitiveCategories, [
            "clipboard",
            "credentials",
            "keychain-values",
            "request-response-bodies",
            "shell-history",
            "user-documents"
        ])
    }

    func testCreationUsesExactlyTheApprovedPlan() throws {
        let source = RecordingBundleSource(entries: [.doctorReport, .logs, .config])
        let engine = SupportBundleEngine(
            sources: [source],
            clock: FixedSupportBundleClock(date: Date(timeIntervalSince1970: 1_700_000_000)),
            redactor: SensitiveDataRedactor(exactSecrets: [], homeDirectory: "/Users/synthetic")
        )
        let plan = engine.preview()
        let selected = plan.selecting(logicalIDs: ["doctor-report"])
        let archive = temporaryArchiveURL()

        _ = try engine.create(plan: selected, to: archive)

        XCTAssertEqual(source.collectCalls, ["doctor-report"])
        let extracted = try extractEntries(from: archive)
        XCTAssertEqual(extracted.map(\.name), ["doctor-report.json"])
    }

    func testAlteredAndUnknownPlansAreRejectedBeforeCollection() throws {
        let source = RecordingBundleSource(entries: [.doctorReport])
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
    }

    func testDecodedArchiveContainsNoPlantedSecretsOrPrivatePaths() throws {
        let connectorToken = "capability-token-synthetic-123"
        let ngrokToken = "2f7b8e3c9a1d4e6f8a0b2c4d6e8f0a1b"
        let connectorURL = "https://connector.example.test/\(connectorToken)/mcp?token=\(connectorToken)"
        let payload = """
        {"authorization":"Bearer \(connectorToken)","connectorURL":"\(connectorURL)","token":"\(connectorToken)","path":"/Users/synthetic/Documents/private.txt","nested":{"secret":"\(ngrokToken)"}}
        """
        let log = "remote=\(connectorURL) ngrok_authtoken=\(ngrokToken) path=/Users/synthetic/Documents/private.txt"
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
        let source = RecordingBundleSource(entries: [.doctorReport, .credential])
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
        sourceURL: URL? = nil,
        approvedRoot: URL? = nil
    ) -> FixtureEntry {
        FixtureEntry(
            plan: SupportBundleEntryPlan(
                sourceID: "recording",
                logicalID: logicalID,
                archivePath: archivePath,
                category: "diagnostic",
                reason: "deterministic fixture",
                expectedRedaction: "canonical redaction",
                approximateSizeBytes: data.count
            ),
            data: data,
            sourceURL: sourceURL,
            approvedRoot: approvedRoot
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
            options: [.skipsHiddenFiles]
        )
        var result: [(name: String, data: Data)] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory != true, values.isSymbolicLink != true else { continue }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            result.append((relative, try Data(contentsOf: url)))
        }
        return result.sorted { $0.name < $1.name }
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
            approvedRoot: nil
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
            approvedRoot: nil
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
            approvedRoot: nil
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
            approvedRoot: nil
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
            archivePath: entry.plan.archivePath,
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
