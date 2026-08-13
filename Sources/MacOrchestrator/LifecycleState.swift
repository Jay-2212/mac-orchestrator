import Foundation

enum ManagedComponentID: String, CaseIterable, Codable, Equatable, Sendable {
    case mcpServer
    case remoteConnector

    var isOptional: Bool {
        self == .remoteConnector
    }
}

enum ComponentDesiredState: String, Codable, Equatable, Sendable {
    case disabled
    case enabled

    var isEnabled: Bool {
        self == .enabled
    }

    init(_ enabled: Bool) {
        self = enabled ? .enabled : .disabled
    }
}

enum ComponentLiveness: String, Codable, Equatable, Sendable {
    case unknown
    case stopped
    case starting
    case running
}

enum ComponentReadiness: String, Codable, Equatable, Sendable {
    case unknown
    case notReady
    case ready
    case waitingForPrerequisites
}

enum ComponentCircuitState: String, Codable, Equatable, Sendable {
    case closed
    case open
}

/// These are deliberately the nine lifecycle states of the two currently
/// managed components. Liveness and readiness remain separate observations.
enum ComponentLifecycleState: String, Codable, Equatable, Sendable {
    case stopped
    case waitingForPrerequisites
    case starting
    case ready
    case degraded
    case retrying
    case circuitOpen
    case failed
    case stopping
}

enum ProductReadinessState: String, Codable, Equatable, Sendable {
    case ready
    case partiallyReady
    case needsAttention
}

struct ComponentLifecycleSnapshot: Codable, Equatable, Sendable {
    let id: ManagedComponentID
    let desired: ComponentDesiredState
    let lifecycle: ComponentLifecycleState
    let liveness: ComponentLiveness
    let readiness: ComponentReadiness
    let recentFailureCount: Int
    let nextRetryAt: Date?
    let reason: String?
    let circuit: ComponentCircuitState

    var isReady: Bool {
        desired == .enabled && lifecycle == .ready && readiness == .ready
    }

    var retryDeadline: Date? {
        nextRetryAt
    }

    var circuitState: ComponentCircuitState {
        circuit
    }

    init(
        id: ManagedComponentID,
        desired: ComponentDesiredState,
        lifecycle: ComponentLifecycleState,
        liveness: ComponentLiveness,
        readiness: ComponentReadiness,
        recentFailureCount: Int = 0,
        nextRetryAt: Date? = nil,
        reason: String? = nil,
        circuit: ComponentCircuitState = .closed
    ) {
        self.id = id
        self.desired = desired
        self.lifecycle = lifecycle
        self.liveness = liveness
        self.readiness = readiness
        self.recentFailureCount = recentFailureCount
        self.nextRetryAt = nextRetryAt
        self.reason = reason
        self.circuit = circuit
    }

}

struct LifecycleSnapshot: Codable, Equatable, Sendable {
    let mcpServer: ComponentLifecycleSnapshot
    let remoteConnector: ComponentLifecycleSnapshot
    let productReadiness: ProductReadinessState

    init(
        mcpServer: ComponentLifecycleSnapshot,
        remoteConnector: ComponentLifecycleSnapshot,
        productReadiness: ProductReadinessState? = nil
    ) {
        self.mcpServer = mcpServer
        self.remoteConnector = remoteConnector
        self.productReadiness = productReadiness ?? Self.deriveProductReadiness(
            mcpServer: mcpServer,
            remoteConnector: remoteConnector
        )
    }

    var product: ProductReadinessState {
        productReadiness
    }

    var components: [ManagedComponentID: ComponentLifecycleSnapshot] {
        [
            .mcpServer: mcpServer,
            .remoteConnector: remoteConnector,
        ]
    }

    subscript(_ id: ManagedComponentID) -> ComponentLifecycleSnapshot {
        switch id {
        case .mcpServer:
            return mcpServer
        case .remoteConnector:
            return remoteConnector
        }
    }

