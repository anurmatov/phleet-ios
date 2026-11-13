import XCTest
@testable import Phleet

/// URLProtocol intercepts the production URLSession client, not a second request builder.
final class HumanInputTransportTests: XCTestCase {
    func testExactHistoryAndAnswerWireEnvelope() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HumanInputURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = URLSessionControlAPIClient(session: session)
        let events = try await api.exactRunHistory(.fixture, namespace: "fleet/one",
                                                  workflowId: "human-input/a b", runId: "run/one")
        XCTAssertEqual(events.count, 1)
        let gate = HumanInputTests.gate()
        let request = try HumanInputRequest.from(history: HumanInputTests.history(mode: "text"), gate: gate)
        try await api.sendSignal(.fixture, namespace: "fleet/one", workflowId: "human-input/a b",
                                 body: request.body(gate: gate, value: "  raw\n🧭 ", comment: " \"why\" "))
    }

    /// The app reaches the orchestrator through the signed-in wrapper, so the exact-run read
    /// must carry this phone's access token like every other read.
    @MainActor
    func testSignedInExactHistoryCarriesTheCurrentToken() async throws {
        let base = FakeControlAPI()
        let tokens = AccessTokenHolder(
            credentialStore: InMemoryCredentialStore(credential: .fixture), clock: TestClock()
        ) { credential in
            try await base.mintToken(try XCTUnwrap(credential.connection),
                                     deviceId: credential.deviceId, deviceSecret: credential.deviceSecret)
        }
        let api = SignedInControlAPI(base: base, tokens: tokens)
        _ = try await api.exactRunHistory(.unsignedFixture, namespace: "fleet",
                                          workflowId: "human-input-sample", runId: "request-run")
        XCTAssertEqual(base.calls.last,
                       .exactRunHistory(namespace: "fleet", workflowId: "human-input-sample", runId: "request-run"))
        XCTAssertEqual(base.accessTokens.last, "access-token-1")
    }

    func testMissingExactRunNeverBuildsALatestRunRequest() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await URLSessionControlAPIClient(session: session).exactRunHistory(
                .fixture, namespace: "fleet", workflowId: "request", runId: ""
            )
            XCTFail("missing run must be refused before transport")
        } catch {
            XCTAssertEqual(error as? ControlAPIError, .decoding("exact run required"))
        }
    }
}

private final class HumanInputURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isRead = request.httpMethod == "GET"
        XCTAssertEqual(request.url?.absoluteString, isRead
            ? "https://fleet.example.invalid/api/workflows/fleet%2Fone/history/human-input%2Fa%20b?runId=run/one"
            : "https://fleet.example.invalid/api/workflows/fleet%2Fone/signal/human-input%2Fa%20b")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token-1")
        if !isRead {
            // URLSession may move the encoded body to its stream before handing it to a protocol.
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            do {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(Set(object.keys), ["signalName", "workflowType", "payload", "runId", "expectedGateRef"])
                XCTAssertEqual(object["signalName"], "request-input")
                XCTAssertEqual(object["workflowType"], "UweHumanInputWorkflow")
                XCTAssertEqual(object["runId"], "request-run")
                XCTAssertEqual(object["expectedGateRef"], "request-run")
                let payload = try XCTUnwrap(object["payload"])
                let answer = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String]
                XCTAssertEqual(answer, ["Value": "  raw\n🧭 ", "Comment": " \"why\" "])
            } catch { XCTFail("invalid production signal body: \(error)") }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((isRead ? "[{\"eventId\":1,\"eventType\":\"WorkflowStarted\"}]" : "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
