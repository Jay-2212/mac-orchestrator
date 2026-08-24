import Foundation

enum ServiceState: String {
    case stopped = "Stopped"
    case starting = "Starting"
    case running = "Running"
    case stopping = "Stopping"
    case reconnecting = "Reconnecting"
    case failed = "Failed"
}

struct ServiceSnapshot {
    var server: ServiceState = .stopped
    var tunnel: ServiceState = .stopped
    var meridianIndexer = MeridianIndexerSnapshot()
    var productReadiness: ProductReadinessState = .needsAttention
    var error: String?
    var controlProfile: ControlProfile?
    var readyCapabilityCount: Int = 0
    var totalCapabilityCount: Int = CapabilityRegistry.capabilityIDs.count
    var pendingPermissions: [String] = []
    var clientRefreshRequired: Bool = false
    var effectiveCapabilitySnapshot: CapabilitySnapshot?

    var isHealthy: Bool {
        if productReadiness == .ready {
            return true
        }
        return server == .running && (tunnel == .running || tunnel == .stopped)
    }

    mutating func applyLifecycleSnapshot(_ lifecycle: LifecycleSnapshot) {
        server = Self.serviceState(for: lifecycle.mcpServer)
        tunnel = Self.serviceState(for: lifecycle.remoteConnector)
        productReadiness = lifecycle.productReadiness
        error = lifecycle.mcpServer.reason ?? lifecycle.remoteConnector.reason
        if let capabilitySnapshot = effectiveCapabilitySnapshot {
            let projected = capabilitySnapshot.projected(from: lifecycle)
            effectiveCapabilitySnapshot = projected
            readyCapabilityCount = projected.capabilities.values.filter(\.ready).count
            totalCapabilityCount = projected.capabilities.count
        }
    }

    func projected(from lifecycle: LifecycleSnapshot) -> ServiceSnapshot {
        var projection = self
        projection.applyLifecycleSnapshot(lifecycle)
        return projection
    }

    private static func serviceState(
        for component: ComponentLifecycleSnapshot
    ) -> ServiceState {
        switch component.lifecycle {
        case .stopped:
            return .stopped
        case .waitingForPrerequisites:
            return .reconnecting
        case .starting:
            return .starting
        case .ready:
            return component.isReady ? .running : .starting
        case .degraded:
            return component.id == .mcpServer ? .starting : .reconnecting
        case .retrying:
            return .reconnecting
        case .circuitOpen, .failed:
            return .failed
        case .stopping:
            return .stopping
        }
    }

    mutating func applyRuntimeContract(
        _ contract: ManagedRuntimeLaunchContract,
        requiresClientRefresh: Bool
    ) {
        controlProfile = contract.capabilitySnapshot.controlProfile
        effectiveCapabilitySnapshot = contract.capabilitySnapshot
        readyCapabilityCount = contract.capabilitySnapshot.capabilities.values.filter(\.ready).count
        totalCapabilityCount = contract.capabilitySnapshot.capabilities.count
        pendingPermissions = Self.pendingPermissions(in: contract.capabilitySnapshot)
        clientRefreshRequired = clientRefreshRequired || requiresClientRefresh
    }

    mutating func applyMeridianIndexerSnapshot(_ meridianIndexer: MeridianIndexerSnapshot) {
        self.meridianIndexer = meridianIndexer
    }

    private static func pendingPermissions(in snapshot: CapabilitySnapshot) -> [String] {
        var permissions = [String]()
        if let ui = snapshot.capabilities["mac.ui"], ui.desired, !ui.ready {
            permissions.append("Accessibility")
        }
        if let screenOcr = snapshot.capabilities["mac.screenOcr"], screenOcr.desired, !screenOcr.ready {
            permissions.append("Screen Recording or OCR payload")
        }
        return permissions
    }
}

struct OwnedProcessState: Codable {
    let ownerID: String
    var serverPID: Int32?
    var tunnelPID: Int32?
}
