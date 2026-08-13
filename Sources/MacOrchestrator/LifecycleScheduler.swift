import Foundation

@MainActor
final class LifecycleScheduledHandle: Identifiable {
    let id: UUID
    let date: Date
    let label: String?

    private(set) var isCancelled = false
    private(set) var hasFired = false
    var onCancel: (() -> Void)?

    init(id: UUID = UUID(), date: Date, label: String?) {
        self.id = id
        self.date = date
        self.label = label
    }

    func cancel() {
        guard !isCancelled, !hasFired else { return }
        isCancelled = true
        onCancel?()
        onCancel = nil
    }

    fileprivate func markFired() {
        guard !isCancelled else { return }
        hasFired = true
        onCancel = nil
    }
}

typealias LifecycleSchedulerHandle = LifecycleScheduledHandle

@MainActor
protocol LifecycleSchedulerProtocol: AnyObject {
    var now: Date { get }

    @discardableResult
    func schedule(
        at date: Date,
        label: String?,
        operation: @escaping @MainActor () -> Void
    ) -> LifecycleScheduledHandle

    func cancel(_ handle: LifecycleScheduledHandle)
}

extension LifecycleSchedulerProtocol {
    @discardableResult
    func schedule(
        at date: Date,
        operation: @escaping @MainActor () -> Void
    ) -> LifecycleScheduledHandle {
        schedule(at: date, label: nil, operation: operation)
    }
}

/// The production scheduler. All lifecycle callbacks return to the main actor,
/// where ProcessSupervisor and the state machine are serialized.
@MainActor
final class MainLifecycleScheduler: LifecycleSchedulerProtocol {
    var now: Date { Date() }

    @discardableResult
    func schedule(
        at date: Date,
        label: String?,
        operation: @escaping @MainActor () -> Void
    ) -> LifecycleScheduledHandle {
        let handle = LifecycleScheduledHandle(date: date, label: label)
        let workItem = DispatchWorkItem { [weak handle] in
            Task { @MainActor [weak handle] in
                guard let handle, !handle.isCancelled else { return }
                handle.markFired()
                operation()
            }
        }
        handle.onCancel = { workItem.cancel() }
        let delay = max(0, date.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return handle
    }

    func cancel(_ handle: LifecycleScheduledHandle) {
        handle.cancel()
    }
}

typealias ProductionLifecycleScheduler = MainLifecycleScheduler
typealias LifecycleScheduler = MainLifecycleScheduler

/// A logical-clock scheduler for lifecycle tests. It never sleeps and does
/// not use a wall-clock timer.
@MainActor
final class TestLifecycleScheduler: LifecycleSchedulerProtocol {
    struct PendingWork: Equatable, Identifiable {
        let id: UUID
        let date: Date
        let label: String?
        fileprivate let sequence: UInt64
    }

    private struct Entry {
        let handle: LifecycleScheduledHandle
        let sequence: UInt64
        let operation: @MainActor () -> Void
    }

    private(set) var now: Date
    private var entries: [UUID: Entry] = [:]
    private var retiredOperations: [UUID: @MainActor () -> Void] = [:]
    private var nextSequence: UInt64 = 0

    init(start: Date = Date(timeIntervalSince1970: 0)) {
        now = start
    }

    convenience init(now: Date) {
        self.init(start: now)
    }

    @discardableResult
    func schedule(
        at date: Date,
        label: String?,
        operation: @escaping @MainActor () -> Void
    ) -> LifecycleScheduledHandle {
        let handle = LifecycleScheduledHandle(date: date, label: label)
        let sequence = nextSequence
        nextSequence &+= 1
        entries[handle.id] = Entry(handle: handle, sequence: sequence, operation: operation)
        return handle
    }

    func cancel(_ handle: LifecycleScheduledHandle) {
        handle.cancel()
        if let entry = entries.removeValue(forKey: handle.id) {
            retiredOperations[handle.id] = entry.operation
        }
    }

    var pending: [PendingWork] {
        entries.values
            .filter { !$0.handle.isCancelled && !$0.handle.hasFired }
            .map {
                PendingWork(
                    id: $0.handle.id,
                    date: $0.handle.date,
                    label: $0.handle.label,
                    sequence: $0.sequence
                )
            }
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.sequence < rhs.sequence }
                return lhs.date < rhs.date
            }
    }

    var pendingHandles: [LifecycleScheduledHandle] {
        pending.compactMap { entries[$0.id]?.handle }
    }

    func pendingWork(for component: ManagedComponentID) -> [PendingWork] {
        pending.filter { $0.label == component.rawValue }
    }

    func isPending(_ handle: LifecycleScheduledHandle) -> Bool {
        entries[handle.id] != nil && !handle.isCancelled && !handle.hasFired
    }

    func advance(by interval: TimeInterval) {
        advance(to: now.addingTimeInterval(interval))
    }

    func advance(to date: Date) {
        guard date >= now else {
            // The logical clock is monotonic. A caller that presents an old
            // timestamp must not make retry windows appear newer or cause
            // already-fired work to become eligible again.
            return
        }
        while let next = pending.first, next.date <= date {
            now = next.date
            guard let entry = entries[next.id] else { continue }
            fire(entry.handle)
        }
        now = date
    }

    func fire(_ handle: LifecycleScheduledHandle) {
        guard let entry = entries.removeValue(forKey: handle.id),
              !handle.isCancelled,
              !handle.hasFired else { return }
        handle.markFired()
        entry.operation()
    }

    /// Test-only escape hatch for simulating a callback that was already
    /// queued when its handle was retired. The callback still has to reject
    /// itself using lifecycle generation/desired-state/quiesce fences.
    func fireIgnoringCancellation(_ handle: LifecycleScheduledHandle) {
        guard handle.isCancelled, !handle.hasFired else { return }
        let operation: (@MainActor () -> Void)? =
            entries.removeValue(forKey: handle.id)?.operation
            ?? retiredOperations.removeValue(forKey: handle.id)
        operation?()
    }

    func firePending(for component: ManagedComponentID) {
        guard let work = pendingWork(for: component).first,
              let entry = entries[work.id] else { return }
        fire(entry.handle)
    }
}

typealias DeterministicLifecycleScheduler = TestLifecycleScheduler
