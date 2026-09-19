import XCTest
@testable import Phleet

/// The client's buffer is bounded for the same reason the server's is, and overflows the same
/// way on purpose: it discards and re-reads rather than dropping frames, because a dropped frame
/// is the one failure it could never detect.
final class BoundedLiveBufferTests: XCTestCase {

    private func event(_ seq: Int) -> ConversationEvent {
        TestEvent.started("s1", seq: seq)
    }

    func testHoldsUpToCapacity() {
        var buffer = BoundedLiveBuffer(capacity: 4)
        for seq in 1...4 {
            buffer.append(event(seq))
        }

        XCTAssertEqual(buffer.count, 4)
        XCTAssertEqual(buffer.overflowCount, 0)
        XCTAssertFalse(buffer.needsAdditionalCatchUp)
    }

    func testOverflowDiscardsTheBufferAndOwesACatchUp() {
        var buffer = BoundedLiveBuffer(capacity: 4)
        for seq in 1...5 {
            buffer.append(event(seq))
        }

        XCTAssertEqual(buffer.overflowCount, 1)
        XCTAssertTrue(buffer.needsAdditionalCatchUp)
        // Started again from empty rather than dropping the newest frame. What is kept does not
        // matter — the owed catch-up re-reads all of it.
        XCTAssertEqual(buffer.count, 1)
    }

    func testConsumingTheOverflowClearsTheDebtSoTheProcessTerminates() {
        var buffer = BoundedLiveBuffer(capacity: 2)
        for seq in 1...3 {
            buffer.append(event(seq))
        }

        XCTAssertTrue(buffer.consumeOverflow())
        XCTAssertFalse(
            buffer.consumeOverflow(),
            "one overflow owes exactly one round, not an unbounded series"
        )
    }

    func testDrainEmptiesTheBufferWithoutClearingTheDebt() {
        var buffer = BoundedLiveBuffer(capacity: 2)
        for seq in 1...3 {
            buffer.append(event(seq))
        }

        XCTAssertEqual(buffer.drain().count, 1)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertTrue(
            buffer.needsAdditionalCatchUp,
            "draining is not the same as having recovered what overflowed"
        )
    }

    func testADroppedFrameAlsoOwesACatchUp() {
        var buffer = BoundedLiveBuffer(capacity: 8)
        buffer.markNeedsCatchUp()
        XCTAssertTrue(buffer.consumeOverflow())
    }

    func testCapacityIsNeverBelowOne() {
        // A zero capacity would discard every frame and report nothing, which is exactly the
        // silent loss this type exists to prevent.
        var buffer = BoundedLiveBuffer(capacity: 0)
        buffer.append(event(1))
        XCTAssertEqual(buffer.count, 1)
    }

    func testTheDefaultCapacityIsTheServerReportedBound() {
        XCTAssertEqual(SessionLimits.documentedDefaults.outboundBufferEvents, 256)
    }
}
