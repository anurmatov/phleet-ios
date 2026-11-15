import XCTest
@testable import Phleet

/// Synthetic text for complete-value tests: every awkward kind of character, in a known order.
enum SyntheticText {

    /// `count` Unicode scalars cycling through characters outside the Basic Multilingual Plane,
    /// a combining mark after its base, line breaks, a tab, quotes, backslashes and a slash.
    static func unicode(scalars count: Int) -> String {
        let pattern: [Unicode.Scalar] = [
            "a", "e", "\u{0301}", "\u{1F9ED}", "\n", "\"", "\\", "/", "\t", "\u{4E16}", "\u{10FFFF}", " "
        ]
        var scalars = String.UnicodeScalarView()
        for index in 0..<count {
            scalars.append(pattern[index % pattern.count])
        }
        return String(scalars)
    }

    /// A JSON string literal for `text`, escaping every scalar outside ASCII as `\uXXXX` — with
    /// surrogate pairs — the way a server's default encoder writes it.
    static func asciiJSONLiteral(_ text: String) -> String {
        var out = "\""
        for unit in text.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x09: out += "\\t"
            case 0x20..<0x7F: out.append(Character(Unicode.Scalar(UInt8(unit))))
            default: out += String(format: "\\u%04x", unit)
            }
        }
        return out + "\""
    }

    static func scalarsEqual(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }
}

/// The documented complete-value contract, read from synthetic answers. These prove what this
/// client does with answers shaped as documented — not that any server answers this way.
final class EventValueContractTests: XCTestCase {

    private let request = EventValueRequest(
        namespace: "fleet",
        workflowId: "design/synthetic+7 %2F",
        runId: "run+one/2",
        eventId: 42,
        field: .input
    )

    private func envelope(
        status: String,
        values: String = "[]",
        reason: String? = nil,
        sourceEventId: Int? = nil,
        namespace: String = "fleet",
        workflowId: String = "design/synthetic+7 %2F",
        runId: String = "run+one/2",
        eventId: Int = 42,
        field: String = "input",
        limitBytes: Int = 1_048_576
    ) throws -> EventValueEnvelope {
        func quoted(_ value: String) -> String {
            String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
        }
        let json = """
        {"namespace":\(quoted(namespace)),"workflowId":\(quoted(workflowId)),\
        "runId":\(quoted(runId)),"eventId":\(eventId),"field":\(quoted(field)),\
        "sourceEventId":\(sourceEventId.map(String.init) ?? "null"),"status":\(quoted(status)),\
        "values":\(values),"reason":\(reason.map(quoted) ?? "null"),"limitBytes":\(limitBytes)}
        """
        return try JSONDecoder().decode(EventValueEnvelope.self, from: Data(json.utf8))
    }

    // MARK: - Complete values

    func testALargeUnicodeValueArrivesExactlyAsStored() throws {
        let original = SyntheticText.unicode(scalars: 100_000)
        // The server's encoder may escape everything outside ASCII; the text must not change.
        for literal in [
            String(decoding: try JSONEncoder().encode(original), as: UTF8.self),
            SyntheticText.asciiJSONLiteral(original)
        ] {
            let answer = try envelope(
                status: "complete",
                values: #"[{"encoding":"text/plain","text":"# + literal + "}]",
                sourceEventId: 42
            )
            guard case .complete(let values, let source) = try answer.checked(against: request) else {
                return XCTFail("a complete answer was not read as complete")
            }
            XCTAssertEqual(source, 42)
            XCTAssertEqual(values.count, 1)
            XCTAssertEqual(values[0].text.unicodeScalars.count, 100_000)
            XCTAssertTrue(
                SyntheticText.scalarsEqual(values[0].text, original),
                "the value changed on the way: normalised, truncated or unescaped"
            )
        }
    }

