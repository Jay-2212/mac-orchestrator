import Foundation
import Network

protocol NetworkPathMonitoring: AnyObject {
    func start(onAvailabilityChanged: @escaping @Sendable (Bool) -> Void)
    func stop()
}

/// Production Network.framework adapter. It exposes only a coalesced usable
/// versus unusable signal; interface details never become lifecycle state.
final class SystemNetworkPathMonitor: @unchecked Sendable, NetworkPathMonitoring {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?
    private var lastAvailability: Bool?
    private var started = false
    private var stopped = false

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        queue: DispatchQueue = DispatchQueue(
            label: "com.jay.mac-orchestrator.network-path",
            qos: .utility
        )
    ) {
        self.monitor = monitor
        self.queue = queue
    }

    func start(onAvailabilityChanged: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        guard !started, !stopped else {
            lock.unlock()
            return
        }
        started = true
        handler = onAvailabilityChanged
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            self?.publish(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        handler = nil
        lock.unlock()
        monitor.cancel()
    }

    private func publish(_ available: Bool) {
        let callback: (@Sendable (Bool) -> Void)?
        lock.lock()
        guard lastAvailability != available else {
            lock.unlock()
            return
        }
        lastAvailability = available
        callback = handler
        lock.unlock()
        callback?(available)
    }
}

/// Deterministic fake used by lifecycle/capability tests. Calls to `emit`
/// represent the already-reduced Network.framework availability state.
final class DeterministicNetworkPathMonitor: @unchecked Sendable, NetworkPathMonitoring {
    private var handler: (@Sendable (Bool) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var emittedValues: [Bool] = []
    private var lastAvailability: Bool?
    private var stopped = false

    func start(onAvailabilityChanged: @escaping @Sendable (Bool) -> Void) {
        guard handler == nil, !stopped else { return }
        handler = onAvailabilityChanged
        startCount += 1
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        stopCount += 1
        handler = nil
    }

    func emit(_ available: Bool) {
        guard !stopped, lastAvailability != available else { return }
        lastAvailability = available
        emittedValues.append(available)
        handler?(available)
    }
}
