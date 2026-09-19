import XCTest
@testable import Phleet

/// The wire shapes, asserted on encoded JSON rather than on the Swift types.
///
/// Both blockers this slice exists to avoid are here: a body missing `protocol` is
/// `400 unsupported_protocol` on every route including enrollment, and a cursor body nested
/// under a `conversation.ack` wrapper writes nothing and shows no symptom beyond a cursor that
/// never advances.
final class WireBodyTests: XCTestCase {

    private func encodedKeys(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - The protocol field

    func testEveryBodyBearingRequestCarriesTheProtocolField() throws {
        let bodies: [(String, any Encodable)] = [
            ("POST /v1/auth/devices", RegisterDeviceBody(enrollmentCode: "code")),
            (
                "POST /v1/auth/token",
                MintTokenBody(deviceId: "device", deviceSecret: "secret")
            ),
            (
                "POST /v1/conversations",
                OpenConversationBody(externalRef: "main", clientInstanceId: "instance")
            ),
            (
                "POST /v1/conversations/{id}/submissions",
                SubmissionBody(
                    type: .create,
                    submissionId: "s1",
                    idempotencyKey: "k1",
                    text: "hello"
                )
            ),
            (
                "POST /v1/conversations/{id}/cursor",
                CursorBody(clientInstanceId: "instance", deliveredSeq: 41, readSeq: 41)
            )
        ]

        XCTAssertEqual(bodies.count, 5, "all five body-bearing requests are covered")

        for (route, body) in bodies {
            let keys = try encodedKeys(body)
            XCTAssertEqual(
                keys["protocol"] as? String,
                "fleet.conversation.v1",
                "\(route) must carry the protocol field, exactly"
            )
        }
    }

    // MARK: - The cursor body

    func testTheCursorBodyIsFlat() throws {
        let keys = try encodedKeys(
            CursorBody(clientInstanceId: "instance", deliveredSeq: 41, readSeq: 40)
        )

        XCTAssertEqual(
            Set(keys.keys),
            ["protocol", "clientInstanceId", "deliveredSeq", "readSeq"]
        )
        XCTAssertNil(
            keys["conversation.ack"],
            "conversation.ack is the kind the server records, not a wrapper on the wire"
        )
        XCTAssertEqual(keys["deliveredSeq"] as? Int, 41)
        XCTAssertEqual(keys["readSeq"] as? Int, 40)
    }

    func testTheCursorBodyOmitsAnAbsentReadSeq() throws {
        let keys = try encodedKeys(
            CursorBody(clientInstanceId: "instance", deliveredSeq: 41, readSeq: nil)
        )
        XCTAssertEqual(Set(keys.keys), ["protocol", "clientInstanceId", "deliveredSeq"])
    }

    // MARK: - Submission

    func testASubmissionSendsNoAttachmentsArray() throws {
        let keys = try encodedKeys(
            SubmissionBody(type: .create, submissionId: "s1", idempotencyKey: "k1", text: "hi")
        )
        // A non-empty array is `400 unsupported_attachments` — refused, never silently dropped —
        // and this slice has nothing to attach, so the key is absent rather than empty.
        XCTAssertNil(keys["attachments"])
        XCTAssertEqual(keys["type"] as? String, "create")
    }

    // MARK: - Responses

    func testA201DecodesWithAnAcceptedSeqAndA202Without() throws {
        let created = Data(
            #"{"protocol":"fleet.conversation.v1","submissionId":"s1","acceptedSeq":41}"#.utf8
        )
        let pending = Data(
            #"{"protocol":"fleet.conversation.v1","submissionId":"s1"}"#.utf8
        )

        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(SubmissionAcceptedResponse.self, from: created).acceptedSeq,
            41
        )
        // A 202 is a success. Treating an absent `acceptedSeq` as a decode failure makes the
        // send read as failed, and the retry then loops forever against a server that keeps
        // answering 202.
        XCTAssertNil(
            try decoder.decode(SubmissionAcceptedResponse.self, from: pending).acceptedSeq
        )
    }

    func testSessionLimitsFallBackToTheDocumentedDefaults() throws {
        let partial = Data(
            #"{"protocol":"fleet.conversation.v1","principalId":"p","limits":{"inboundTextBytes":1024}}"#
                .utf8
        )
        let session = try JSONDecoder().decode(SessionResponse.self, from: partial)

        XCTAssertEqual(session.limits.inboundTextBytes, 1024)
        XCTAssertEqual(session.limits.catchUpLimitMax, 1000)
        XCTAssertEqual(session.limits.outboundBufferEvents, 256)
        XCTAssertNil(session.agentLabel)
    }

    func testDocumentedDefaultsMatchTheContract() {
        let limits = SessionLimits.documentedDefaults
        XCTAssertEqual(limits.inboundTextBytes, 32768)
        XCTAssertEqual(limits.catchUpLimitDefault, 200)
        XCTAssertEqual(limits.catchUpLimitMax, 1000)
        XCTAssertEqual(limits.outboundBufferEvents, 256)
        XCTAssertEqual(limits.identifierMaxLength, 128)
    }

    func testCatchUpGapIsAbsentUnlessHistoryExpired() throws {
        let withoutGap = Data(
            #"{"protocol":"fleet.conversation.v1","events":[],"nextAfterSeq":40,"hasMore":false}"#
                .utf8
        )
        let withGap = Data(
            #"{"protocol":"fleet.conversation.v1","gap":{"fromSeq":1,"toSeq":9,"retainedFloorSeq":10},"events":[],"nextAfterSeq":40,"hasMore":false}"#
                .utf8
        )

        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(CatchUpResponse.self, from: withoutGap).gap)
        XCTAssertEqual(
            try decoder.decode(CatchUpResponse.self, from: withGap).gap?.retainedFloorSeq,
            10
        )
    }

    func testTheInternalErrorCodeCarriesBothStatuses() {
        // The split: the same code arrives on a 500 this client must not hammer and on a 503 it
        // should back off and retry.
        XCTAssertEqual(ProtocolErrorCode.internalError.expectedStatuses, [500, 503])
        XCTAssertEqual(
            ProtocolErrorCode.treatment(code: .internalError, status: 503),
            .backoff
        )
        XCTAssertEqual(
            ProtocolErrorCode.treatment(code: .internalError, status: 500),
            .manualRetry
        )
    }

    func testAnUnknownErrorCodeDecodesRatherThanThrowing() throws {
        let body = Data(
            #"{"protocol":"fleet.conversation.v1","code":"a_code_from_a_later_minor"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(ProtocolErrorBody.self, from: body)
        XCTAssertEqual(decoded.code, .unknown("a_code_from_a_later_minor"))
    }
}
