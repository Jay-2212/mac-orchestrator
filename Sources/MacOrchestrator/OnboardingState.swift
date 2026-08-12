import Foundation

enum Phase2OnboardingState: String, Codable, Equatable, Sendable {
    case fresh
    case legacyMigrated
    case interrupted
    case completed
}

enum OnboardingStateClassifier {
    static func classify(_ configuration: AppConfiguration) -> Phase2OnboardingState {
        if configuration.onboarding.phase2State == .interrupted {
            return .interrupted
        }
        if configuration.onboarding.completed || configuration.onboarding.phase2State == .completed {
            return .completed
        }
        if let phase2State = configuration.onboarding.phase2State {
            return phase2State
        }
        if configuration.onboarding.migrationMarkers.contains("legacy-control-profile-v1")
            || configuration.onboarding.migrationMarkers.contains("legacy-secrets-v1") {
            return .legacyMigrated
        }
        return .fresh
    }
}
