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
}
