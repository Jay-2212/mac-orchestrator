import Foundation
import XCTest
@testable import MacOrchestrator

final class NgrokSupportTests: XCTestCase {
    func testEndpointReconciliationReturnsCurrentForOneNormalizedHTTPSMatch() {
        let data = Data(
            #"{"endpoints":[{"name":"ep_1","url":"https://demo.ngrok.app","upstream":{"url":"http://127.0.0.1:8000/"}}]}"#.utf8
        )

        XCTAssertEqual(
            NgrokEndpointParser.reconcile(
                from: data,
                matching: "  http://127.0.0.1:8000  "
            ),
            .current(publicURL: URL(string: "https://demo.ngrok.app")!)
        )
    }

    func testEndpointReconciliationReturnsMissingForAValidEmptyResponse() {
        XCTAssertEqual(
            NgrokEndpointParser.reconcile(
                from: Data(#"{"endpoints":[]}"#.utf8),
                matching: "http://127.0.0.1:8000"
            ),
            .missing
        )
    }

    func testEndpointReconciliationReturnsForeignWhenOnlyWrongUpstreamsExist() {
        let data = Data(
            #"{"endpoints":[{"url":"https://foreign.ngrok.app","upstream":{"url":"http://127.0.0.1:8001"}}]}"#.utf8
        )

        XCTAssertEqual(
            NgrokEndpointParser.reconcile(
                from: data,
                matching: "http://127.0.0.1:8000"
            ),
            .foreign
        )
    }

    func testEndpointReconciliationReturnsAmbiguousForMultipleMatchingEndpoints() {
        let data = Data(
            #"{"endpoints":[{"url":"https://one.ngrok.app","upstream":{"url":"http://127.0.0.1:8000"}},{"url":"https://two.ngrok.app","upstream":{"url":"http://127.0.0.1:8000/"}}]}"#.utf8
        )

        XCTAssertEqual(
            NgrokEndpointParser.reconcile(
                from: data,
                matching: "http://127.0.0.1:8000"
            ),
            .ambiguous
        )
    }

    func testEndpointWithTwoExactMatchesIsAmbiguousEvenWhenOneURLIsInvalid() {
        let data = Data(
            #"{"endpoints":[{"url":"not-a-url","upstream":{"url":"http://127.0.0.1:8000"}},{"url":"https://two.ngrok.app","upstream":{"url":"http://127.0.0.1:8000"}}]}"#.utf8
        )

        XCTAssertEqual(
            NgrokEndpointParser.reconcile(
                from: data,
                matching: "http://127.0.0.1:8000"
            ),
            .ambiguous
        )
    }

    func testEndpointReconciliationReturnsInvalidForMalformedAgentAPIResponse() {
        XCTAssertEqual(
            NgrokEndpointParser.reconcile(
                from: Data("not-json".utf8),
                matching: "http://127.0.0.1:8000"
            ),
            .invalidAgentAPIResponse
        )
    }

    func testEndpointReconciliationRejectsNonHTTPSMatchingPublicEndpoint() {
        let data = Data(
            #"{"endpoints":[{"url":"http://demo.ngrok.app","upstream":{"url":"http://127.0.0.1:8000"}}]}"#.utf8
        )

        XCTAssertEqual(
            NgrokEndpointParser.reconcile(
                from: data,
                matching: "http://127.0.0.1:8000"
            ),
            .invalidAgentAPIResponse
        )
    }

    func testEndpointReconciliationRejectsDeprecatedTunnelsShape() {
        let data = Data(
            #"{"tunnels":[{"public_url":"https://demo.ngrok.app","config":{"addr":"http://127.0.0.1:8000"}}]}"#.utf8
        )

        XCTAssertEqual(
            NgrokEndpointParser.reconcile(
                from: data,
                matching: "http://127.0.0.1:8000"
            ),
            .invalidAgentAPIResponse
        )
    }

    func testEndpointResponseValidityDistinguishesMalformedData() {
        XCTAssertTrue(NgrokEndpointParser.isValidResponse(from: Data(#"{"endpoints":[]}"#.utf8)))
        XCTAssertFalse(NgrokEndpointParser.isValidResponse(from: Data(#"not-json"#.utf8)))
    }

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

    func testEndpointParserDetectsAnyLiveHTTPSEndpointForShutdownVerification() {
        let data = Data(
            #"{"endpoints":[{"url":"https://stale.ngrok.app","upstream":{"url":"http://127.0.0.1:9999"}}]}"#.utf8
        )

        XCTAssertTrue(NgrokEndpointParser.hasLiveHTTPS(from: data))
    }
}
