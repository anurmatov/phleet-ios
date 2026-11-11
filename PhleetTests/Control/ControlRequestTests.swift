import XCTest
@testable import Phleet

/// How a control-plane request is put on the wire, and how an answer is read.
///
/// These assert on the real request builders. A double that is handed the secrets as parameters
/// could not show where they end up.
final class ControlRequestTests: XCTestCase {

    private func get(
        _ path: String,
        _ connection: ControlConnection = .fixture
    ) throws -> URLRequest {
        try ControlRequest.make(connection: connection, method: "GET", percentEncodedPath: path)
    }

    private func post(
        _ path: String,
        _ connection: ControlConnection = .fixture
    ) throws -> URLRequest {
        try ControlRequest.make(
            connection: connection,
            method: "POST",
            percentEncodedPath: path,
            body: Data("{}".utf8)
        )
    }

    // MARK: - Where the secrets go

    func testAReadCarriesTheServiceTokenAndNotTheOperatorToken() throws {
        let request = try get("/api/agents")

        XCTAssertEqual(
            request.value(forHTTPHeaderField: ControlRequest.accessClientIdHeader),
            "client-id-1"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: ControlRequest.accessClientSecretHeader),
            "client-secret-1"
        )
        // The orchestrator does not ask for it on a read, so it is not sent on one.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testAWriteCarriesBoth() throws {
        let request = try post("/api/workflows/fleet/signal/w1")

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer operator-token-1")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: ControlRequest.accessClientSecretHeader),
            "client-secret-1"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testAConnectionWithNoProxySendsNoServiceTokenHeaders() throws {
        let direct = ControlConnection(
            origin: URL(string: "https://fleet.example.invalid")!,
            serviceToken: nil,
            operatorToken: "operator-token-1"
        )
        let request = try get("/api/agents", direct)

        XCTAssertNil(request.value(forHTTPHeaderField: ControlRequest.accessClientIdHeader))
        XCTAssertNil(request.value(forHTTPHeaderField: ControlRequest.accessClientSecretHeader))
    }

    func testAReadOnlyConnectionCannotBuildAWrite() {
        XCTAssertThrowsError(try post("/api/workflows/fleet/signal/w1", .readOnlyFixture)) { error in
            XCTAssertEqual(error as? ControlAPIError, .readOnly)
        }
        // And reading still works.
        XCTAssertNoThrow(try get("/api/agents", .readOnlyFixture))
    }

    func testNoSecretEverAppearsInAURL() throws {
        let requests = [
            try get("/api/agents"),
            try get("/api/workflows"),
            try get("/api/signals"),
            try post(ControlRequest.signalPath(namespace: "fleet", workflowId: "w1")),
            try XCTUnwrap(URLSessionControlLiveStream.upgradeRequest(.fixture))
        ]
        for request in requests {
            let url = try XCTUnwrap(request.url?.absoluteString)
            for secret in ["client-id-1", "client-secret-1", "operator-token-1"] {
                XCTAssertFalse(url.contains(secret), "\(url) carries a secret")
            }
            XCTAssertNil(request.url?.query)
        }
    }

    // MARK: - URLs

    func testARouteIsAppendedToTheOrigin() throws {
        XCTAssertEqual(
            try get("/api/agents").url?.absoluteString,
            "https://fleet.example.invalid/api/agents"
        )
    }

    func testAnOriginWithAPathKeepsIt() throws {
        let nested = ControlConnection(
            origin: URL(string: "https://fleet.example.invalid/console/")!,
            serviceToken: nil,
            operatorToken: nil
        )
        XCTAssertEqual(
            try get("/api/agents", nested).url?.absoluteString,
            "https://fleet.example.invalid/console/api/agents"
        )
    }

    func testAWorkflowIdentifierWithASlashStaysOneSegment() {
        // The route takes the identifier as a single segment and the orchestrator unescapes it.
        XCTAssertEqual(
            ControlRequest.signalPath(namespace: "fleet", workflowId: "design/synthetic 7"),
            "/api/workflows/fleet/signal/design%2Fsynthetic%207"
        )
    }

