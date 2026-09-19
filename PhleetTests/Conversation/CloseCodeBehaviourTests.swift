import XCTest
@testable import Phleet

/// Every close code gets a distinct outcome, and there is one assertion per code.
final class CloseCodeBehaviourTests: XCTestCase {

    private func action(
        _ code: Int,
        reason: String? = nil,
        framesAppliedSinceHello: Int = 3
    ) -> CloseAction {
        CloseCode.action(
            for: code,
            reason: reason,
            framesAppliedSinceHello: framesAppliedSinceHello
        )
    }

    func test4401Reauthenticates() {
        // Not a sign-out: only the token mint itself answering 401 proves the credential is dead.
        XCTAssertEqual(action(4401), .reauthenticateAndReconnect)
    }

    func test4403IsTerminal() {
        XCTAssertEqual(action(4403), .terminal)
    }

    func test4408ReconnectsWithBackoff() {
        XCTAssertEqual(action(4408), .reconnectWithBackoff)
    }

    func test4409Disarms() {
        XCTAssertEqual(action(4409), .disarm)
    }

    func test4413MidSessionReconnectsAndCatchesUp() {
        XCTAssertEqual(action(4413, framesAppliedSinceHello: 12), .reconnectAndCatchUp)
    }

    func test4413OnTheFirstFrameAfterHelloReattachesFromAFreshOpen() {
        // The attach floor was wrong, not the client slow. Reconnecting at the same floor
        // reattaches into the same replay and loops forever.
        XCTAssertEqual(action(4413, framesAppliedSinceHello: 0), .reattachFromFreshOpen)
    }

    func test4429WaitsForTheNumberOfSecondsInTheReason() {
        XCTAssertEqual(action(4429, reason: "12"), .reconnectAfter(seconds: 12))
    }

    func test4429WithAnUnreadableReasonWaitsTheCap() {
        for reason in [nil, "", "soon", "-5", "2.5", "7s"] {
            XCTAssertEqual(
                action(4429, reason: reason),
                .reconnectAfter(seconds: 30),
                "an unreadable rate-limit delay must never become zero"
            )
        }
    }

    func test4500ReconnectsWithBackoff() {
        XCTAssertEqual(action(4500), .reconnectWithBackoff)
    }

    func test4503ReconnectsWithBackoff() {
        XCTAssertEqual(action(4503), .reconnectWithBackoff)
    }

    func testAnUnpublishedCodeBacksOffRatherThanGivingUp() {
        XCTAssertEqual(action(4999), .reconnectWithBackoff)
    }

    func testEveryPublishedCodeHasItsOwnCase() {
        XCTAssertEqual(
            Set(StreamCloseCode.allCases.map(\.rawValue)),
            [4401, 4403, 4408, 4409, 4413, 4429, 4500, 4503]
        )
    }

    // MARK: - The delay carrier

    func testRetryAfterParsesANonNegativeIntegerOfSeconds() {
        XCTAssertEqual(RetryAfterParser.seconds(from: "0"), 0)
        XCTAssertEqual(RetryAfterParser.seconds(from: "12"), 12)
        // Surrounding whitespace is optional whitespace around an HTTP header value, so it is
        // trimmed rather than treated as a malformed delay. Anything else in the string is not.
        XCTAssertEqual(RetryAfterParser.seconds(from: " 12 "), 12)
    }

    func testRetryAfterFallsBackToTheCapRatherThanZero() {
        for value in [nil, "", "   ", "-1", "1.5", "Fri, 01 Jan 2027 00:00:00 GMT", "12s"] {
            XCTAssertEqual(RetryAfterParser.seconds(from: value), 30)
        }
    }

    func testTheFallbackIsTheBackoffCap() {
        XCTAssertEqual(
            Double(RetryAfterParser.defaultSeconds),
            ReconnectPolicy.maximumSeconds
        )
    }
}
