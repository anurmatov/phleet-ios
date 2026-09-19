import XCTest
@testable import Phleet

/// The discriminator is `kind`, not `type`.
///
/// The published prose documentation shows `type`, and a client written from it fails to decode
/// the very first frame it ever receives. There is also no `event` wrapper: a frame that is not
/// a control frame **is** the bare envelope.
final class StreamFrameTests: XCTestCase {

    func testHelloDecodesAsAControlFrame() throws {
        let data = Data(
            #"{"protocol":"fleet.conversation.v1","kind":"hello","conversationId":"c1","nextSeq":41,"retainedFloorSeq":12}"#
                .utf8
        )

        guard case .hello(let hello) = try StreamFrame.decode(from: data) else {
            return XCTFail("expected a hello frame")
        }
        XCTAssertEqual(hello.conversationId, "c1")
        XCTAssertEqual(hello.nextSeq, 41)
        XCTAssertEqual(hello.retainedFloorSeq, 12)
    }

    func testPingDecodesAsAControlFrame() throws {
        XCTAssertEqual(try StreamFrame.decode(from: Data(#"{"kind":"ping"}"#.utf8)), .ping)
    }

    func testAnEventKindDecodesAsABareEnvelope() throws {
        let data = Data(
            #"{"protocol":"fleet.conversation.v1","eventId":"e1","seq":42,"kind":"turn.final","identity":{"submissionId":"s1"},"payload":{"text":"hi","completion":"completed","mergedSubmissionIds":["s1"]}}"#
                .utf8
        )

        guard case .event(let event) = try StreamFrame.decode(from: data) else {
            return XCTFail("expected an event frame")
        }
        XCTAssertEqual(event.kind, .turnFinal)
        XCTAssertEqual(event.identity.submissionId, "s1")
        guard case .turnFinal(let payload) = event.payload else {
            return XCTFail("expected a turn.final payload")
        }
        XCTAssertEqual(payload.mergedSubmissionIds, ["s1"])
    }

    func testAFrameWithAnUnknownKindStillDecodesAsAnEvent() throws {
        let data = Data(
            #"{"protocol":"fleet.conversation.v1","eventId":"e2","kind":"turn.brand_new"}"#.utf8
        )

        guard case .event(let event) = try StreamFrame.decode(from: data) else {
            return XCTFail("an unknown kind is ordinary forward compatibility, not a failure")
        }
        XCTAssertEqual(event.kind, .unknown("turn.brand_new"))
    }

    func testNoCodePathReadsATypeField() throws {
        // A frame carrying `type` and no `kind` must not decode: reading `type` is exactly the
        // mistake the prose documentation invites.
        let onlyType = Data(#"{"protocol":"fleet.conversation.v1","type":"hello"}"#.utf8)
        XCTAssertThrowsError(try StreamFrame.decode(from: onlyType))

        // And when both are present, `kind` is the one that decides.
        let both = Data(
            #"{"protocol":"fleet.conversation.v1","type":"ping","kind":"hello","conversationId":"c1"}"#
                .utf8
        )
        guard case .hello = try StreamFrame.decode(from: both) else {
            return XCTFail("kind must win over type")
        }
    }

    func testTheOnlyClientFrameIsPong() {
        // Anything else cancels the connection server-side, which then closes as `4409` and
        // reads as a supersede that never happened.
        XCTAssertEqual(StreamFrame.pongFrameText, #"{"kind":"pong"}"#)
    }

    func testUndecodableTextIsReportedRatherThanCrashing() {
        XCTAssertThrowsError(try StreamFrame.decode(text: "not json"))
    }
}