    static func deriveProductReadiness(
        mcpServer: ComponentLifecycleSnapshot,
        remoteConnector: ComponentLifecycleSnapshot
    ) -> ProductReadinessState {
        guard mcpServer.isReady else { return .needsAttention }
        guard remoteConnector.desired == .enabled else { return .ready }
        guard remoteConnector.isReady else {
            switch remoteConnector.lifecycle {
            case .circuitOpen, .failed:
                return .needsAttention
            case .stopped, .waitingForPrerequisites, .starting, .ready, .degraded, .retrying, .stopping:
                return .partiallyReady
            }
        }
        return .ready
    }
}

enum LifecycleEffect: Codable, Equatable, Sendable {
    case start(ManagedComponentID)
    case stop(ManagedComponentID)
    case revalidate(ManagedComponentID)
}

@MainActor
final class LifecycleStateMachine {
    private struct ComponentRecord {
        var desired: ComponentDesiredState = .disabled
        var lifecycle: ComponentLifecycleState = .stopped
        var liveness: ComponentLiveness = .stopped
        var readiness: ComponentReadiness = .notReady
        var failureDates: [Date] = []
        var nextRetryAt: Date?
        var retryHandle: LifecycleScheduledHandle?
        var circuit: ComponentCircuitState = .closed
        var reason: String?
        var generation: UInt64 = 0

        var isReady: Bool {
            desired == .enabled && lifecycle == .ready && readiness == .ready
        }
    }

    let scheduler: any LifecycleSchedulerProtocol
    var onSnapshot: ((LifecycleSnapshot) -> Void)?
    var onEffect: ((LifecycleEffect) -> Void)?

    private var records: [ManagedComponentID: ComponentRecord]
    private(set) var snapshot: LifecycleSnapshot
    private var networkAvailable = true
    private(set) var isQuiescing = false

    convenience init() {
        self.init(scheduler: MainLifecycleScheduler())
    }

    init(scheduler: any LifecycleSchedulerProtocol) {
        self.scheduler = scheduler
        let initial = Dictionary(
            uniqueKeysWithValues: ManagedComponentID.allCases.map {
                ($0, ComponentRecord())
            }
        )
        records = initial
        snapshot = LifecycleSnapshot(
            mcpServer: Self.snapshot(for: .mcpServer, record: initial[.mcpServer]!, now: scheduler.now),
            remoteConnector: Self.snapshot(for: .remoteConnector, record: initial[.remoteConnector]!, now: scheduler.now)
        )
    }

    func componentSnapshot(for component: ManagedComponentID) -> ComponentLifecycleSnapshot {
        snapshot[component]
    }

    func desiredState(for component: ManagedComponentID) -> ComponentDesiredState {
        records[component]?.desired ?? .disabled
    }

    func retryHandle(for component: ManagedComponentID) -> LifecycleScheduledHandle? {
        records[component]?.retryHandle
    }

    func setDesiredState(
        _ desired: ComponentDesiredState,
        for component: ManagedComponentID,
        reconcile: Bool = true
    ) {
        guard var record = records[component] else { return }
        let changed = record.desired != desired
        record.desired = desired

        if desired == .disabled {
            cancelRetry(&record, advanceGeneration: true)
            record.failureDates.removeAll()
            record.circuit = .closed
            record.nextRetryAt = nil
            record.reason = nil
            let shouldStop = record.lifecycle != .stopped
            record.lifecycle = shouldStop && reconcile ? .stopping : .stopped
            record.liveness = .stopped
            record.readiness = .notReady
            records[component] = record
            publish()
            if shouldStop && reconcile {
                requestStop(component)
                if onEffect == nil {
                    markStopped(for: component)
                }
            }
            return
        }

        if changed && record.circuit == .open {
            record.circuit = .closed
            record.failureDates.removeAll()
        }
        records[component] = record
        guard reconcile, !isQuiescing else {
            if !reconcile { publish() }
            return
        }
        reconcileStart(for: component)
    }

