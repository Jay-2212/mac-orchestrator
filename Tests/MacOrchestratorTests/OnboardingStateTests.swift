import Foundation
import XCTest
@testable import MacOrchestrator

final class OnboardingStateTests: XCTestCase {
    func testUnmarkedConfigurationIsFresh() {
        let configuration = AppConfiguration.fresh(ownerID: "fresh-owner")

        XCTAssertEqual(
            OnboardingStateClassifier.classify(configuration),
            .fresh
        )
    }

    func testLegacyMarkerClassifiesMigratedLegacyInstall() {
        var configuration = AppConfiguration.fresh(ownerID: "legacy-owner")
        configuration.controlProfile = .full
        configuration.onboarding.migrationMarkers = ["legacy-control-profile-v1"]

        XCTAssertEqual(
            OnboardingStateClassifier.classify(configuration),
            .legacyMigrated
        )
    }

    func testInterruptedStateIsNotTreatedAsFresh() {
        var configuration = AppConfiguration.fresh(ownerID: "interrupted-owner")
        configuration.onboarding.phase2State = .interrupted

        XCTAssertEqual(
            OnboardingStateClassifier.classify(configuration),
            .interrupted
        )
    }

    func testCompletedBooleanAndStateClassifyCompletedInstall() {
        var configuration = AppConfiguration.fresh(ownerID: "complete-owner")
        configuration.onboarding.completed = true

        XCTAssertEqual(
            OnboardingStateClassifier.classify(configuration),
            .completed
        )
    }

    func testPortAllocatorKeepsPreferredFreePort() throws {
        let selected = try LocalPortAllocator.select(
            preferred: 8_000,
            isOccupied: { _ in false }
        )

        XCTAssertEqual(selected, 8_000)
    }

    func testPortAllocatorSelectsFirstFreeCandidateAfterOccupiedPreferredPort() throws {
        let selected = try LocalPortAllocator.select(
            preferred: 8_000,
            isOccupied: { $0 == 8_000 || $0 == 8_002 },
            candidates: 8_000...8_003
        )

        XCTAssertEqual(selected, 8_001)
    }

    func testPortAllocatorFailsWhenEveryCandidateIsOccupied() {
        XCTAssertThrowsError(
            try LocalPortAllocator.select(
                preferred: 8_000,
                isOccupied: { _ in true },
                candidates: 8_000...8_001
            )
        ) { error in
            XCTAssertEqual(error as? LocalPortSelectionError, .noAvailablePort)
        }
    }
}
