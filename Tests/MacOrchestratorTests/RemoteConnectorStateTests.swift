import Foundation
import XCTest
@testable import MacOrchestrator

final class RemoteConnectorStateTests: XCTestCase {
    func testLoadOrCreateWritesOnlyNonsecretVersionedState() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)

        let state = try store.loadOrCreate(provider: .ngrok)

        XCTAssertEqual(state.schemaVersion, RemoteConnectorStateV1.currentSchemaVersion)
        XCTAssertEqual(state.provider, .ngrok)
        XCTAssertEqual(state.connectorCredentialGeneration, 0)
        let data = try Data(contentsOf: store.stateURL)
        let serialized = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(serialized.contains("connector-capability-token"))
        XCTAssertFalse(serialized.contains("ngrok-authtoken"))
    }

    func testAtomicRoundTripPreservesValidatedStateAndLeavesNoTemporaryStateFile() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)
        var state = try store.loadOrCreate(provider: .ngrok)
        state.connectorCredentialGeneration = 1
        state.lastRemoteResult = .ready
        state.lastVerifiedPublicOrigin = try RemotePublicOrigin("https://example.ngrok.app")
        state.lastSuccessfulRemoteProbeAt = Date(timeIntervalSince1970: 1_700_000_000)
        state.handoffReceipt = RemoteConnectorHandoffReceipt(
            connectorCredentialGeneration: 1,
            publicOrigin: try RemotePublicOrigin("https://example.ngrok.app"),
            handedOffAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        try store.save(state)
        let loaded = try XCTUnwrap(try store.load())

        XCTAssertEqual(loaded, state)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["remote-connector-state-v1.json"])
    }

    func testStoreUsesPrivateDirectoryAndFilePermissions() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)

        _ = try store.loadOrCreate(provider: .ngrok)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.stateURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testUnsupportedSchemaIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try Data("{\"schemaVersion\":99}".utf8).write(to: store.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.stateURL.path)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? RemoteConnectorStateStoreError, .unsupportedSchema(99))
        }
    }

    func testMalformedStateIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try Data("not-json".utf8).write(to: store.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.stateURL.path)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? RemoteConnectorStateStoreError, .malformed)
        }
    }

    func testUnknownStateFieldIsRejectedInsteadOfIgnored() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let data = Data("{\"schemaVersion\":1,\"provider\":\"ngrok\",\"unexpectedToken\":\"secret\"}".utf8)
        try data.write(to: store.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.stateURL.path)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? RemoteConnectorStateStoreError, .malformed)
        }
    }

    func testSymlinkedDirectoryIsRejected() throws {
        let root = try makeTemporaryDirectory()
        let real = root.appendingPathComponent("real", isDirectory: true)
        let redirected = root.appendingPathComponent("redirected", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: real)

        let store = RemoteConnectorStateStore(directoryURL: redirected)

        XCTAssertThrowsError(try store.loadOrCreate(provider: .ngrok)) { error in
            XCTAssertEqual(error as? RemoteConnectorStateStoreError, .unsafePath)
        }
    }

    func testSymlinkedStateFileIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)
        _ = try store.loadOrCreate(provider: .ngrok)
        let target = directory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createSymbolicLink(at: store.stateURL, withDestinationURL: target)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? RemoteConnectorStateStoreError, .unsafePath)
        }
    }

    func testCredentialBearingPublicOriginIsRejected() {
        XCTAssertThrowsError(try RemotePublicOrigin("https://secret@example.ngrok.app/abc/mcp"))
        XCTAssertThrowsError(try RemotePublicOrigin("https://example.ngrok.app/token/mcp"))
        XCTAssertThrowsError(try RemotePublicOrigin(String(repeating: "ab", count: 32)))
    }

    func testGenerationRegressionIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)
        var first = try store.loadOrCreate(provider: .ngrok)
        first.connectorCredentialGeneration = 2
        try store.save(first)
        var lower = first
        lower.connectorCredentialGeneration = 1

        XCTAssertThrowsError(try store.save(lower)) { error in
            XCTAssertEqual(error as? RemoteConnectorStateStoreError, .generationRegression)
        }
    }

    func testFreshStateHasNoReceiptAndReadyDoesNotRequireCurrentHandoff() throws {
        let fresh = RemoteConnectorStateV1.fresh(provider: .ngrok)
        XCTAssertEqual(fresh.connectorCredentialGeneration, 0)
        XCTAssertNil(fresh.handoffReceipt)
        XCTAssertEqual(fresh.clientHandoffClassification, .notAvailable)

        var ready = fresh
        ready.connectorCredentialGeneration = 1
        ready.lastVerifiedPublicOrigin = try RemotePublicOrigin("https://example.ngrok.app")
        ready.lastSuccessfulRemoteProbeAt = Date(timeIntervalSince1970: 1_700_000_000)
        ready.lastRemoteResult = .ready

        XCTAssertNoThrow(try ready.validated())
        XCTAssertEqual(ready.clientHandoffClassification, .notAvailable)
    }

    func testReceiptClassificationTracksGenerationAndOriginIndependentlyOfReadiness() throws {
        let firstOrigin = try RemotePublicOrigin("https://one.ngrok.app")
        let secondOrigin = try RemotePublicOrigin("https://two.ngrok.app")
        let receipt = RemoteConnectorHandoffReceipt(
            connectorCredentialGeneration: 1,
            publicOrigin: firstOrigin,
            handedOffAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var state = try RemoteConnectorStateV1(
            provider: .ngrok,
            connectorCredentialGeneration: 1,
            lastVerifiedPublicOrigin: firstOrigin,
            lastSuccessfulRemoteProbeAt: Date(timeIntervalSince1970: 1_700_000_001),
            lastRemoteResult: .ready,
            handoffReceipt: receipt
        )

        XCTAssertEqual(state.clientHandoffClassification, .unchanged)

        state.connectorCredentialGeneration = 2
        XCTAssertEqual(state.clientHandoffClassification, .changed)

        state.connectorCredentialGeneration = 1
        state.lastVerifiedPublicOrigin = secondOrigin
        XCTAssertEqual(state.clientHandoffClassification, .changed)
        XCTAssertNoThrow(try state.validated())
    }

    func testLegacyScalarHandoffDecodesAsNoReceipt() throws {
        let data = Data(
            #"{"schemaVersion":1,"provider":"ngrok","connectorCredentialGeneration":2,"pendingConnectorCredentialGeneration":null,"recoveryPhase":"stable","lastVerifiedPublicOrigin":"https://example.ngrok.app","lastSuccessfulRemoteProbeAt":"2023-11-14T22:13:20Z","lastRemoteResult":"ready","lastConnectorHandoffGeneration":2}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(RemoteConnectorStateV1.self, from: data)

        XCTAssertNil(state.handoffReceipt)
        XCTAssertEqual(state.clientHandoffClassification, .notAvailable)
    }

    private func makeTemporaryDirectory(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-state-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