    func setDesiredState(
        _ enabled: Bool,
        for component: ManagedComponentID,
        reconcile: Bool = true
    ) {
        setDesiredState(ComponentDesiredState(enabled), for: component, reconcile: reconcile)
    }

    func setDesired(
        _ desired: ComponentDesiredState,
        for component: ManagedComponentID
    ) {
        setDesiredState(desired, for: component)
    }

    /// Synchronizes configuration-derived intent without starting or stopping
    /// processes. ProcessSupervisor uses this while replacing a launch contract.
    func synchronizeDesiredStates(
        mcpServer: Bool,
        remoteConnector: Bool,
        resetFailureHistory: Bool = false
    ) {
        for (component, desired) in [
            (ManagedComponentID.mcpServer, mcpServer),
            (ManagedComponentID.remoteConnector, remoteConnector),
        ] {
            guard var record = records[component] else { continue }
            record.desired = ComponentDesiredState(desired)
            if resetFailureHistory {
                cancelRetry(&record, advanceGeneration: true)
                record.failureDates.removeAll()
                record.circuit = .closed
                record.nextRetryAt = nil
                record.reason = nil
            }
            if !desired {
                cancelRetry(&record, advanceGeneration: true)
                record.lifecycle = .stopped
                record.liveness = .stopped
                record.readiness = .notReady
                record.nextRetryAt = nil
                record.circuit = .closed
            }
            records[component] = record
        }
        publish()
    }

    func markStarting(for component: ManagedComponentID) {
        guard var record = records[component],
              record.desired == .enabled,
              record.circuit == .closed else { return }
        record.lifecycle = .starting
        record.liveness = .starting
        record.readiness = .notReady
        record.reason = nil
        records[component] = record
        publish()
    }

    func markProcessRunning(for component: ManagedComponentID) {
        guard var record = records[component],
              record.desired == .enabled,
              record.circuit == .closed else { return }
        record.lifecycle = .starting
        record.liveness = .running
        record.readiness = .notReady
        records[component] = record
        publish()
    }

    func markRunning(for component: ManagedComponentID) {
        markProcessRunning(for: component)
    }

    func markReady(for component: ManagedComponentID) {
        guard var record = records[component],
              record.desired == .enabled,
              record.circuit == .closed else { return }
        if component == .remoteConnector && (!networkAvailable || !mcpIsReady) {
            records[component] = record
            transitionToWaitingForPrerequisites(component, reason: prerequisiteReason)
            return
        }
        cancelRetry(&record, advanceGeneration: true)
        record.lifecycle = .ready
        record.liveness = .running
        record.readiness = .ready
        record.nextRetryAt = nil
        record.reason = nil
        records[component] = record
        publish()
        if component == .mcpServer {
            reconcileStart(for: .remoteConnector)
        }
    }

    func markDegraded(
        for component: ManagedComponentID,
        reason: String,
        liveness: ComponentLiveness = .running
    ) {
        guard var record = records[component],
              record.desired == .enabled else { return }
        if component == .remoteConnector && !mcpIsReady {
            records[component] = record
            transitionToWaitingForPrerequisites(component, reason: prerequisiteReason)
            return
        }
        record.lifecycle = .degraded
        record.liveness = liveness
        record.readiness = .notReady
        record.reason = reason
        records[component] = record
        publish()
        if component == .mcpServer {
            blockRemoteForPrerequisite(cancelRemoteRetry: false)
        }
    }

    func markFailed(for component: ManagedComponentID, reason: String) {
        guard var record = records[component],
              record.desired == .enabled else { return }
        cancelRetry(&record, advanceGeneration: true)
        record.lifecycle = .failed
        record.liveness = .stopped
        record.readiness = .notReady
        record.reason = reason
        records[component] = record
        publish()
        if component == .mcpServer {
            blockRemoteForPrerequisite(cancelRemoteRetry: false)
        }
    }

