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

    var isHealthy: Bool {
        server == .running && (tunnel == .running || tunnel == .stopped)
    }
}

struct OwnedProcessState: Codable {
    let ownerID: String
    var serverPID: Int32?
    var tunnelPID: Int32?
}
