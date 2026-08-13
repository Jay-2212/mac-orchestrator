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

        XCTAssertEqual(output, "<redacted> token=<redacted> <redacted>")
        XCTAssertFalse(output.contains(connector))
        XCTAssertFalse(output.contains(token))
        XCTAssertFalse(output.contains("secret-long"))
        XCTAssertFalse(output.contains("https://demo.ngrok.app/"))
    }

    func testIgnoresWhitespaceOnlyExactSecrets() {
        let redactor = SensitiveDataRedactor(
            exactSecrets: ["   ", "\t\n"],
            homeDirectory: nil
        )

        XCTAssertEqual(redactor.redact("left   right"), "left   right")
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
        let redactor = SensitiveDataRedactor(
            exactSecrets: ["unrelated-secret"],
            homeDirectory: "/Users/synthetic"
        )
        let input = Data(
            #"{"category":"network","status":"fail","filename":"doctor.json","details":{"AuThToKeN":"field-only-auth-value","CAPABILITYTOKEN":"field-only-capability-value","errorClass":"timeout"}}"#.utf8
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
        let text = String(decoding: sanitized, as: UTF8.self)
        XCTAssertFalse(text.contains("field-only-auth-value"))
        XCTAssertFalse(text.contains("field-only-capability-value"))
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

    func testRedactsPlaintextSecretAssignmentsWithoutRemovingFieldContext() {
        let redactor = SensitiveDataRedactor(exactSecrets: [], homeDirectory: "/Users/synthetic")
        let output = redactor.redact("ngrok_authtoken=FAKE_NGROK_TOKEN password: fake-password authorization=Bearer fake-auth")

        XCTAssertTrue(output.contains("ngrok_authtoken=<redacted>"))
        XCTAssertTrue(output.contains("password: <redacted>"))
        XCTAssertTrue(output.contains("authorization=Bearer <redacted>"))
        XCTAssertFalse(output.contains("FAKE_NGROK_TOKEN"))
        XCTAssertFalse(output.contains("fake-password"))
        XCTAssertFalse(output.contains("fake-auth"))
    }

    func testRedactsAbsoluteConnectorURLsRouteOnlyFormsAndBareCredentialAssignments() {
        let connectorToken = "connector-route-secret-abcdefghijklmnopqrstuvwxyz"
        let redactor = SensitiveDataRedactor(
            exactSecrets: [connectorToken],
            homeDirectory: "/Users/synthetic"
        )
        let input = """
        endpoint=https://connector.example.test/health?capability=abc
        route=/\(connectorToken)/mcp?token=\(connectorToken)
        token=bare-token bot_token=bare-bot auth_token=bare-auth ngrok_authtoken=bare-ngrok password=bare-password authorization=Bearer bare-authz
        safe-context=preserved
        """

        let output = redactor.redact(input)

        XCTAssertFalse(output.contains("https://connector.example.test/health"))
        XCTAssertFalse(output.contains(connectorToken))
        XCTAssertFalse(output.contains("bare-token"))
        XCTAssertFalse(output.contains("bare-bot"))
        XCTAssertFalse(output.contains("bare-auth"))
        XCTAssertFalse(output.contains("bare-ngrok"))
        XCTAssertFalse(output.contains("bare-password"))
        XCTAssertFalse(output.contains("bare-authz"))
        XCTAssertTrue(output.contains("safe-context=preserved"))
    }

    func testRotatingLogRedactsCurrentAndRotatedFilesAndPreservesPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-orchestrator-redactor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let currentURL = directory.appendingPathComponent("runtime.log")
        let rotatedURL = directory.appendingPathComponent("runtime.log.1")
        let secret = "ngrok_2sPlausibleToken_1234567890"
        let connector = "connector-capability-token-abcdefghijklmnopqrstuvwxyz"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("current \(secret) https://demo.ngrok.app/\(connector)/mcp\n".utf8)
            .write(to: currentURL)
        try Data("rotated \(secret) https://demo.ngrok.app/\(connector)/mcp\n".utf8)
            .write(to: rotatedURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: currentURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: rotatedURL.path
        )

        RotatingLog(directory: directory, name: "runtime.log", backups: 1)
            .redact([secret, connector])

        for url in [currentURL, rotatedURL] {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(secret))
            XCTAssertFalse(text.contains(connector))
            XCTAssertFalse(text.contains("https://demo.ngrok.app/"))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
}