    func markStopped(for component: ManagedComponentID, reason: String? = nil) {
        guard var record = records[component] else { return }
        if record.desired == .enabled &&
            (record.lifecycle == .waitingForPrerequisites || record.lifecycle == .degraded) {
            return
        }
        cancelRetry(&record, advanceGeneration: true)
        record.lifecycle = .stopped
        record.liveness = .stopped
        record.readiness = .notReady
        record.nextRetryAt = nil
        record.reason = reason
        records[component] = record
        publish()
    }

    func stop(component: ManagedComponentID, reason: String? = nil) {
        guard var record = records[component] else { return }
        cancelRetry(&record, advanceGeneration: true)
        let shouldStop = record.lifecycle != .stopped
        record.lifecycle = shouldStop ? .stopping : .stopped
        record.liveness = .stopped
        record.readiness = .notReady
        record.reason = reason
        records[component] = record
        publish()
        if shouldStop {
            requestStop(component)
        }
    }

    func recordFailure(
        for component: ManagedComponentID,
        reason: String,
        at date: Date? = nil
    ) {
        guard var record = records[component],
              record.desired == .enabled else { return }
        if component == .remoteConnector && (!networkAvailable || !mcpIsReady) {
            records[component] = record
            transitionToWaitingForPrerequisites(component, reason: prerequisiteReason)
            return
        }

        let now = date ?? scheduler.now
        let decision = SupervisorRetryPolicy.decision(
            failures: record.failureDates,
            now: now
        )
        switch decision {
        case let .retry(failures, delay):
            cancelRetry(&record, advanceGeneration: true)
            record.failureDates = failures
            record.circuit = .closed
            record.lifecycle = .retrying
            record.liveness = .stopped
            record.readiness = .notReady
            record.nextRetryAt = now.addingTimeInterval(delay)
            record.reason = reason
            records[component] = record
            scheduleRetry(for: component, at: now.addingTimeInterval(delay))
            publish()
        case let .circuitOpen(failures):
            cancelRetry(&record, advanceGeneration: true)
            record.failureDates = failures
            record.circuit = .open
            record.lifecycle = .circuitOpen
            record.liveness = .stopped
            record.readiness = .notReady
            record.nextRetryAt = nil
            record.reason = reason
            records[component] = record
            publish()
            if component == .mcpServer {
                blockRemoteForPrerequisite(cancelRemoteRetry: true)
            }
        }
    }

    func recordFailure(
        for component: ManagedComponentID,
        at date: Date,
        reason: String
    ) {
        recordFailure(for: component, reason: reason, at: date)
    }

    func reset(_ component: ManagedComponentID) {
        guard var record = records[component] else { return }
        cancelRetry(&record, advanceGeneration: true)
        record.failureDates.removeAll()
        record.circuit = .closed
        record.lifecycle = .stopped
        record.liveness = .stopped
        record.readiness = .notReady
        record.nextRetryAt = nil
        record.reason = nil
        records[component] = record
        publish()
        guard record.desired == .enabled, !isQuiescing else { return }
        reconcileStart(for: component)
    }

    func reset(component: ManagedComponentID) {
        reset(component)
    }

    func retry(component: ManagedComponentID) {
        reset(component)
    }

    func start(component: ManagedComponentID) {
        reconcileStart(for: component)
    }

    func stop(_ component: ManagedComponentID) {
        stop(component: component)
    }

    func handleNetworkAvailabilityChanged(_ available: Bool) {
        networkAvailable = available
        guard let record = records[.remoteConnector],
              record.desired == .enabled else { return }

        if !available {
            guard record.lifecycle != .stopped else { return }
            var updated = record
            cancelRetry(&updated, advanceGeneration: true)
            updated.lifecycle = .degraded
            updated.liveness = .stopped
            updated.readiness = .notReady
            updated.nextRetryAt = nil
            updated.reason = "Network is unavailable; remote endpoint will be revalidated when connectivity returns."
            records[.remoteConnector] = updated
            publish()
            requestStop(.remoteConnector)
            return
        }

        guard mcpIsReady, updatedRemoteCanRun else {
            transitionToWaitingForPrerequisites(
                .remoteConnector,
                reason: prerequisiteReason
            )
            return
        }
        if record.lifecycle == .ready {
            emit(.revalidate(.remoteConnector))
        } else if record.circuit == .closed {
            scheduleRecovery(for: .remoteConnector)
        }
    }

