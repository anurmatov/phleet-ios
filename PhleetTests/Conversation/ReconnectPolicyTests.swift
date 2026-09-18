import XCTest
@testable import Phleet

/// Backoff, the reset rule, and the disarm.
///
/// Both rules here exist because their obvious simplifications fail quietly: resetting on any
/// successful `hello` turns a connection that dies straight after it into a hot loop, and
/// reconnecting on `4409` produces two instances superseding each other forever, each looking
/// healthy in isolation.
final class ReconnectPolicyTests: XCTestCase {

    func testBackoffDoublesAndCapsAtThirtySeconds() {
        var policy = ReconnectPolicy()
        var intervals: [Double] = []

        for _ in 0..<8 {
            intervals.append(policy.currentInterval)
            // A full-jitter draw of 1 is the interval itself.
            _ = policy.nextDelay(randomFraction: 1)
        }

        XCTAssertEqual(intervals, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testFullJitterDrawsFromZeroToTheInterval() {
        var policy = ReconnectPolicy()
        _ = policy.nextDelay(randomFraction: 1)  // interval is now 2

        var lower = ReconnectPolicy()
        _ = lower.nextDelay(randomFraction: 1)

        XCTAssertEqual(policy.nextDelay(randomFraction: 0), 0)
        XCTAssertEqual(lower.nextDelay(randomFraction: 0.5), 1)
    }

    func testJitterFractionIsClamped() {
        var policy = ReconnectPolicy()
        XCTAssertEqual(policy.nextDelay(randomFraction: 4), 1)

        var other = ReconnectPolicy()
        XCTAssertEqual(other.nextDelay(randomFraction: -3), 0)
    }

    func testAConnectionThatStayedUpSixtySecondsResetsTheBackoff() {
        var policy = ReconnectPolicy()
        for _ in 0..<4 {
            _ = policy.nextDelay(randomFraction: 1)
        }
        XCTAssertEqual(policy.currentInterval, 16)

        policy.recordConnectionEnded(connectedForSeconds: 60)
        XCTAssertEqual(policy.currentInterval, 1)
    }

    func testAConnectionThatFailedAtFiftyNineSecondsDoesNotResetTheBackoff() {
        var policy = ReconnectPolicy()
        for _ in 0..<4 {
            _ = policy.nextDelay(randomFraction: 1)
        }

        policy.recordConnectionEnded(connectedForSeconds: 59)
        XCTAssertEqual(
            policy.currentInterval,
            16,
            "a connection that dies just short of the threshold must not restart the backoff"
        )
    }

    func testADisarmedPolicyYieldsNoDelayAtAll() {
        var policy = ReconnectPolicy()
        policy.disarm()

        for _ in 0..<10 {
            XCTAssertNil(
                policy.nextDelay(randomFraction: 1),
                "a disarmed policy performs zero attempts, not delayed ones"
            )
        }
        XCTAssertTrue(policy.isDisarmed)
    }

    func testAManualResumeRearmsAsAFreshConnection() {
        var policy = ReconnectPolicy()
        for _ in 0..<3 {
            _ = policy.nextDelay(randomFraction: 1)
        }
        policy.disarm()
        policy.resumeManually()

        XCTAssertFalse(policy.isDisarmed)
        XCTAssertEqual(policy.currentInterval, 1)
    }
}
