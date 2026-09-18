import XCTest
@testable import Phleet

/// The access token appears in no URL anywhere.
///
/// Asserted against the real URL builders rather than against a double: the doubles are handed
/// the token as a parameter and never build a URL at all, so asserting on them would prove
/// nothing about the code that ships.
final class RequestURLTests: XCTestCase {

    private let origin = URL(string: "https://server.invalid")!
    private let token = "a-token-value-that-must-never-reach-a-url"

    private var routeURLs: [URL] {
        get throws {
            [
                try URLSessionFleetAPIClient.routeURL(origin: origin, path: "/v1/auth/devices"),
                try URLSessionFleetAPIClient.routeURL(origin: origin, path: "/v1/auth/token"),
                try URLSessionFleetAPIClient.routeURL(origin: origin, path: "/v1/session"),
                try URLSessionFleetAPIClient.routeURL(origin: origin, path: "/v1/conversations"),
                try URLSessionFleetAPIClient.routeURL(
                    origin: origin,
                    path: "/v1/conversations/conversation-1/events",
                    query: [
                        URLQueryItem(name: "afterSeq", value: "10"),
                        URLQueryItem(name: "limit", value: "200")
                    ]
                ),
                try URLSessionFleetAPIClient.routeURL(
                    origin: origin,
                    path: "/v1/conversations/conversation-1/submissions"
                ),
                try URLSessionFleetAPIClient.routeURL(
                    origin: origin,
                    path: "/v1/conversations/conversation-1/cursor"
                )
            ]
        }
    }

    func testNoRouteURLCarriesTheToken() throws {
        for url in try routeURLs {
            XCTAssertFalse(
                url.absoluteString.contains(token),
                "\(url.path) must carry the token in a header, never in a URL"
            )
            XCTAssertNil(url.user)
            XCTAssertNil(url.password)
            XCTAssertNil(url.fragment)
        }
    }

    func testTheStreamURLCarriesTheClientInstanceIdAndNotTheToken() throws {
        let url = try XCTUnwrap(
            URLSessionConversationStream.streamURL(
                origin: origin,
                conversationId: "conversation-1",
                clientInstanceId: "instance-1",
                afterSeq: 899
            )
        )
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )

        // Required on the upgrade, and validated before anything else server-side.
        XCTAssertEqual(query["clientInstanceId"], "instance-1")
        XCTAssertEqual(query["afterSeq"], "899")
        XCTAssertFalse(url.absoluteString.contains(token))
        XCTAssertEqual(components.scheme, "wss")
    }

    func testTheCatchUpURLSendsBothParametersExplicitly() throws {
        let url = try URLSessionFleetAPIClient.routeURL(
            origin: origin,
            path: "/v1/conversations/conversation-1/events",
            query: [
                URLQueryItem(name: "afterSeq", value: "0"),
                URLQueryItem(name: "limit", value: "200")
            ]
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let names = (components.queryItems ?? []).map(\.name)

        XCTAssertEqual(names, ["afterSeq", "limit"])
    }

    func testAnOriginWithAPathKeepsIt() throws {
        let nested = URL(string: "https://server.invalid/fleet/")!
        let url = try URLSessionFleetAPIClient.routeURL(origin: nested, path: "/v1/session")
        XCTAssertEqual(url.path, "/fleet/v1/session")
    }
}
