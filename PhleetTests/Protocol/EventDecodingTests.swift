import XCTest
@testable import Phleet

/// Decoding is the boundary's only enforcement point, so the cases that matter are the ones a
/// future minor will produce: a kind this build has never seen, an enum raw value it has never
/// seen, and the one envelope whose `seq` is genuinely null.
final class EventDecodingTests: XCTestCase {

    func testEveryAllowlistedKindDecodesWithItsPayload() throws {
        let events = try ProtocolFixture.events("all-kinds")
        let byKind = Dictionary(grouping: events, by: \.kind)

        for kind in EventKind.rendered {
            XCTAssertNotNil(byKind[kind], "no fixture event for \(kind.rawValue)")
        }

        for event in events {
            switch event.kind {
            case .submissionAccepted:
                guard case .submissionAccepted(let payload) = event.payload else {
                    return XCTFail("submission.accepted decoded to \(event.payload)")
                }
                XCTAssertEqual(payload.disposition, .ran)

            case .turnProgress:
                guard case .turnProgress(let payload) = event.payload else {
                    return XCTFail("turn.progress decoded to \(event.payload)")
                }
                XCTAssertEqual(payload.activity, .tool)
                XCTAssertEqual(payload.toolName, "search")

            case .turnRecoveredAnswer:
                guard case .turnRecoveredAnswer(let payload) = event.payload else {
                    return XCTFail("turn.recovered_answer decoded to \(event.payload)")
                }
                // Carried by notices and recovered answers too, not only by `turn.final`.
                XCTAssertEqual(payload.truncated, true)

            case .controlAck:
                guard case .controlAck(let payload) = event.payload else {
                    return XCTFail("control.ack decoded to \(event.payload)")
                }
                XCTAssertEqual(payload.target, "turn")
                XCTAssertEqual(payload.accepted, true)
                XCTAssertEqual(payload.hadRunningTask, true)

            case .turnFinal:
                guard case .turnFinal(let payload) = event.payload else {
                    return XCTFail("turn.final decoded to \(event.payload)")
                }
                // `completion: "idle"` legitimately carries empty text.
                XCTAssertEqual(payload.completion, .idle)
                XCTAssertEqual(payload.text, "")
                XCTAssertEqual(payload.mergedSubmissionIds, ["s3"])

            case .turnCanceled:
                guard case .turnCanceled(let payload) = event.payload else {
                    return XCTFail("turn.canceled decoded to \(event.payload)")
                }
                XCTAssertEqual(payload.reason, .operatorAction)

            case .turnOutcomeUnknown:
                guard case .turnOutcomeUnknown(let payload) = event.payload else {
                    return XCTFail("turn.outcome_unknown decoded to \(event.payload)")
                }
                XCTAssertEqual(payload.reason, .turnReaped)

            default:
                break
            }
        }
    }

    func testReplayGapCarriesANullSeq() throws {
        let events = try ProtocolFixture.events("all-kinds")
        let gap = try XCTUnwrap(events.first { $0.kind == .conversationReplayGap })

        // The reason dedupe is on `eventId` rather than `seq`.
        XCTAssertNil(gap.seq)
        guard case .replayGap(let payload) = gap.payload else {
            return XCTFail("conversation.replay_gap decoded to \(gap.payload)")
        }
        XCTAssertEqual(payload.retainedFloorSeq, 10)
    }

    func testAnUnrecognisedKindDecodesRatherThanThrowing() throws {
        let events = try ProtocolFixture.events("all-kinds")
        let unknown = events.filter {
            if case .unknown = $0.kind { return true }
            return false
        }

        XCTAssertEqual(unknown.count, 1)
        XCTAssertEqual(
            unknown.first?.kind.rawValue,
            "turn.something_this_build_has_never_seen"
        )
        XCTAssertEqual(unknown.first?.isRenderedKind, false)
    }

    func testAnUnrecognisedEnumRawValueDecodesRatherThanThrowing() throws {
        let events = try ProtocolFixture.events("outcome-unknown-unrecognised-reason")
        let terminal = try XCTUnwrap(events.first { $0.kind == .turnOutcomeUnknown })

        guard case .turnOutcomeUnknown(let payload) = terminal.payload else {
            return XCTFail("turn.outcome_unknown decoded to \(terminal.payload)")
        }
        XCTAssertEqual(
            payload.reason,
            .unrecognized("a_reason_this_build_has_never_seen"),
            "an unknown reason must not fall through to a recognised case"
        )
    }

    func testCancelReasonUnknownIsNotTheSameAsUnrecognised() {
        // `unknown` is a real value on the wire. Collapsing it into the fallback would make "the
        // server said unknown" and "this build has not heard of this" indistinguishable.
        XCTAssertEqual(CancelReason(rawValue: "unknown"), .unknown)
        XCTAssertEqual(CancelReason(rawValue: "brand-new"), .unrecognized("brand-new"))
        XCTAssertNotEqual(CancelReason.unknown, CancelReason.unrecognized("unknown"))
    }

    func testCancelReasonKnowsWhatThisClientInitiated() {
        XCTAssertTrue(CancelReason.user.wasInitiatedHere)
        for reason in [CancelReason.operatorAction, .bridge, .unknown, .unrecognized("x")] {
            XCTAssertFalse(reason.wasInitiatedHere)
        }
    }

    func testAMissingPayloadDecodesRatherThanThrowing() throws {
        let json = Data(
            #"{"protocol":"fleet.conversation.v1","eventId":"e1","seq":1,"kind":"turn.started"}"#
                .utf8
        )
        let event = try ConversationEvent.decode(from: json)

        XCTAssertEqual(event.kind, .turnStarted)
        XCTAssertNil(event.identity.submissionId)
    }

    func testAnAbsentFieldAndAnExplicitNullAreTheSame() throws {
        let absent = Data(
            #"{"protocol":"fleet.conversation.v1","eventId":"a","kind":"turn.started"}"#.utf8
        )
        let explicit = Data(
            #"{"protocol":"fleet.conversation.v1","eventId":"a","seq":null,"kind":"turn.started"}"#
                .utf8
        )

        XCTAssertEqual(
            try ConversationEvent.decode(from: absent).seq,
            try ConversationEvent.decode(from: explicit).seq
        )
    }

    func testProtocolVersionIsComparedOrdinally() {
        XCTAssertTrue(ProtocolVersion.isSupported("fleet.conversation.v1"))
        XCTAssertFalse(ProtocolVersion.isSupported(nil))
        XCTAssertFalse(ProtocolVersion.isSupported(""))
        XCTAssertFalse(ProtocolVersion.isSupported("fleet.conversation.v2"))
        XCTAssertFalse(ProtocolVersion.isSupported("Fleet.Conversation.v1"))
    }
}

extension ConversationEvent {
    /// Reads through to the kind, so the assertion above says what it means.
    var isRenderedKind: Bool { kind.isRendered }
}
