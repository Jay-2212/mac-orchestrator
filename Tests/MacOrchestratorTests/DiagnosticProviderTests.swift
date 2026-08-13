import Foundation
import XCTest
@testable import MacOrchestrator

final class DiagnosticProviderTests: XCTestCase {
    func testDiagnosticPathSafetyAcceptsOnlyVerifiedVarAliasAndRejectsUserSymlinks() throws {
        XCTAssertTrue(DiagnosticPathSafety.isSafe(FileManager.default.temporaryDirectory))
        XCTAssertFalse(DiagnosticPathSafety.isSafe(URL(fileURLWithPath: "/tmp")))

        let root = try makeTemporaryDirectory()
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertFalse(DiagnosticPathSafety.isSafe(link.appendingPathComponent("child")))
    }

    func testConfigurationProviderDoesNotCreateMissingConfigurationOrDirectory() throws {
        let root = try makeTemporaryDirectory()
        let support = root.appendingPathComponent("Mac Orchestrator", isDirectory: true)
        let provider = ReadOnlyConfigurationDiagnosticProvider(directoryURL: support)

        let facts = try provider.inspect()

        XCTAssertFalse(facts.primary.exists)
        XCTAssertEqual(facts.primary.state, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    func testConfigurationProviderReportsValidBackupWithoutRestoringIt() throws {
        let support = try makeTemporaryDirectory()
        let backup = support.appendingPathComponent("config.json.backup")
        try JSONEncoder().encode(AppConfiguration.fresh(ownerID: "backup-owner")).write(to: backup)
        let provider = ReadOnlyConfigurationDiagnosticProvider(directoryURL: support)

        let facts = try provider.inspect()

        XCTAssertTrue(facts.backup.valid)
        XCTAssertEqual(facts.backup.state, .valid)
        XCTAssertFalse(facts.primary.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("config.json").path))
    }

    func testMalformedPrimaryAndInvalidBackupRemainUnchanged() throws {
        let support = try makeTemporaryDirectory()
        let primary = support.appendingPathComponent("config.json")
        let backup = support.appendingPathComponent("config.json.backup")
        let primaryBytes = Data("{malformed".utf8)
        let backupBytes = Data("{\"schemaVersion\":99}".utf8)
        try primaryBytes.write(to: primary)
        try backupBytes.write(to: backup)

        let facts = try ReadOnlyConfigurationDiagnosticProvider(directoryURL: support).inspect()

        XCTAssertEqual(facts.primary.state, .malformed)
        XCTAssertFalse(facts.primary.valid)
        XCTAssertEqual(facts.backup.state, .unsupported)
        XCTAssertFalse(facts.backup.valid)
        XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
        XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
    }

    func testConfigurationProviderClassifiesInvalidAndCountsCorruptEvidenceWithoutMutation() throws {
        let support = try makeTemporaryDirectory()
        var invalid = AppConfiguration.fresh(ownerID: "owner")
        invalid.localMCPPort = 0
        let primary = support.appendingPathComponent("config.json")
        try JSONEncoder().encode(invalid).write(to: primary)
        try Data("old-corrupt-primary".utf8).write(
            to: support.appendingPathComponent("config.json.corrupt-1")
        )
        try Data("old-corrupt-primary-2".utf8).write(
            to: support.appendingPathComponent("config.json.corrupt-2")
        )

        let facts = try ReadOnlyConfigurationDiagnosticProvider(directoryURL: support).inspect()

        XCTAssertEqual(facts.primary.state, .invalid)
        XCTAssertEqual(facts.corruptEvidenceCount, 2)
        XCTAssertTrue(facts.primary.exists)
        XCTAssertFalse(facts.primary.isSymlink)
        XCTAssertEqual(try Data(contentsOf: primary), try JSONEncoder().encode(invalid))
    }

    func testConfigurationProviderReportsSymlinkMetadataWithoutChangingTarget() throws {
        let root = try makeTemporaryDirectory()
        let support = root.appendingPathComponent("Mac Orchestrator", isDirectory: true)
        let target = root.appendingPathComponent("real-config.json")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let configuration = AppConfiguration.fresh(ownerID: "symlink-owner")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode(configuration)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: support.appendingPathComponent("config.json"),
            withDestinationURL: target
        )

        let facts = try ReadOnlyConfigurationDiagnosticProvider(directoryURL: support).inspect()

        XCTAssertTrue(facts.primary.exists)
        XCTAssertTrue(facts.primary.isSymlink)
        XCTAssertTrue(facts.primary.valid)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testKeychainPresenceProviderUsesExistenceOnlyQueriesForCurrentCoreItems() throws {
        let query = RecordingKeychainPresenceQuery(defaultResult: .absent)
        query.results[KeychainPresenceItem.connectorToken] = .present
        let provider = ReadOnlySystemKeychainPresenceProvider(querying: query)

        let facts = try provider.inspect()

        XCTAssertEqual(facts.presence(for: .connectorToken), .present)
        XCTAssertEqual(facts.presence(for: .ngrokAuthtoken), .absent)
        XCTAssertFalse(query.requests.isEmpty)
        XCTAssertTrue(query.requests.allSatisfy { !$0.requestsData })
        XCTAssertTrue(query.requests.allSatisfy { request in
            request.item != .meridianTelegramBotToken &&
                request.item != .meridianTelegramWebhookSecret
        })
        XCTAssertEqual(
            Set(query.requests.map(\.item)),
            Set([.connectorToken, .ngrokAuthtoken, .telegramSendBotToken, .telegramSendChatID])
        )
    }

    func testKeychainPresenceProviderPreservesOnlyBoundedPresenceStates() throws {
        let query = RecordingKeychainPresenceQuery(defaultResult: .inaccessible)
        query.results[KeychainPresenceItem.connectorToken] = .present
        query.results[KeychainPresenceItem.ngrokAuthtoken] = .absent

        let facts = try ReadOnlySystemKeychainPresenceProvider(querying: query).inspect()

        XCTAssertEqual(facts.presence(for: .connectorToken), .present)
        XCTAssertEqual(facts.presence(for: .ngrokAuthtoken), .absent)
        XCTAssertEqual(facts.presence(for: .telegramSendBotToken), .inaccessible)
        XCTAssertTrue(facts.states.values.allSatisfy { [.present, .absent, .inaccessible].contains($0) })
    }

    func testDiagnosticFactContractsCarrySafeValueFactsOnly() {
        let facts = InstalledReleaseFacts(
            releaseVersion: "1.2.3",
            helper: CodeSignFacts(isSigned: true, isAdHoc: false),
            runtime: RuntimeFacts(runtimePresent: true, payloadPresent: true)
        )

        XCTAssertEqual(facts.releaseVersion, "1.2.3")
        XCTAssertTrue(facts.helper.isSigned)
        XCTAssertTrue(facts.runtime.payloadPresent)
    }

    private func makeTemporaryDirectory(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOrchestratorDiagnosticProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private final class RecordingKeychainPresenceQuery: KeychainPresenceQuerying {
        private(set) var requests: [KeychainPresenceQuery] = []
        var results: [KeychainPresenceItem: KeychainPresence] = [:]
        let defaultResult: KeychainPresence

        init(defaultResult: KeychainPresence) {
            self.defaultResult = defaultResult
        }

        func query(_ request: KeychainPresenceQuery) -> KeychainPresence {
            requests.append(request)
            return results[request.item] ?? defaultResult
        }
    }
}
