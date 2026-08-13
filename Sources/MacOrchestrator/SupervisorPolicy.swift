import Foundation

enum SupervisorComponent: Sendable, Equatable {
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

        let delay = delay(forFailureCount: updatedFailures.count - 1)
        return .retry(failures: updatedFailures, delay: delay)
    }

    static func delay(forFailureCount failureCount: Int) -> TimeInterval {
        min(pow(2.0, Double(max(0, failureCount))), maximumDelay)
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
        let tokens = commandLine.split { $0 == " " || $0 == "\t" }.map(String.init)
        switch component {
        case .server:
            return zip(tokens, tokens.dropFirst()).contains { option, value in
                option == "--managed-owner" && value == ownerID
            }
        case .tunnel:
            return tokens.contains("mac-orchestrator-owner=\(ownerID)")
        }
    }

    /// Pure authorization policy for cleanup of a recorded process ID.
    ///
    /// The PID liveness check and the component-specific owner marker are both
    /// required before a caller may terminate a recorded process. Keeping the
    /// policy free of process inspection makes PID reuse and cross-component
    /// cases deterministic to test.
    static func authorizesTermination(
        pidExists: Bool,
        commandLine: String,
        component: SupervisorComponent,
        ownerID: String
    ) -> Bool {
        pidExists && matches(
            commandLine: commandLine,
            component: component,
            ownerID: ownerID
        )
    }
}

enum PortOccupancyDecision: Equatable, Sendable {
    case allowStart
    case refuseWithoutTermination
}

enum PortSafetyPolicy {
    static func decision(isOccupied: Bool) -> PortOccupancyDecision {
        isOccupied ? .refuseWithoutTermination : .allowStart
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