    func handleWake() {
        guard !isQuiescing else { return }
        if records[.mcpServer]?.desired == .enabled,
           records[.mcpServer]?.lifecycle != .ready,
           records[.mcpServer]?.retryHandle == nil,
           records[.mcpServer]?.circuit == .closed {
            reconcileStart(for: .mcpServer)
        }
        guard records[.remoteConnector]?.desired == .enabled,
              mcpIsReady,
              updatedRemoteCanRun else { return }
        if records[.remoteConnector]?.lifecycle == .ready {
            emit(.revalidate(.remoteConnector))
        } else {
            scheduleRecovery(for: .remoteConnector)
        }
    }

    func prepareForMaintenance() {
        isQuiescing = true
        for component in ManagedComponentID.allCases {
            guard var record = records[component] else { continue }
            cancelRetry(&record, advanceGeneration: true)
            if record.lifecycle != .stopped {
                record.lifecycle = .stopping
            }
            record.liveness = .stopped
            record.readiness = .notReady
            record.nextRetryAt = nil
            record.reason = "Quiesced for maintenance."
            records[component] = record
        }
        publish()

        let remoteWasActive = records[.remoteConnector]?.lifecycle == .stopping
        let serverWasActive = records[.mcpServer]?.lifecycle == .stopping
        if remoteWasActive { requestStop(.remoteConnector) }
        if serverWasActive { requestStop(.mcpServer) }
        if onEffect == nil {
            if remoteWasActive { markStopped(for: .remoteConnector) }
            if serverWasActive { markStopped(for: .mcpServer) }
        }
    }

    func resumeAfterMaintenance() {
        isQuiescing = false
        reconcileStart(for: .mcpServer)
        reconcileStart(for: .remoteConnector)
    }

    func reconcile() {
        reconcileStart(for: .mcpServer)
        reconcileStart(for: .remoteConnector)
    }

    private var mcpIsReady: Bool {
        records[.mcpServer]?.isReady == true
    }

    private var updatedRemoteCanRun: Bool {
        networkAvailable && records[.remoteConnector]?.circuit == .closed
    }

    private var prerequisiteReason: String {
        if !networkAvailable {
            return "Waiting for network availability."
        }
        return "Waiting for the local MCP server to become ready."
    }

    private func reconcileStart(for component: ManagedComponentID) {
        guard !isQuiescing,
              var record = records[component],
              record.desired == .enabled,
              record.circuit == .closed else { return }

        if component == .remoteConnector && (!networkAvailable || !mcpIsReady) {
            records[component] = record
            transitionToWaitingForPrerequisites(component, reason: prerequisiteReason)
            return
        }
        guard record.lifecycle != .starting,
              record.lifecycle != .ready,
              record.lifecycle != .failed,
              record.lifecycle != .stopping,
              record.retryHandle == nil else { return }
        record.lifecycle = .starting
        record.liveness = .starting
        record.readiness = .notReady
        record.reason = nil
        records[component] = record
        publish()
        emit(.start(component))
    }

    private func transitionToWaitingForPrerequisites(
        _ component: ManagedComponentID,
        reason: String,
        cancelPendingRetry: Bool = true
    ) {
        guard var record = records[component],
              record.desired == .enabled else { return }
        if cancelPendingRetry {
            cancelRetry(&record, advanceGeneration: true)
            record.nextRetryAt = nil
        }
        record.lifecycle = .waitingForPrerequisites
        record.liveness = .stopped
        record.readiness = .waitingForPrerequisites
        record.reason = reason
        records[component] = record
        publish()
    }

