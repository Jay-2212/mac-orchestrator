import Foundation
import XCTest
@testable import MacOrchestrator

final class ConfigurationStoreTests: XCTestCase {
    func testLoadOrCreateWritesFreshConfigurationInInjectedDirectory() throws {
        let directory = try makeTemporaryDirectory()
        let store = ConfigurationStore(directoryURL: directory, ownerIDProvider: { "owner-1" })

        let configuration = try store.loadOrCreate()

        XCTAssertEqual(configuration.ownerID, "owner-1")
        XCTAssertEqual(configuration.localMCPPort, 8000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.configurationURL.path))
    }

    func testSecondSaveBacksUpPreviousPrimaryBeforeReplacingIt() throws {
        let store = try makeStore()
        var first = try store.loadOrCreate()
        first.localMCPPort = 8123
        _ = try store.save(first)

        var second = first
        second.localMCPPort = 9123
        _ = try store.save(second)

        let backupData = try Data(contentsOf: store.backupURL)
        let backedUp = try JSONDecoder().decode(AppConfiguration.self, from: backupData)
        XCTAssertEqual(backedUp.localMCPPort, 8123)
        XCTAssertEqual(try store.load().localMCPPort, 9123)
    }

    func testCorruptPrimaryIsPreservedAndKnownGoodBackupIsRecovered() throws {
        let store = try makeStore()
        var configuration = try store.loadOrCreate()
        configuration.localMCPPort = 8123
        _ = try store.save(configuration)
        configuration.localMCPPort = 9123
        _ = try store.save(configuration)
        let knownGoodBackup = try Data(contentsOf: store.backupURL)

        try Data("{not-json".utf8).write(to: store.configurationURL)

        let recovered = try store.load()

        XCTAssertEqual(recovered.localMCPPort, 8123)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.configurationURL.path + ".corrupt"))
        XCTAssertEqual(try Data(contentsOf: store.backupURL), knownGoodBackup)
    }

    func testUnsupportedFutureSchemaIsRejectedWithoutDefaultReset() throws {
        let store = try makeStore()
        let future = Data("{\"schemaVersion\":99}".utf8)
        try future.write(to: store.configurationURL)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? ConfigurationStoreError, .unsupportedSchema(99))
        }
        XCTAssertEqual(try Data(contentsOf: store.configurationURL), future)
    }

    func testInvalidPrimaryFailsClosedWhenNoBackupExists() throws {
        let store = try makeStore()
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.localMCPPort = 70000
        try JSONEncoder().encode(configuration).write(to: store.configurationURL)

        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.configurationURL.path + ".corrupt"))
    }

    func testSchemaMigrationIsIdempotent() throws {
        let store = try makeStore()
        let legacy = Data(
            """
            {
              "generation": 4,
              "controlProfile": "guided",
              "localMCPPort": 8787,
              "ownerID": "legacy-owner",
              "process": { "serverDesired": true, "tunnelDesired": false }
            }
            """.utf8
        )
        try legacy.write(to: store.configurationURL)

        let first = try store.load()
        let migratedData = try Data(contentsOf: store.configurationURL)
        let second = try store.load()

        XCTAssertEqual(first.schemaVersion, 1)
        XCTAssertEqual(first.localMCPPort, 8787)
        XCTAssertEqual(first.ownerID, "legacy-owner")
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: store.configurationURL), migratedData)
        XCTAssertEqual(first.onboarding.migrationMarkers, ["schema-v1"])
    }

    func testUpdateIncrementsGenerationOnlyForAChangedConfiguration() throws {
        let store = try makeStore()
        let initial = try store.loadOrCreate()

        let changed = try store.update { configuration in
            configuration.localMCPPort = 8765
        }
        let unchanged = try store.update { _ in }

        XCTAssertEqual(changed.generation, initial.generation + 1)
        XCTAssertEqual(unchanged.generation, changed.generation)
    }

    private func makeStore(file: StaticString = #filePath, line: UInt = #line) throws -> ConfigurationStore {
        let directory = try makeTemporaryDirectory(file: file, line: line)
        return ConfigurationStore(directoryURL: directory, ownerIDProvider: { "owner-test" })
    }

    private func makeTemporaryDirectory(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOrchestratorTests-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
