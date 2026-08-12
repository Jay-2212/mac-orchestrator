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
    var connectorURL: URL?
    var error: String?
    var controlProfile: ControlProfile?
    var readyCapabilityCount: Int = 0
    var totalCapabilityCount: Int = CapabilityRegistry.capabilityIDs.count
    var pendingPermissions: [String] = []
    var clientRefreshRequired: Bool = false

    var isHealthy: Bool {
        server == .running && (tunnel == .running || tunnel == .stopped)
    }

    mutating func applyRuntimeContract(
        _ contract: ManagedRuntimeLaunchContract,
        requiresClientRefresh: Bool
    ) {
        controlProfile = contract.capabilitySnapshot.controlProfile
        readyCapabilityCount = contract.capabilitySnapshot.capabilities.values.filter(\.ready).count
        totalCapabilityCount = contract.capabilitySnapshot.capabilities.count
        pendingPermissions = Self.pendingPermissions(in: contract.capabilitySnapshot)
        clientRefreshRequired = clientRefreshRequired || requiresClientRefresh
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
