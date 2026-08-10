import Foundation
import XCTest
@testable import MacOrchestrator

final class ConfigurationTests: XCTestCase {
    func testFreshConfigurationUsesGuidedSafeDefaults() throws {
        let configuration = AppConfiguration.fresh(ownerID: "owner-1")

        XCTAssertEqual(configuration.schemaVersion, 1)
        XCTAssertEqual(configuration.generation, 1)
        XCTAssertEqual(configuration.controlProfile, .guided)
        XCTAssertEqual(configuration.localMCPPort, 8000)
        XCTAssertTrue(configuration.process.serverDesired)
        XCTAssertFalse(configuration.process.tunnelDesired)
        XCTAssertEqual(configuration.ownerID, "owner-1")
        XCTAssertTrue(configuration.desiredCapabilities["core.session"] == true)
        XCTAssertTrue(configuration.desiredCapabilities["mac.ui"] == true)
        XCTAssertFalse(configuration.desiredCapabilities["mac.shell"] == true)
        XCTAssertFalse(configuration.desiredCapabilities["mac.files.write"] == true)
        XCTAssertFalse(configuration.policy.clipboardMutation)
        XCTAssertTrue(configuration.approvedFileRoots.isEmpty)
        XCTAssertNil(configuration.integration.meridianDeploymentURL)
    }

    func testInvalidPortIsRejectedBeforePersistence() {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.localMCPPort = 0

        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? ConfigurationValidationError, .invalidPort(0))
        }
    }

    func testConfigurationRoundTripsArbitraryValidPortWithoutSecrets() throws {
        var configuration = AppConfiguration.fresh(ownerID: "owner-1")
        configuration.localMCPPort = 9876
        configuration.integration.meridianDeploymentURL = "https://meridian.example"

        let data = try JSONEncoder().encode(try configuration.validated())
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("bot-token-secret"))
        XCTAssertFalse(json.contains("ingest-secret"))

        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        XCTAssertEqual(decoded.localMCPPort, 9876)
        XCTAssertEqual(decoded.integration.meridianDeploymentURL, "https://meridian.example")
    }
}
