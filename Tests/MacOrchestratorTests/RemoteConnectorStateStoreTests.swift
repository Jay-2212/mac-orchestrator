import Foundation
import XCTest
@testable import MacOrchestrator

final class RemoteConnectorStateStoreTests: XCTestCase {
    func testExplicitHandoffRecordsOnlyCurrentAuthenticatedIdentity() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)
        let origin = try RemotePublicOrigin("https://example.ngrok.app")
        var state = try store.loadOrCreate(provider: .ngrok)
        state.connectorCredentialGeneration = 1
        state.lastVerifiedPublicOrigin = origin
        state.lastSuccessfulRemoteProbeAt = Date(timeIntervalSince1970: 1_700_000_000)
        state.lastRemoteResult = .ready
        try store.save(state)

        let handedOffAt = Date(timeIntervalSince1970: 1_700_000_100)
        let recorded = try store.recordHandoff(
            generation: 1,
            origin: origin,
            at: handedOffAt
        )

        XCTAssertEqual(
            recorded.handoffReceipt,
            RemoteConnectorHandoffReceipt(
                connectorCredentialGeneration: 1,
                publicOrigin: origin,
                handedOffAt: handedOffAt
            )
        )
        XCTAssertEqual(recorded.clientHandoffClassification, .unchanged)
        let serialized = String(
            decoding: try Data(contentsOf: store.stateURL),
            as: UTF8.self
        )
        XCTAssertFalse(serialized.contains("lastConnectorHandoffGeneration"))
        XCTAssertFalse(serialized.contains("/mcp"))
    }

    func testStaleHandoffGenerationOrOriginIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)
        let currentOrigin = try RemotePublicOrigin("https://example.ngrok.app")
        var state = try store.loadOrCreate(provider: .ngrok)
        state.connectorCredentialGeneration = 2
        state.lastVerifiedPublicOrigin = currentOrigin
        state.lastSuccessfulRemoteProbeAt = Date(timeIntervalSince1970: 1_700_000_000)
        state.lastRemoteResult = .ready
        try store.save(state)

        XCTAssertThrowsError(
            try store.recordHandoff(
                generation: 1,
                origin: currentOrigin,
                at: Date(timeIntervalSince1970: 1_700_000_001)
            )
        ) { error in
            XCTAssertEqual(error as? RemoteConnectorStateStoreError, .staleHandoff)
        }

        XCTAssertThrowsError(
            try store.recordHandoff(
                generation: 2,
                origin: try RemotePublicOrigin("https://other.ngrok.app"),
                at: Date(timeIntervalSince1970: 1_700_000_001)
            )
        ) { error in
            XCTAssertEqual(error as? RemoteConnectorStateStoreError, .staleHandoff)
        }
    }

    func testPendingGenerationCannotBeSilentlyClearedBeforeCutover() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)
        var pending = try store.loadOrCreate(provider: .ngrok)
        pending.pendingConnectorCredentialGeneration = 1
        pending.recoveryPhase = .cutoverPendingValidation
        pending.lastRemoteResult = .notReady
        try store.save(pending)

        var stale = pending
        stale.pendingConnectorCredentialGeneration = nil
        stale.recoveryPhase = .stable
        XCTAssertThrowsError(try store.save(stale)) { error in
            XCTAssertEqual(error as? RemoteConnectorStateStoreError, .generationRegression)
        }
    }

    func testHandoffReceiptGenerationAndTimeCannotRegress() throws {
        let directory = try makeTemporaryDirectory()
        let store = RemoteConnectorStateStore(directoryURL: directory)
        let origin = try RemotePublicOrigin("https://example.ngrok.app")
        var state = try store.loadOrCreate(provider: .ngrok)
        state.connectorCredentialGeneration = 2
        state.lastVerifiedPublicOrigin = origin
        state.lastSuccessfulRemoteProbeAt = Date(timeIntervalSince1970: 1_700_000_000)
        state.lastRemoteResult = .ready
        state.handoffReceipt = RemoteConnectorHandoffReceipt(
            connectorCredentialGeneration: 2,
            publicOrigin: origin,
            handedOffAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        try store.save(state)

        var stale = state
        stale.handoffReceipt = RemoteConnectorHandoffReceipt(
            connectorCredentialGeneration: 1,
            publicOrigin: origin,
            handedOffAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        XCTAssertThrowsError(try store.save(stale)) { error in
            XCTAssertEqual(error as? RemoteConnectorStateStoreError, .generationRegression)
        }
    }

    private func makeTemporaryDirectory(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-state-store-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
