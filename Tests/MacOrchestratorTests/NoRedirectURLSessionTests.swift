import Foundation
import XCTest
@testable import MacOrchestrator

final class NoRedirectURLSessionTests: XCTestCase {
    func testHTTPRedirectIsRejectedRatherThanFollowed() {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "http://127.0.0.1/start")!)
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1/start")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "http://attacker.invalid/final"]
        )!
        var redirectedRequest: URLRequest? = URLRequest(
            url: URL(string: "http://attacker.invalid/final")!
        )

        NoRedirectURLSessionDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirectedRequest!,
            completionHandler: { redirectedRequest = $0 }
        )

        XCTAssertNil(redirectedRequest)
        task.cancel()
    }
}
