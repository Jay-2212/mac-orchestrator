import Foundation
import XCTest
@testable import MacOrchestrator

final class NgrokSupportTests: XCTestCase {
    func testEndpointParserUsesCurrentEndpointsResponseAndMatchesUpstream() throws {
        let data = Data(
            #"{"endpoints":[{"name":"ep_1","url":"https://demo.ngrok.app","upstream":{"url":"http://127.0.0.1:8000"}}]}"#.utf8
        )

        XCTAssertEqual(
            NgrokEndpointParser.publicURL(
                from: data,
                matching: "http://127.0.0.1:8000"
            ),
            URL(string: "https://demo.ngrok.app")
        )
    }

    func testEndpointParserRejectsWrongUpstreamAndNonTLSPublicURL() {
        let data = Data(
            #"{"endpoints":[{"url":"http://demo.ngrok.app","upstream":{"url":"http://127.0.0.1:8001"}}]}"#.utf8
        )

        XCTAssertNil(
            NgrokEndpointParser.publicURL(
                from: data,
                matching: "http://127.0.0.1:8000"
            )
        )
    }

    func testEndpointParserRejectsDeprecatedTunnelsShape() {
        let data = Data(
            #"{"tunnels":[{"public_url":"https://demo.ngrok.app","config":{"addr":"http://127.0.0.1:8000"}}]}"#.utf8
        )

        XCTAssertNil(
            NgrokEndpointParser.publicURL(
                from: data,
                matching: "http://127.0.0.1:8000"
            )
        )
    }
}