    func testPayloadsStaySeparateAndInOrderWithJSONLiteralsKept() throws {
        // A JSON string stays a JSON literal, quotes and escapes included; malformed JSON is raw
        // text like any other; empty text is a value.
        let answer = try envelope(
            status: "complete",
            values: #"""
            [{"encoding":"json/plain","text":"\"hello\\nworld\""},
             {"encoding":"json/plain","text":"{\"truncated\": "},
             {"encoding":"text/plain","text":""}]
            """#,
            sourceEventId: 42
        )
        XCTAssertEqual(
            try answer.checked(against: request),
            .complete(
                values: [
                    EventPayloadText(encoding: "json/plain", text: #""hello\nworld""#),
                    EventPayloadText(encoding: "json/plain", text: #"{"truncated": "#),
                    EventPayloadText(encoding: "text/plain", text: "")
                ],
                sourceEventId: 42
            )
        )
    }

    func testACompletedActivitysInputNamesTheEventThatScheduledIt() throws {
        let answer = try envelope(
            status: "complete",
            values: #"[{"encoding":"json/plain","text":"1"}]"#,
            sourceEventId: 37
        )
        guard case .complete(_, let source) = try answer.checked(against: request) else {
            return XCTFail("not complete")
        }
        XCTAssertEqual(source, 37)
    }

    func testOnlyAnEncodingThatSaysJSONIsReadAsJSON() {
        XCTAssertTrue(EventPayloadText(encoding: "json/plain", text: "{}").isJSONEncoded)
        XCTAssertTrue(EventPayloadText(encoding: "json/protobuf", text: "{}").isJSONEncoded)
        XCTAssertFalse(EventPayloadText(encoding: "text/plain", text: "{}").isJSONEncoded)
        XCTAssertFalse(EventPayloadText(encoding: "JSON/PLAIN", text: "{}").isJSONEncoded)
    }

    // MARK: - No value

    func testEveryDocumentedNoValueStateIsReadAsItself() throws {
        XCTAssertEqual(
            try envelope(status: "absent", reason: "no_value").checked(against: request),
            .absent
        )
        let reasons: [(String, EventValueUnsupportedReason)] = [
            ("encoding", .encoding), ("invalid_utf8", .invalidUTF8),
            ("event_type", .eventType), ("encoded_failure", .encodedFailure)
        ]
        for (raw, reason) in reasons {
            XCTAssertEqual(
                try envelope(status: "unsupported", reason: raw).checked(against: request),
                .unsupported(reason)
            )
        }
        XCTAssertEqual(
            try envelope(status: "too_large", reason: "value_size").checked(against: request),
            .tooLarge(limitBytes: 1_048_576)
        )
    }

    // MARK: - Refused answers

    func testAnAnswerForAnotherRunEventOrFieldIsRefusedWhole() throws {
        let values = #"[{"encoding":"text/plain","text":"another execution's text"}]"#
        let others: [EventValueEnvelope] = [
            try envelope(status: "complete", values: values, sourceEventId: 42, namespace: "Fleet"),
            try envelope(status: "complete", values: values, sourceEventId: 42, workflowId: "design/synthetic+7"),
            try envelope(status: "complete", values: values, sourceEventId: 42, runId: "run+one/1"),
            try envelope(status: "complete", values: values, sourceEventId: 43, eventId: 43),
            try envelope(status: "complete", values: values, sourceEventId: 42, field: "output")
        ]
        for other in others {
            XCTAssertThrowsError(try other.checked(against: request)) { error in
                XCTAssertEqual(error as? EventValueAnswerError, .identityMismatch)
            }
        }
    }

    func testIdentifiersAreComparedScalarByScalar() throws {
        // "é" as one scalar and as "e" plus a combining accent are equal to Swift's `==` and
        // are two different workflow identifiers.
        let composed = EventValueRequest(namespace: "fleet", workflowId: "caf\u{E9}", runId: "r",
                                         eventId: 1, field: .output)
        let answer = try envelope(status: "absent", reason: "no_value",
                                  workflowId: "cafe\u{301}", runId: "r", eventId: 1, field: "output")
        XCTAssertEqual("caf\u{E9}", "cafe\u{301}", "the premise: Swift calls these equal")
        XCTAssertThrowsError(try answer.checked(against: composed)) { error in
            XCTAssertEqual(error as? EventValueAnswerError, .identityMismatch)
        }
    }

    func testAnAnswerThatContradictsItselfIsRefused() throws {
        let one = #"[{"encoding":"text/plain","text":"x"}]"#
        let contradictions: [EventValueEnvelope] = [
            try envelope(status: "complete", sourceEventId: 42),
            try envelope(status: "complete", values: one, reason: "no_value", sourceEventId: 42),
            try envelope(status: "complete", values: one),
            try envelope(status: "complete", values: one, sourceEventId: 0),
            try envelope(status: "complete", values: one, sourceEventId: 43),
            try envelope(status: "complete", values: one, sourceEventId: 42, limitBytes: 0),
            try envelope(status: "absent", values: one, reason: "no_value"),
            try envelope(status: "absent", reason: "no_value", sourceEventId: 42),
            try envelope(status: "absent"),
            try envelope(status: "too_large", values: one, reason: "value_size"),
            try envelope(status: "unsupported", values: one, reason: "encoding")
        ]
        for answer in contradictions {
            XCTAssertThrowsError(try answer.checked(against: request)) { error in
                XCTAssertEqual(error as? EventValueAnswerError, .inconsistent, "\(answer)")
            }
        }
    }

    func testCompleteTextLargerThanTheLimitIsRefused() throws {
        // Equality is accepted; one byte more is not a complete value under this limit.
        let exact = try envelope(
            status: "complete",
            values: #"[{"encoding":"text/plain","text":"\#(String(repeating: "a", count: 8))"}]"#,
            sourceEventId: 42,
            limitBytes: 8
        )
        XCTAssertNoThrow(try exact.checked(against: request))
        let over = try envelope(
            status: "complete",
            values: #"[{"encoding":"text/plain","text":"aaaa"},{"encoding":"text/plain","text":"aaaaé"}]"#,
            sourceEventId: 42,
            limitBytes: 9
        )
        XCTAssertThrowsError(try over.checked(against: request))
    }

    func testAStatusOrReasonThisBuildDoesNotKnowIsNotGuessedAt() throws {
        for answer in [
            try envelope(status: "partial"),
            try envelope(status: "unsupported", reason: "compressed"),
            try envelope(status: "absent", reason: "deleted"),
            try envelope(status: "too_large", reason: "count")
        ] {
            XCTAssertThrowsError(try answer.checked(against: request)) { error in
                XCTAssertEqual(error as? EventValueAnswerError, .unrecognized)
            }
        }
    }

    func testAnAnswerMissingARequiredKeyDoesNotDecode() {
        let missing = Data(#"{"namespace":"fleet","workflowId":"w","runId":"r","eventId":1,"field":"input","status":"absent","reason":"no_value","limitBytes":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EventValueEnvelope.self, from: missing))
    }

    // MARK: - Which fields an event offers

    func testAnEventOffersTheFieldsTheContractMapsForItsKind() {
        func fields(_ type: String) -> [EventValueField] {
            EventValueRequest.fields(for: WorkflowEvent(eventId: 1, eventType: type))
        }
        XCTAssertEqual(fields("WorkflowStarted"), [.input])
        XCTAssertEqual(fields("ActivityScheduled"), [.input])
        XCTAssertEqual(fields("SignalReceived"), [.input])
        XCTAssertEqual(fields("WorkflowCompleted"), [.output])
        XCTAssertEqual(fields("ActivityCompleted"), [.input, .output])
        XCTAssertEqual(fields("WorkflowFailed"), [.failure])
        XCTAssertEqual(fields("ActivityFailed"), [.failure])
        XCTAssertEqual(fields("WorkflowCanceled"), [])
        XCTAssertEqual(fields("ANewKindOfEvent"), [])
    }

    func testARequestNamesTheRowsOwnRunAndEvent() {
        let run = WorkflowRun(workflowId: "w/1", runId: "run-b", workflowType: "T", namespace: "ns")
        let event = WorkflowEvent(eventId: 9, eventType: "ActivityCompleted")
        XCTAssertEqual(
            EventValueRequest(run: run, event: event, field: .output),
            EventValueRequest(namespace: "ns", workflowId: "w/1", runId: "run-b", eventId: 9, field: .output)
        )
    }

    // MARK: - On the wire

    func testTheRequestEscapesEveryIdentifierOnceAndCarriesNoSecretInTheURL() throws {
        let built = try ControlRequest.make(
            connection: .fixture,
            method: "GET",
            percentEncodedPath: ControlRequest.eventValuePath(
                namespace: request.namespace,
                workflowId: request.workflowId
            ),
            percentEncodedQuery: ControlRequest.eventValueQuery(request)
        )
        XCTAssertEqual(
            built.url?.absoluteString,
            "https://fleet.example.invalid/api/workflows/fleet/event-value/"
                + "design%2Fsynthetic%2B7%20%252F?runId=run%2Bone%2F2&eventId=42&field=input"
        )
        XCTAssertEqual(built.value(forHTTPHeaderField: "Authorization"), "Bearer access-token-1")
        let url = try XCTUnwrap(built.url?.absoluteString)
        XCTAssertFalse(url.contains("access-token-1"))
        XCTAssertFalse(url.contains("client-secret-1"))
    }

    func testTheProductionClientReadsTheExactEventAndChecksTheAnswer() async throws {
        let api = Self.client()
        EventValueURLProtocol.answer = { url in
            XCTAssertEqual(
                url.absoluteString,
                "https://fleet.example.invalid/api/workflows/fleet/event-value/"
                    + "design%2Fsynthetic%2B7%20%252F?runId=run%2Bone%2F2&eventId=42&field=input",
                "every value travels once-escaped, so + and / arrive as themselves"
            )
            return (200, #"{"namespace":"fleet","workflowId":"design/synthetic+7 %2F","runId":"run+one/2","eventId":42,"field":"input","sourceEventId":42,"status":"complete","values":[{"encoding":"json/plain","text":"{\"a\":1}"}],"reason":null,"limitBytes":1048576}"#)
        }
        let result = try await api.eventValue(.fixture, request: request)
        XCTAssertEqual(
            result,
            .complete(values: [EventPayloadText(encoding: "json/plain", text: #"{"a":1}"#)], sourceEventId: 42)
        )
    }

    func testTheServersFailuresAreToldApartAndAnOlderServerIsNamed() async throws {
        let cases: [(Int, String, EventValuesModel.Failure)] = [
            (404, "", .notOffered),
            (404, "<html>Not here</html>", .notOffered),
            (404, #"{"error":"not_found"}"#, .notFound),
            (405, "", .notOffered),
            (503, #"{"error":"history_unavailable"}"#, .historyUnavailable),
            (503, #"{"error":"history_timeout"}"#, .timedOut),
            (400, #"{"error":"invalid_request"}"#, .refused("invalid_request")),
            (502, "", .refused(nil)),
            (401, "", .tokenRejected),
            (403, "", .accessDenied),
            // A server that answers the path with something else entirely.
            (200, "<html>dashboard</html>", .unreadableAnswer),
            (200, #"[{"eventId":1,"eventType":"WorkflowStarted"}]"#, .unreadableAnswer),
            // Another run's value is never shown under this one.
            (200, #"{"namespace":"fleet","workflowId":"design/synthetic+7 %2F","runId":"run+one/1","eventId":42,"field":"input","sourceEventId":42,"status":"complete","values":[{"encoding":"text/plain","text":"x"}],"reason":null,"limitBytes":1048576}"#, .unreadableAnswer)
        ]
        let api = Self.client()
        for (status, body, expected) in cases {
            EventValueURLProtocol.answer = { _ in (status, body) }
            do {
                _ = try await api.eventValue(.fixture, request: request)
                XCTFail("\(status) \(body) was read as a value")
            } catch {
                XCTAssertEqual(EventValuesModel.failure(for: error), expected, "\(status) \(body)")
            }
        }
    }

    func testABlankRunOrEventIsRefusedBeforeAnythingIsSent() async {
        let api = Self.client()
        EventValueURLProtocol.answer = { _ in
            XCTFail("a request without an exact run or event went out")
            return (500, "")
        }
        let blank = [
            EventValueRequest(namespace: "fleet", workflowId: "w", runId: " ", eventId: 1, field: .input),
            EventValueRequest(namespace: "fleet", workflowId: "", runId: "r", eventId: 1, field: .input),
            EventValueRequest(namespace: "fleet", workflowId: "w", runId: "r", eventId: 0, field: .input)
        ]
        for request in blank {
            do {
                _ = try await api.eventValue(.fixture, request: request)
                XCTFail("refused nothing")
            } catch {
                XCTAssertEqual(error as? ControlAPIError, .decoding("exact event required"))
            }
        }
        do {
            _ = try await api.runHistory(.fixture, namespace: "fleet", workflowId: "w", runId: "")
            XCTFail("a history read without its run went out")
        } catch {
            XCTAssertEqual(error as? ControlAPIError, .decoding("exact run required"))
        }
    }

    func testTheHistoryIsReadForTheExactRun() async throws {
        let api = Self.client()
        EventValueURLProtocol.answer = { url in
            XCTAssertEqual(
                url.absoluteString,
                "https://fleet.example.invalid/api/workflows/fleet/history/design%2Fsynthetic%207"
                    + "?runId=run%2Bone"
            )
            return (200, #"[{"eventId":1,"eventType":"WorkflowStarted"}]"#)
        }
        let events = try await api.runHistory(
            .fixture, namespace: "fleet", workflowId: "design/synthetic 7", runId: "run+one"
        )
        XCTAssertEqual(events.map(\.eventId), [1])
    }

    @MainActor
    func testTheSignedInClientCarriesTheCurrentToken() async throws {
        let base = FakeControlAPI()
        let tokens = AccessTokenHolder(
            credentialStore: InMemoryCredentialStore(credential: .fixture), clock: TestClock()
        ) { credential in
            try await base.mintToken(try XCTUnwrap(credential.connection),
                                     deviceId: credential.deviceId, deviceSecret: credential.deviceSecret)
        }
        let api = SignedInControlAPI(base: base, tokens: tokens)
        _ = try await api.eventValue(.unsignedFixture, request: request)
        XCTAssertEqual(base.calls.last, .eventValue(request))
        XCTAssertEqual(base.accessTokens.last, "access-token-1")
    }

    private static func client() -> URLSessionControlAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EventValueURLProtocol.self]
        return URLSessionControlAPIClient(session: URLSession(configuration: configuration))
    }
}

/// Answers every request with what the test says, for the production client.
final class EventValueURLProtocol: URLProtocol {

    nonisolated(unsafe) static var answer: (URL) -> (Int, String) = { _ in (500, "") }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (status, body) = Self.answer(url)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
