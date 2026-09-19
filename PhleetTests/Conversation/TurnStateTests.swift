import XCTest
@testable import Phleet

/// Each submission's state is a function of *which* kinds have arrived, never of the order they
/// arrived in. Every test here is a case where the order-dependent reading gives the wrong
/// answer.
final class TurnStateTests: XCTestCase {

    private func machine(_ events: [ConversationEvent]) -> TurnStateMachine {
        var machine = TurnStateMachine()
        for event in events {
            machine.apply(event)
        }
        return machine
    }

    // MARK: - Ordering

    func testTurnStartedBeforeAcceptedRendersARunningTurn() {
        // On the `ran` path it arrives first and takes the lower seq. A client that waits for
        // `accepted` before rendering a running turn hangs on the ordinary path.
        let state = machine([TestEvent.started("s1", seq: 1)])
        XCTAssertEqual(state.record("s1")?.state, .working)
        XCTAssertTrue(state.record("s1")?.state.ownsProgressIndicator == true)
    }

    func testAcceptedArrivingAfterATerminalDoesNotReopenTheTurn() {
        let state = machine([
            TestEvent.started("s1", seq: 1),
            TestEvent.final("s1", seq: 2, merged: ["s1"]),
            TestEvent.accepted("s1", .ran, seq: 3)
        ])

        guard case .completed = state.record("s1")?.state else {
            return XCTFail("a late accepted must not reopen a resolved turn")
        }
    }

    func testTheFirstTerminalWinsAndLaterOnesAreIgnored() {
        let state = machine([
            TestEvent.started("s1", seq: 1),
            TestEvent.final("s1", seq: 2, text: "first", merged: ["s1"]),
            TestEvent.final("s1", seq: 3, text: "second", merged: ["s1"])
        ])

        XCTAssertEqual(state.record("s1")?.reply?.text, "first")
        XCTAssertEqual(
            state.orderedRecords.compactMap(\.reply).count,
            1,
            "a second terminal must not produce a second reply"
        )
    }

    func testDedupeIsOnEventIdNotSeq() {
        var state = TurnStateMachine()
        let event = TestEvent.started("s1", seq: 1)

        XCTAssertTrue(state.apply(event))
        XCTAssertFalse(state.apply(event), "the same eventId must be applied once")
    }

    // MARK: - Dispositions

    func testQueuedRendersWaitingAndNotTyping() {
        // The agent is busy with something else entirely; one provider process serves every
        // channel. Rendering "typing" would assert it is working on *this* message.
        let state = machine([TestEvent.accepted("s1", .queued, seq: 1)])
        XCTAssertEqual(state.record("s1")?.state, .waiting)
        XCTAssertFalse(state.record("s1")?.state.ownsProgressIndicator == true)
    }

    func testQueueFullAndDroppedAreTerminalRatherThanSendFailures() {
        for disposition in [Disposition.queueFull, .dropped] {
            let state = machine([TestEvent.accepted("s1", disposition, seq: 1)])

            XCTAssertEqual(state.record("s1")?.state, .notRun(disposition))
            XCTAssertTrue(state.record("s1")?.state.isTerminal == true)
            XCTAssertNil(
                state.record("s1")?.reply,
                "a submission that never ran has no answer to show"
            )
        }
    }

    func testAnUnrecognisedDispositionLeavesTheStateAloneAndStillTerminates() {
        let state = machine([
            TestEvent.accepted("s1", Disposition(rawValue: "a_new_disposition"), seq: 1),
            TestEvent.final("s1", seq: 2, merged: ["s1"])
        ])
        XCTAssertTrue(state.record("s1")?.state.isTerminal == true)
    }

    // MARK: - Progress

    func testProgressIsOneIndicatorWithNoPerToolRows() {
        let state = machine([
            TestEvent.started("s1", seq: 1),
            TestEvent.progress("s1", seq: 2, activity: .tool, toolName: "search"),
            TestEvent.progress("s1", seq: 3, activity: .tool, toolName: "read")
        ])

        // One activity, replaced not accumulated: nothing reports a tool *finishing* on any
        // provider, so a list would render rows that can never be ticked off.
        XCTAssertEqual(state.activity?.toolName, "read")
        XCTAssertEqual(state.activity?.activity, .tool)
    }

