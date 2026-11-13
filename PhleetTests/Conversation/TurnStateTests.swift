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

    func testALocalSubmissionKeepsItsTextAndAReplayedOneWithoutATextEventHasNone() {
        var state = TurnStateMachine()
        state.registerLocalSubmission(id: "s1", text: "hello")
        state.apply(TestEvent.started("s2", seq: 1))

        XCTAssertEqual(state.record("s1")?.text, "hello")
        XCTAssertNil(
            state.record("s2")?.text,
            "no submission.text was read for it, so its words are unavailable, not empty"
        )
    }

    // MARK: - Restored text

    func testRestoredTextLandsOnTheDurableRowWithoutInventingATurn() {
        let state = machine([TestEvent.text("durable-1", seq: 1, text: "hello")])

        XCTAssertEqual(state.orderedRecords.map(\.id), ["durable-1"])
        XCTAssertEqual(state.record("durable-1")?.text, "hello")
        // Durably accepted and nothing more: no disposition, progress, terminal or reply.
        XCTAssertEqual(state.record("durable-1")?.state, .sending)
        XCTAssertNil(state.record("durable-1")?.reply)
        XCTAssertNil(state.activity)
        XCTAssertTrue(state.pendingAnnouncements.isEmpty)
    }

    func testTextArrivingAfterATerminalChangesNothingTheTerminalDecided() {
        var state = machine([
            TestEvent.started("durable-1", seq: 2),
            TestEvent.final("durable-1", seq: 3, text: "Answer.", merged: ["durable-1"])
        ])
        let decided = state.record("durable-1")?.state
        let announced = state.pendingAnnouncements.count

        state.apply(TestEvent.text("durable-1", seq: 1, text: "the question"))

        XCTAssertEqual(state.record("durable-1")?.text, "the question")
        XCTAssertEqual(state.record("durable-1")?.state, decided)
        XCTAssertEqual(state.record("durable-1")?.reply?.text, "Answer.")
        XCTAssertEqual(state.pendingAnnouncements.count, announced, "no second announcement")
        XCTAssertEqual(state.orderedRecords.count, 1)
    }

    func testValidEmptyTextIsDistinctFromMissingText() {
        let state = machine([
            TestEvent.text("durable-1", seq: 1, text: ""),
            TestEvent.final("durable-2", seq: 2, merged: ["durable-2"])
        ])

        XCTAssertEqual(state.record("durable-1")?.text, "", "sent with no text")
        XCTAssertNil(state.record("durable-2")?.text, "text unavailable")
    }

    func testTheExactTextIsKeptWithoutTrimmingOrInterpretation() {
        let typed = "  leading\n\ttabbed — ünïcødé 🧭 **not bold** "
            + "[not a link](https://example.invalid)  "
        let state = machine([TestEvent.text("durable-1", seq: 1, text: typed)])

        XCTAssertEqual(state.record("durable-1")?.text, typed)
        XCTAssertEqual(TranscriptCopy.copyable(state.record("durable-1")?.text), typed)
    }

    func testMalformedSubmissionTextIsIgnoredAndCountedAndErasesNothing() {
        let state = machine([
            TestEvent.text("durable-1", seq: 1, text: "known"),
            TestEvent.text("durable-1", seq: 2, text: nil, eventId: "missing-text"),
            TestEvent.text(nil, seq: 3, text: "names no submission", eventId: "no-identity"),
            TestEvent.text("", seq: 4, text: "names an empty one", eventId: "empty-identity"),
            TestEvent.text("durable-2", seq: 5, text: nil, eventId: "missing-text-new-id"),
            TestEvent.final("durable-1", seq: 6, merged: ["durable-1"])
        ])

        XCTAssertEqual(state.record("durable-1")?.text, "known", "known text is never erased")
        XCTAssertNil(state.record("durable-2"), "no empty message is fabricated")
        XCTAssertNil(state.record(""))
        XCTAssertEqual(state.orderedRecords.map(\.id), ["durable-1"])
        XCTAssertEqual(state.ignoredEventKinds, Array(repeating: "submission.text", count: 4))
        XCTAssertNotNil(state.record("durable-1")?.reply, "the rest of the transcript still applies")
    }

    func testTheRestoredFixtureReplaysEveryHumanTextInServerOrder() throws {
        let state = machine(try ProtocolFixture.events("restored-human-text"))

        XCTAssertEqual(
            state.orderedRecords.map(\.id),
            ["durable-legacy", "durable-1", "durable-2", "durable-3", "durable-4", "durable-6"]
        )
        XCTAssertEqual(
            state.orderedRecords.map(\.text),
            [
                nil,
                "  leading and trailing spaces  ",
                "Line one\nLine two — ünïcødé 🧭",
                "**not bold** `not code` [not a link](https://example.invalid)",
                "",
                "Was this run?"
            ]
        )
        // The gap separator stays first, and the pruned message keeps its reply.
        XCTAssertEqual(state.entries.first?.id, "system:restored-gap")
        XCTAssertEqual(state.record("durable-legacy")?.reply?.text,
                       "A reply to a message from before the retained floor.")
        // One group, one reply, both members marked.
        XCTAssertEqual(state.orderedRecords.compactMap(\.reply).count, 3)
        XCTAssertNil(state.record("durable-2")?.reply)
        XCTAssertEqual(state.record("durable-3")?.reply?.text, "One answer for both.")
        XCTAssertTrue(state.record("durable-2")?.isAnsweredTogether == true)
        XCTAssertTrue(state.record("durable-3")?.isAnsweredTogether == true)
        XCTAssertEqual(state.record("durable-4")?.state, .notRun(.queueFull))
        XCTAssertEqual(state.record("durable-6")?.state, .outcomeUnknown(.attemptAbandoned))
        XCTAssertTrue(state.unresolvedSubmissionIds.isEmpty)
        XCTAssertEqual(state.ignoredEventKinds, Array(repeating: "submission.text", count: 4))
    }

    // MARK: - Receipts

    /// The server keeps a submission under an id of its own; the receipt answers with the one this
    /// device chose. Only `acceptedSeq` joins them.
    private func sentAndAccepted(at acceptedSeq: Int) -> [ConversationEvent] {
        [
            TestEvent.text("durable-1", seq: acceptedSeq, text: "hello"),
            TestEvent.accepted("durable-1", .ran, seq: acceptedSeq + 1),
            TestEvent.started("durable-1", seq: acceptedSeq + 2),
            TestEvent.final("durable-1", seq: acceptedSeq + 3, text: "Hi.", merged: ["durable-1"])
        ]
    }

    func testAReceiptBeforeItsTextLeavesOneRowUnderTheDurableId() {
        var state = TurnStateMachine()
        state.registerLocalSubmission(id: "local-1", text: "hello")
        state.reconcileReceipt(localSubmissionId: "local-1", acceptedSeq: 41)
        XCTAssertEqual(state.orderedRecords.map(\.id), ["local-1"], "the echo stands until its row")

        for event in sentAndAccepted(at: 41) {
            state.apply(event)
        }

        XCTAssertEqual(state.entries, [.submission("durable-1")])
        XCTAssertEqual(state.record("durable-1")?.text, "hello")
        XCTAssertEqual(state.record("durable-1")?.reply?.text, "Hi.")
        XCTAssertNil(state.record("local-1"))
        XCTAssertEqual(state.localSubmissionId(for: "durable-1"), "local-1")
    }

    func testATextBeforeItsReceiptLeavesOneRowOnceTheReceiptArrives() {
        var state = TurnStateMachine()
        state.registerLocalSubmission(id: "local-1", text: "hello")
        for event in sentAndAccepted(at: 41) {
            state.apply(event)
        }
        XCTAssertEqual(
            state.orderedRecords.map(\.id),
            ["local-1", "durable-1"],
            "nothing joins them before the receipt: not the text, not the timing"
        )

        state.reconcileReceipt(localSubmissionId: "local-1", acceptedSeq: 41)

        XCTAssertEqual(state.entries, [.submission("durable-1")])
        XCTAssertEqual(state.record("durable-1")?.reply?.text, "Hi.")
        XCTAssertEqual(state.localSubmissionId(for: "durable-1"), "local-1")
    }

    func testTwoSubmissionsWithIdenticalTextStayTwoRows() {
        var state = TurnStateMachine()
        state.registerLocalSubmission(id: "local-1", text: "same words")
        state.registerLocalSubmission(id: "local-2", text: "same words")
        state.reconcileReceipt(localSubmissionId: "local-2", acceptedSeq: 43)
        state.apply(TestEvent.text("durable-1", seq: 41, text: "same words"))
        state.apply(TestEvent.text("durable-2", seq: 43, text: "same words"))
        state.reconcileReceipt(localSubmissionId: "local-1", acceptedSeq: 41)

        XCTAssertEqual(state.orderedRecords.map(\.id), ["durable-1", "durable-2"])
        XCTAssertEqual(state.localSubmissionId(for: "durable-1"), "local-1")
        XCTAssertEqual(state.localSubmissionId(for: "durable-2"), "local-2")
    }

    func testTextAtASeqNoReceiptNamedNeverRetiresAnEcho() {
        var state = TurnStateMachine()
        state.registerLocalSubmission(id: "local-1", text: "same words")
        state.reconcileReceipt(localSubmissionId: "local-1", acceptedSeq: 41)
        // Another device's message with the same words, at another seq.
        state.apply(TestEvent.text("durable-other", seq: 40, text: "same words"))

        XCTAssertEqual(state.orderedRecords.map(\.id), ["local-1", "durable-other"])
        XCTAssertEqual(state.localSubmissionId(for: "durable-other"), "durable-other")
    }

    func testAnAcceptedWithoutSeqRetiresTheEchoAndInventsNoLink() {
        // `202`: the same key landed again while the first accept was still being decided.
        var state = TurnStateMachine()
        state.registerLocalSubmission(id: "local-1", text: "hello")
        state.apply(TestEvent.text("durable-1", seq: 41, text: "hello"))

        state.reconcileReceipt(localSubmissionId: "local-1", acceptedSeq: nil)

        XCTAssertEqual(state.orderedRecords.map(\.id), ["durable-1"])
        XCTAssertEqual(state.localSubmissionId(for: "durable-1"), "durable-1", "no seq was invented")
    }

    func testAServerThatKeepsTheDevicesOwnIdLeavesTheRowInPlace() {
        // A server whose events name the id this device chose: the echo *is* the durable row.
        var state = TurnStateMachine()
        state.registerLocalSubmission(id: "s1", text: "hello")
        state.reconcileReceipt(localSubmissionId: "s1", acceptedSeq: 41)
        state.apply(TestEvent.text("s1", seq: 41, text: "hello"))
        state.apply(TestEvent.final("s1", seq: 42, merged: ["s1"]))
        state.reconcileReceipt(localSubmissionId: "s1", acceptedSeq: nil)

        XCTAssertEqual(state.entries, [.submission("s1")])
        XCTAssertNotNil(state.record("s1")?.reply)
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
