import Foundation

enum SupervisorComponent: Sendable {
    case server
    case tunnel
}

enum SupervisorRetryDecision: Equatable, Sendable {
    case retry(failures: [Date], delay: TimeInterval)
    case circuitOpen(failures: [Date])
}

enum SupervisorRetryPolicy {
    static let failureWindow: TimeInterval = 120
    private static let maximumFailures = 5
    private static let maximumDelay: TimeInterval = 30

    static func decision(failures: [Date], now: Date) -> SupervisorRetryDecision {
        let recentFailures = failures.filter {
            now.timeIntervalSince($0) < failureWindow
        }
        let updatedFailures = recentFailures + [now]

        guard updatedFailures.count <= maximumFailures else {
            return .circuitOpen(failures: updatedFailures)
        }

        let delay = min(
            pow(2.0, Double(max(0, updatedFailures.count - 1))),
            maximumDelay
        )
        return .retry(failures: updatedFailures, delay: delay)
    }
}

enum ProcessOwnership {
    static func marker(for component: SupervisorComponent, ownerID: String) -> String {
        switch component {
        case .server:
            return "--managed-owner \(ownerID)"
        case .tunnel:
            return "mac-orchestrator-owner=\(ownerID)"
        }
    }

    static func matches(
        commandLine: String,
        component: SupervisorComponent,
        ownerID: String
    ) -> Bool {
        commandLine.contains(marker(for: component, ownerID: ownerID))
    }
}

enum ConnectorURLBuilder {
    static func make(publicURL: String, capabilityToken: String) -> URL? {
        guard publicURL.hasPrefix("https://"),
              let base = URL(string: publicURL),
              var components = URLComponents(
                  url: base,
                  resolvingAgainstBaseURL: false
              ) else {
            return nil
        }

        components.path = "/\(capabilityToken)/mcp"
        return components.url
    }
}