    func testATerminalClearsTheActivity() {
        let state = machine([
            TestEvent.started("s1", seq: 1),
            TestEvent.progress("s1", seq: 2),
            TestEvent.final("s1", seq: 3, merged: ["s1"])
        ])
        XCTAssertNil(state.activity)
    }

    // MARK: - Terminals

    func testOutcomeUnknownIsItsOwnState() {
        for reason in [
            OutcomeUnknownReason.turnReaped,
            .terminalEventOversize,
            .attemptAbandoned,
            .unrecognized("something_new")
        ] {
            let state = machine([
                TestEvent.started("s1", seq: 1),
                TestEvent.outcomeUnknown("s1", seq: 2, reason: reason)
            ])

            XCTAssertEqual(state.record("s1")?.state, .outcomeUnknown(reason))
            XCTAssertTrue(state.record("s1")?.state.isTerminal == true)
            XCTAssertFalse(
                state.record("s1")?.state.ownsProgressIndicator == true,
                "never an unresolved spinner"
            )
            XCTAssertNil(state.record("s1")?.reply, "never the success treatment")
        }
    }

    func testACancelThisClientDidNotInitiateIsATerminalWithoutAnError() {
        let state = machine([
            TestEvent.started("s1", seq: 1),
            TestEvent.canceled("s1", seq: 2, reason: .unknown, merged: ["s1"])
        ])

        guard case .canceled(let payload) = state.record("s1")?.state else {
            return XCTFail("expected a canceled state")
        }
        XCTAssertFalse(payload.reason.wasInitiatedHere)
        XCTAssertEqual(state.record("s1")?.state.isTerminal, true)
    }

    func testControlAckWithNoRunningTaskSynthesisesNoTerminal() {
        let state = machine([
            TestEvent.accepted("s1", .queued, seq: 1),
            TestEvent.controlAck("s1", seq: 2, hadRunningTask: false)
        ])

        XCTAssertEqual(state.lastControlAck?.hadRunningTask, false)
        XCTAssertEqual(
            state.record("s1")?.state,
            .waiting,
            "the ack is the whole story; nothing follows it"
        )
    }

    // MARK: - Unknown kinds

    func testAnUnrecognisedKindIsIgnoredAndCounted() {
        let state = machine([
            TestEvent.started("s1", seq: 1),
            TestEvent.unknownKind(seq: 2),
            TestEvent.unknownKind(seq: 3, raw: "conversation.something_else")
        ])

        XCTAssertEqual(state.ignoredEventCount, 2)
        XCTAssertEqual(state.record("s1")?.state, .working, "rendering is otherwise unaffected")
    }

    // MARK: - Transcript

    func testALocalSubmissionKeepsItsTextAndAReplayedOneHasNone() {
        var state = TurnStateMachine()
        state.registerLocalSubmission(id: "s1", text: "hello")
        state.apply(TestEvent.started("s2", seq: 1))

        XCTAssertEqual(state.record("s1")?.text, "hello")
        XCTAssertNil(
            state.record("s2")?.text,
            "catch-up carries the agent's side of a turn, not the words that started it"
        )
    }

    func testAHistoryGapIsRenderedOnceAndNeverDropped() {
        var state = TurnStateMachine()
        state.appendHistoryGap(id: "gap-1")
        state.appendHistoryGap(id: "gap-1")

        let gaps = state.entries.filter {
            if case .systemLine(let line) = $0 { return line.kind == .replayGap }
            return false
        }
        XCTAssertEqual(gaps.count, 1)
    }

    func testEveryTerminalPostsAnAnnouncement() {
        var state = TurnStateMachine()
        state.apply(TestEvent.started("s1", seq: 1))
        state.apply(TestEvent.outcomeUnknown("s1", seq: 2))

        let announcements = state.consumeAnnouncements()
        XCTAssertEqual(announcements.count, 1)
        XCTAssertEqual(announcements.first?.kind, .turnOutcomeUnknown)
        XCTAssertTrue(state.consumeAnnouncements().isEmpty)
    }
}
