import XCTest
@testable import MacOrchestrator

final class StreamingLogRedactorTests: XCTestCase {
    func testRedactsSecretsSplitAcrossPipeChunks() {
        var redactor = StreamingLogRedactor(
            secrets: ["connector-secret", "ngrok-secret"]
        )

        XCTAssertEqual(redactor.append("connector-", flush: false), [])
        XCTAssertEqual(
            redactor.append("secret and ngrok-", flush: false),
            []
        )
        XCTAssertEqual(
            redactor.append("secret\n", flush: false),
            ["<redacted> and <redacted>"]
        )
    }

    func testFlushesAnUnterminatedLineWithoutLeakingSecrets() {
        var redactor = StreamingLogRedactor(secrets: ["connector-secret"])

        _ = redactor.append("prefix connector-", flush: false)
        XCTAssertEqual(
            redactor.append("secret", flush: true),
            ["prefix <redacted>"]
        )
    }

    func testRedactionRemainsSafeAcrossSecretAndURLChunkBoundaries() {
        var redactor = StreamingLogRedactor(
            secrets: ["connector-token", "ngrok_2sPlausibleToken_1234567890"]
        )
        _ = redactor.append("prefix https://demo.ngrok.app/connect", flush: false)
        let lines = redactor.append(
            "or-token/mcp and ngrok_2sPlausibleToken_1234567890\n",
            flush: false
        )

        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].contains("connector-token"))
        XCTAssertFalse(lines[0].contains("ngrok_2sPlausibleToken_1234567890"))
        XCTAssertFalse(lines[0].contains("https://demo.ngrok.app/"))
    }
}
