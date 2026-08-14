import Foundation
import XCTest
@testable import MacOrchestrator

final class NetworkPathMonitorTests: XCTestCase {
    func testDeterministicMonitorCoalescesDuplicateAvailabilityEvents() {
        let monitor = DeterministicNetworkPathMonitor()
        let recorder = EventRecorder()

        monitor.start { value in recorder.append(value) }
        monitor.emit(true)
        monitor.emit(true)
        monitor.emit(false)
        monitor.emit(false)

        XCTAssertEqual(recorder.values, [true, false])
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(monitor.emittedValues, [true, false])
    }

    func testStoppingMonitorCancelsCallbacksAndIsIdempotent() {
        let monitor = DeterministicNetworkPathMonitor()
        let recorder = EventRecorder()
        monitor.start { value in recorder.append(value) }

        monitor.stop()
        monitor.stop()
        monitor.emit(true)

        XCTAssertEqual(monitor.stopCount, 1)
        XCTAssertTrue(recorder.values.isEmpty)
        XCTAssertTrue(monitor.emittedValues.isEmpty)
    }

    func testStartingAfterStopDoesNotCreateASecondMonitorOwner() {
        let monitor = DeterministicNetworkPathMonitor()
        monitor.start { _ in }
        monitor.stop()
        monitor.start { _ in }

        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(monitor.stopCount, 1)
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues = [Bool]()

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: Bool) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}