    func testEscapingLeavesOnlyUnreservedCharacters() {
        XCTAssertEqual(ControlRequest.escaped("Az09-._~"), "Az09-._~")
        XCTAssertEqual(ControlRequest.escaped("a?b#c&d=e%f"), "a%3Fb%23c%26d%3De%25f")
        XCTAssertEqual(ControlRequest.escaped("é"), "%C3%A9")
    }

    func testTheSignalRouteSurvivesBeingBuiltIntoARequest() throws {
        let request = try post(
            ControlRequest.signalPath(namespace: "fleet", workflowId: "design/synthetic 7")
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://fleet.example.invalid/api/workflows/fleet/signal/design%2Fsynthetic%207"
        )
    }

    // MARK: - The live socket

    func testTheSocketUpgradesOverTheSecureSchemeWithTheServiceTokenOnly() throws {
        let request = try XCTUnwrap(URLSessionControlLiveStream.upgradeRequest(.fixture))

        XCTAssertEqual(request.url?.absoluteString, "wss://fleet.example.invalid/ws")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: ControlRequest.accessClientIdHeader),
            "client-id-1"
        )
        // The socket only delivers state, and the orchestrator asks for no token on it.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - Reading an answer

    func testASuccessIsNotAFailure() {
        XCTAssertNil(URLSessionControlAPIClient.failure(status: 200, body: Data()))
        XCTAssertNil(URLSessionControlAPIClient.failure(status: 204, body: Data()))
    }

    func testARedirectOrAForbiddenMeansTheProxyRefused() {
        // A proxy that does not recognise the caller redirects to a sign-in page. The redirect is
        // refused rather than followed, so it arrives here as itself.
        XCTAssertEqual(URLSessionControlAPIClient.failure(status: 302, body: Data()), .accessDenied)
        XCTAssertEqual(URLSessionControlAPIClient.failure(status: 403, body: Data()), .accessDenied)
    }

    func testAnUnauthorizedMeansTheOrchestratorRefusedTheOperatorToken() {
        XCTAssertEqual(URLSessionControlAPIClient.failure(status: 401, body: Data()), .unauthorized)
    }

    func testAConflictCarriesTheOrchestratorsCode() {
        let body = Data(#"{"error":"stale_gate","expectedGateRef":"a","currentGateRef":"b"}"#.utf8)
        XCTAssertEqual(
            URLSessionControlAPIClient.failure(status: 409, body: body),
            .gateChanged("stale_gate")
        )
    }

    func testAnErrorPageIsNeverShownAsAMessage() {
        let page = Data("<html><body>Bad gateway</body></html>".utf8)
        XCTAssertEqual(
            URLSessionControlAPIClient.failure(status: 502, body: page),
            .refused(status: 502, message: nil)
        )
        XCTAssertEqual(
            URLSessionControlAPIClient.failure(
                status: 400,
                body: Data(#"{"error":"run_required"}"#.utf8)
            ),
            .refused(status: 400, message: "run_required")
        )
    }

    func testABodyThatIsNotAnAgentListIsADecodingFailure() {
        XCTAssertThrowsError(
            try URLSessionControlAPIClient.decode(
                Data("<html>sign in</html>".utf8),
                JSONDecoder()
            ) as LossyList<FleetAgent>
        ) { error in
            guard case .decoding? = error as? ControlAPIError else {
                return XCTFail("expected a decoding failure, got \(error)")
            }
        }
    }

    // MARK: - Redirects

    func testTheSessionRefusesEveryRedirect() async throws {
        let delegate = RedirectRefusingDelegate()
        let session = URLSession(configuration: .ephemeral)
        let original = URLRequest(url: try XCTUnwrap(URL(string: "https://fleet.example.invalid/api/agents")))
        let target = try XCTUnwrap(URL(string: "https://signin.example.invalid/login"))
        let response = try XCTUnwrap(
            HTTPURLResponse(url: target, statusCode: 302, httpVersion: nil, headerFields: nil)
        )

        // Never resumed: this asks the delegate the question directly, with no network.
        let followed = await delegate.urlSession(
            session,
            task: session.dataTask(with: original),
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: target)
        )
        XCTAssertNil(followed, "a redirect would carry the service token to another host")
    }

    func testTheSessionKeepsNoCookiesAndNoCache() {
        let configuration = ControlTransport.makeSession().configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
    }
}