    private func blockRemoteForPrerequisite(cancelRemoteRetry: Bool) {
        guard let remote = records[.remoteConnector],
              remote.desired == .enabled,
              remote.circuit == .closed else { return }
        let wasActive = remote.lifecycle == .ready ||
            remote.lifecycle == .starting ||
            remote.lifecycle == .degraded
        transitionToWaitingForPrerequisites(
            .remoteConnector,
            reason: "Waiting for the local MCP server to recover.",
            cancelPendingRetry: cancelRemoteRetry
        )
        if wasActive { requestStop(.remoteConnector) }
    }

    private func scheduleRecovery(for component: ManagedComponentID) {
        guard var record = records[component],
              record.desired == .enabled,
              record.circuit == .closed,
              record.retryHandle == nil,
              !isQuiescing else { return }
        let failureCount = record.failureDates.filter {
            scheduler.now.timeIntervalSince($0) < SupervisorRetryPolicy.failureWindow
        }.count
        let delay = SupervisorRetryPolicy.delay(forFailureCount: failureCount)
        let date = scheduler.now.addingTimeInterval(delay)
        record.lifecycle = .retrying
        record.liveness = .stopped
        record.readiness = .notReady
        record.nextRetryAt = date
        record.reason = "Retry scheduled after lifecycle revalidation."
        records[component] = record
        scheduleRetry(for: component, at: date)
        publish()
    }

    private func scheduleRetry(for component: ManagedComponentID, at date: Date) {
        guard var record = records[component] else { return }
        let generation = record.generation
        let handle = scheduler.schedule(
            at: date,
            label: component.rawValue
        ) { [weak self] in
            self?.retryFired(for: component, generation: generation)
        }
        record.retryHandle = handle
        records[component] = record
    }

    private func retryFired(for component: ManagedComponentID, generation: UInt64) {
        guard var record = records[component],
              record.generation == generation,
              record.desired == .enabled,
              !isQuiescing,
              record.circuit == .closed else { return }
        record.retryHandle = nil
        record.nextRetryAt = nil
        records[component] = record
        if component == .remoteConnector && (!networkAvailable || !mcpIsReady) {
            transitionToWaitingForPrerequisites(component, reason: prerequisiteReason)
            return
        }
        reconcileStart(for: component)
    }

    private func requestStop(_ component: ManagedComponentID) {
        emit(.stop(component))
    }

    private func emit(_ effect: LifecycleEffect) {
        onEffect?(effect)
    }

    private func cancelRetry(
        _ record: inout ComponentRecord,
        advanceGeneration: Bool
    ) {
        if let handle = record.retryHandle {
            scheduler.cancel(handle)
            record.retryHandle = nil
        }
        if advanceGeneration {
            record.generation &+= 1
        }
    }

    private func publish() {
        let mcp = Self.snapshot(
            for: .mcpServer,
            record: records[.mcpServer]!,
            now: scheduler.now
        )
        let remote = Self.snapshot(
            for: .remoteConnector,
            record: records[.remoteConnector]!,
            now: scheduler.now
        )
        snapshot = LifecycleSnapshot(mcpServer: mcp, remoteConnector: remote)
        onSnapshot?(snapshot)
    }

    private static func snapshot(
        for id: ManagedComponentID,
        record: ComponentRecord,
        now: Date
    ) -> ComponentLifecycleSnapshot {
        let recentFailureCount = record.failureDates.filter {
            now.timeIntervalSince($0) < SupervisorRetryPolicy.failureWindow
        }.count
        return ComponentLifecycleSnapshot(
            id: id,
            desired: record.desired,
            lifecycle: record.lifecycle,
            liveness: record.liveness,
            readiness: record.readiness,
            recentFailureCount: recentFailureCount,
            nextRetryAt: record.nextRetryAt,
            reason: record.reason,
            circuit: record.circuit
        )
    }
}
