import Foundation
import XCTest
@testable import MacOrchestrator

final class SensitiveDataRedactorTests: XCTestCase {
    func testRedactsOverlappingSecretsAndConnectorURLVariants() {
        let token = "ngrok_2sPlausibleToken_1234567890"
        let connector = "connector-capability-token-abcdefghijklmnopqrstuvwxyz"
        let redactor = SensitiveDataRedactor(
            exactSecrets: ["secret", "secret-long", token, connector],
            homeDirectory: "/Users/synthetic"
        )
        let input = "https://demo.ngrok.app/\(connector)/mcp token=\(token) secret-long"
        let output = redactor.redact(input)

        XCTAssertFalse(output.contains(connector))
        XCTAssertFalse(output.contains(token))
        XCTAssertFalse(output.contains("secret-long"))
        XCTAssertFalse(output.contains("https://demo.ngrok.app/"))
    }

    func testRedactsSecretNamedJSONFieldsAndNormalizesHomePaths() throws {
        let redactor = SensitiveDataRedactor(
            exactSecrets: ["bot-secret"],
            homeDirectory: "/Users/synthetic"
        )
        let sanitized = try XCTUnwrap(redactor.redactJSON(Data(
            #"{"token":"bot-secret","path":"/Users/synthetic/Library/Logs/x"}"#.utf8
        )))
        let text = String(decoding: sanitized, as: UTF8.self)

        XCTAssertFalse(text.contains("bot-secret"))
        XCTAssertFalse(text.contains("/Users/synthetic"))
        XCTAssertTrue(text.contains("<redacted>"))
        XCTAssertTrue(text.contains("<home>/Library/Logs/x"))
    }

    func testRedactsNestedCaseInsensitiveCredentialFieldsWithoutChangingMetadata() throws {
        let token = "nested-secret"
        let redactor = SensitiveDataRedactor(
            exactSecrets: [token],
            homeDirectory: "/Users/synthetic"
        )
        let input = Data(
            #"{"category":"network","status":"fail","filename":"doctor.json","details":{"AuThToKeN":"nested-secret","CAPABILITYTOKEN":"nested-secret","errorClass":"timeout"}}"#.utf8
        )

        let sanitized = try XCTUnwrap(redactor.redactJSON(input))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        )
        let details = try XCTUnwrap(object["details"] as? [String: Any])

        XCTAssertEqual(object["category"] as? String, "network")
        XCTAssertEqual(object["status"] as? String, "fail")
        XCTAssertEqual(object["filename"] as? String, "doctor.json")
        XCTAssertEqual(details["errorClass"] as? String, "timeout")
        XCTAssertEqual(details["AuThToKeN"] as? String, "<redacted>")
        XCTAssertEqual(details["CAPABILITYTOKEN"] as? String, "<redacted>")
        XCTAssertFalse(String(decoding: sanitized, as: UTF8.self).contains(token))
    }

    func testRedactedPathNormalizesConfiguredAndUserHomePaths() {
        let redactor = SensitiveDataRedactor(
            exactSecrets: [],
            homeDirectory: "/Users/synthetic"
        )

        XCTAssertEqual(
            redactor.redactedPath("/Users/synthetic/Library/Logs/current.log"),
            "<home>/Library/Logs/current.log"
        )
        XCTAssertEqual(
            redactor.redactedPath("/Users/another-user/Library/Logs/current.log"),
            "<home>/Library/Logs/current.log"
        )
    }
}
