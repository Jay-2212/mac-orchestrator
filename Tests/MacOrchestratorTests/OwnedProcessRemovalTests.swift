import Darwin
import Foundation
import XCTest
@testable import MacOrchestrator

final class OwnedProcessRemovalTests: XCTestCase {
    func testCorrectlyOwnedProcessesAreTerminatedAndStateIsRemoved() throws {
        let fixture = try Fixture()
        let inspector = RecordingOwnedProcessInspector(observations: [
            101: OwnedProcessObservation(
                commandLine: "python automac_mcp.py --managed-owner owner-1",
                processGroupID: 101
            ),
            202: OwnedProcessObservation(
                commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-1",
                processGroupID: 202
            ),
        ])
        let terminator = RecordingOwnedProcessTerminator()
        let adapter = fixture.adapter(inspector: inspector, terminator: terminator)
        try fixture.writeState(OwnedProcessState(ownerID: "owner-1", serverPID: 101, tunnelPID: 202))

        try adapter.removeOwnedProcesses()

        XCTAssertEqual(terminator.calls.map(\.pid), [101, 202])
        XCTAssertEqual(terminator.calls.map(\.component), [.server, .tunnel])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testAlreadyStoppedAndStalePIDsAreToleratedAndStateIsRemoved() throws {
        let fixture = try Fixture()
        let inspector = RecordingOwnedProcessInspector(observations: [:])
        let terminator = RecordingOwnedProcessTerminator()
        let adapter = fixture.adapter(inspector: inspector, terminator: terminator)
        try fixture.writeState(OwnedProcessState(ownerID: "owner-1", serverPID: 101, tunnelPID: nil))

        try adapter.removeOwnedProcesses()

        XCTAssertTrue(terminator.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testPIDReuseAndWrongOwnerMarkerFailClosedWithoutTermination() throws {
        for commandLine in [
            "python automac_mcp.py --managed-owner owner-2",
            "python unrelated-process",
        ] {
            let fixture = try Fixture()
            let inspector = RecordingOwnedProcessInspector(observations: [
                101: OwnedProcessObservation(commandLine: commandLine, processGroupID: 101)
            ])
            let terminator = RecordingOwnedProcessTerminator()
            let adapter = fixture.adapter(inspector: inspector, terminator: terminator)
            try fixture.writeState(OwnedProcessState(ownerID: "owner-1", serverPID: 101, tunnelPID: nil))

            XCTAssertThrowsError(try adapter.removeOwnedProcesses()) { error in
                XCTAssertEqual(error as? UninstallError, .processOwnershipNotProven)
            }
            XCTAssertTrue(terminator.calls.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stateURL.path))
        }
    }

    func testMixedValidityIsPreflightedBeforeAnyProcessIsTerminated() throws {
        let fixture = try Fixture()
        let inspector = RecordingOwnedProcessInspector(observations: [
            101: OwnedProcessObservation(
                commandLine: "python automac_mcp.py --managed-owner owner-1",
                processGroupID: 101
            ),
            202: OwnedProcessObservation(
                commandLine: "ngrok http --metadata mac-orchestrator-owner=owner-2",
                processGroupID: 202
            ),
        ])
        let terminator = RecordingOwnedProcessTerminator()
        let adapter = fixture.adapter(inspector: inspector, terminator: terminator)
        try fixture.writeState(OwnedProcessState(ownerID: "owner-1", serverPID: 101, tunnelPID: 202))

        XCTAssertThrowsError(try adapter.removeOwnedProcesses()) { error in
            XCTAssertEqual(error as? UninstallError, .processOwnershipNotProven)
        }
        XCTAssertTrue(terminator.calls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testStateOwnerMismatchMalformedStateAndDuplicatePIDsFailClosed() throws {
        let mismatch = try Fixture()
        let mismatchAdapter = mismatch.adapter(
            inspector: RecordingOwnedProcessInspector(observations: [:]),
            terminator: RecordingOwnedProcessTerminator()
        )
        try mismatch.writeState(OwnedProcessState(ownerID: "owner-2", serverPID: 101, tunnelPID: nil))
        XCTAssertThrowsError(try mismatchAdapter.removeOwnedProcesses())

        let malformed = try Fixture()
        let malformedAdapter = malformed.adapter(
            inspector: RecordingOwnedProcessInspector(observations: [:]),
            terminator: RecordingOwnedProcessTerminator()
        )
        try Data("{malformed".utf8).write(to: malformed.stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: malformed.stateURL.path)
        XCTAssertThrowsError(try malformedAdapter.removeOwnedProcesses())

        let duplicate = try Fixture()
        let duplicateAdapter = duplicate.adapter(
            inspector: RecordingOwnedProcessInspector(observations: [:]),
            terminator: RecordingOwnedProcessTerminator()
        )
        try duplicate.writeState(OwnedProcessState(ownerID: "owner-1", serverPID: 101, tunnelPID: 101))
        XCTAssertThrowsError(try duplicateAdapter.removeOwnedProcesses())
    }

    func testSymlinkedStateIsRejectedAndUnrelatedStateIsNotDeleted() throws {
        let fixture = try Fixture()
        let target = fixture.root.appendingPathComponent("target-state.json")
        try fixture.writeState(OwnedProcessState(ownerID: "owner-1", serverPID: nil, tunnelPID: 101), at: target)
        try FileManager.default.createSymbolicLink(at: fixture.stateURL, withDestinationURL: target)
        let adapter = fixture.adapter(
            inspector: RecordingOwnedProcessInspector(observations: [:]),
            terminator: RecordingOwnedProcessTerminator()
        )

        XCTAssertThrowsError(try adapter.removeOwnedProcesses()) { error in
            XCTAssertEqual(error as? UninstallError, .processOwnershipNotProven)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testStateArtifactRemainsWhenRemovalWasNotExplicitlyRequested() throws {
        let fixture = try Fixture()
        try fixture.writeState(OwnedProcessState(ownerID: "owner-1", serverPID: nil, tunnelPID: nil), allowEmpty: true)
        let engine = try UninstallEngine(
            supportDirectory: fixture.root,
            logsDirectory: fixture.home.appendingPathComponent("Library/Logs/Mac Orchestrator", isDirectory: true),
            keychain: KeychainStore(client: NoopOwnedProcessKeychainClient()),
            lifecycle: OwnedProcessTestLifecycle(),
            homeDirectory: fixture.home,
            processRemoval: fixture.adapter(
                inspector: RecordingOwnedProcessInspector(observations: [:]),
                terminator: RecordingOwnedProcessTerminator()
            )
        )

        _ = engine.apply(try engine.plan(options: RemovalOptions()))

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    private final class Fixture {
        let root: URL
        let home: URL
        let stateURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("phase3-owned-process-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            stateURL = root.appendingPathComponent("owned-processes.json", isDirectory: false)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("Library/Logs/Mac Orchestrator", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func adapter(
            inspector: any OwnedProcessInspecting,
            terminator: any OwnedProcessTerminating
        ) -> ProductionOwnedProcessRemovalAdapter {
            ProductionOwnedProcessRemovalAdapter(
                ownerID: "owner-1",
                stateURL: stateURL,
                inspector: inspector,
                terminator: terminator
            )
        }

        func writeState(
            _ state: OwnedProcessState,
            at url: URL? = nil,
            allowEmpty: Bool = false
        ) throws {
            if !allowEmpty, state.serverPID == nil && state.tunnelPID == nil {
                XCTFail("test state must contain a PID")
            }
            let destination = url ?? stateURL
            try JSONEncoder().encode(state).write(to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }

    }

    override func setUpWithError() throws {
        try super.setUpWithError()
    }

}

private struct RecordingOwnedProcessObservation: Sendable {
    let pid: Int32
    let component: SupervisorComponent
}

private final class RecordingOwnedProcessInspector: OwnedProcessInspecting, @unchecked Sendable {
    let observations: [Int32: OwnedProcessObservation]

    init(observations: [Int32: OwnedProcessObservation]) {
        self.observations = observations
    }

    func inspect(pid: Int32) throws -> OwnedProcessObservation? {
        observations[pid]
    }
}

private final class RecordingOwnedProcessTerminator: OwnedProcessTerminating, @unchecked Sendable {
    private(set) var calls: [RecordingOwnedProcessObservation] = []

    func terminate(
        pid: Int32,
        component: SupervisorComponent,
        ownerID: String,
        processGroupID: Int32?
    ) throws {
        _ = ownerID
        _ = processGroupID
        calls.append(RecordingOwnedProcessObservation(pid: pid, component: component))
    }
}

private struct NoopOwnedProcessKeychainClient: KeychainClient {
    func read(service: String, account: String) throws -> String? { nil }
    func create(value: String, service: String, account: String) throws {}
    func update(value: String, service: String, account: String) throws {}
}

private struct OwnedProcessTestLifecycle: MaintenanceLifecycleAdapter {
    func quiesce() throws -> MaintenanceQuiesceReceipt {
        MaintenanceQuiesceReceipt(ownerID: "owner-1", remoteStopped: true, localServerStopped: true)
    }

    func restore() throws {}
}
