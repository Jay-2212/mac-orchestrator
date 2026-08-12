import Foundation
import XCTest
@testable import MacOrchestrator

final class NoRedirectURLSessionTests: XCTestCase {
    func testHTTPRedirectIsRejectedRatherThanFollowed() async throws {
        RedirectURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectURLProtocol.self]
        let session = NoRedirectURLSession.make(configuration: configuration)
        let request = URLRequest(url: URL(string: "http://127.0.0.1/start")!)

        do {
            _ = try await session.data(for: request)
            XCTFail("a redirect must not produce a successful probe response")
        } catch {
            // Rejecting the redirect is the expected transport result.
        }

        XCTAssertFalse(RedirectURLProtocol.didFollowRedirect)
    }
}

private final class RedirectURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var followedRedirect = false

    static func reset() {
        lock.lock()
        followedRedirect = false
        lock.unlock()
    }

    static var didFollowRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return followedRedirect
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1" || request.url?.host == "attacker.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if url.host == "attacker.invalid" {
            Self.lock.lock()
            Self.followedRedirect = true
            Self.lock.unlock()
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"status":"ok"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "http://attacker.invalid/final"]
        )!
        let redirectedRequest = URLRequest(url: URL(string: "http://attacker.invalid/final")!)
        client?.urlProtocol(self, wasRedirectedTo: redirectedRequest, redirectResponse: response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
