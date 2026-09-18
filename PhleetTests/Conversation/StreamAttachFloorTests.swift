import XCTest
@testable import Phleet

/// The three cursor values, and the one that closes a conversation deterministically when it is
/// wrong.
///
/// `afterSeq` means the same thing on both calls — "I have processed up to and including this
/// seq" — and is computed from different sources on purpose. The stream's is always derived from
/// the open response; the catch-up call's comes from local cursor state.
final class StreamAttachFloorTests: XCTestCase {

    // MARK: - The live-tail floor

    func testTheFloorIsOneBelowNextSeq() {
        XCTAssertEqual(StreamAttachFloor.liveTailFloor(nextSeq: 900), 899)
        XCTAssertEqual(StreamAttachFloor.liveTailFloor(nextSeq: 41), 40)
    }

    func testAFreshConversationProducesZeroWithoutUnderflow() {
        // A brand-new thread may report `nextSeq: 0` or `1`. Unguarded, this underflows or comes
        // back `400 invalid_cursor` on exactly the thread that has to load first.
        XCTAssertEqual(StreamAttachFloor.liveTailFloor(nextSeq: 0), 0)
        XCTAssertEqual(StreamAttachFloor.liveTailFloor(nextSeq: 1), 0)
    }

    // MARK: - The catch-up cursors

    func testTheColdStartCursorIsZero() {
        XCTAssertEqual(CatchUpCursor.coldStart, 0)
    }

    func testTheRecoveryFloorIsOneBelowTheRetainedFloor() {
        XCTAssertEqual(CatchUpCursor.recoveryFloor(retainedFloorSeq: 20), 19)
    }

    func testTheRecoveryFloorGuardsAgainstUnderflow() {
        // A fresh conversation reports `retainedFloorSeq: 0`. Without the guard the recovery
        // attempt answers with a second `invalid_cursor` — which is why reusing the recovery
        // formula at cold start is actively wrong rather than merely redundant.
        XCTAssertEqual(CatchUpCursor.recoveryFloor(retainedFloorSeq: 0), 0)
        XCTAssertEqual(CatchUpCursor.recoveryFloor(retainedFloorSeq: 1), 0)
    }

    func testColdStartAndRecoveryAreDifferentValuesWhereverTheFloorIsAboveOne() {
        for retainedFloorSeq in [2, 12, 20, 900] {
            XCTAssertNotEqual(
                CatchUpCursor.coldStart,
                CatchUpCursor.recoveryFloor(retainedFloorSeq: retainedFloorSeq),
                "the two must not collapse into each other"
            )
        }
    }

    func testASubmissionLifecycleIsReadFromOneBelowItsAcceptedSeq() {
        // `afterSeq` is inclusive of the seq it names, so the accepted event itself is only
        // returned when the request starts one below it.
        XCTAssertEqual(CatchUpCursor.beforeAcceptedSeq(41), 40)
        XCTAssertEqual(CatchUpCursor.beforeAcceptedSeq(1), 0)
        XCTAssertEqual(CatchUpCursor.beforeAcceptedSeq(0), 0)
    }

    // MARK: - The regression the floor exists to prevent

    func testTheStreamFloorAndTheCatchUpCursorAreDifferentValuesInOneAttach() {
        // The exact shape of the failure: a conversation at seq 900 with a client that has
        // processed 10. Handing the stream the catch-up cursor replays 890 events into a
        // 256-slot non-blocking server buffer and closes 4413 before the client reads one
        // useful frame.
        let openNextSeq = 900
        let lastApplied = 10

        XCTAssertEqual(StreamAttachFloor.liveTailFloor(nextSeq: openNextSeq), 899)
        XCTAssertNotEqual(StreamAttachFloor.liveTailFloor(nextSeq: openNextSeq), lastApplied)
    }
}
