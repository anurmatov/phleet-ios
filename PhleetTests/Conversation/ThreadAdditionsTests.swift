import XCTest
@testable import Phleet

/// What the thread gained after the first version: what the agent says while it works, when
/// things were said, which tools a turn has started, what a message answers, and files that are
/// not pictures. All of it as values fed with events, with no screen involved.
@MainActor
final class ThreadAdditionsTests: XCTestCase {

    private func machine(_ events: [ConversationEvent]) -> TurnStateMachine {
        var machine = TurnStateMachine()
        for event in events {
            machine.apply(event)
        }
        return machine
    }

    private func at(_ event: ConversationEvent, _ instant: String) -> ConversationEvent {
        ConversationEvent(
            eventId: event.eventId,
            seq: event.seq,
            kind: event.kind,
            identity: event.identity,
            payload: event.payload,
            emittedAt: instant
        )
    }

    private func said(
        _ submissionId: String?,
        seq: Int,
        text: String,
        truncated: Bool? = nil
    ) -> ConversationEvent {
        ConversationEvent(
            eventId: "message-\(seq)",
            seq: seq,
            kind: .turnMessage,
            identity: TestEvent.identity(submissionId: submissionId),
            payload: .turnMessage(TurnMessagePayload(text: text, truncated: truncated))
        )
    }

    private func replying(
        _ submissionId: String,
        seq: Int,
        text: String,
        to target: String
    ) -> ConversationEvent {
        ConversationEvent(
            eventId: "text-\(submissionId)-\(seq)",
            seq: seq,
            kind: .submissionText,
            identity: TestEvent.identity(submissionId: submissionId),
            payload: .submissionText(SubmissionTextPayload(text: text, replyToEventId: target))
        )
    }

    // MARK: - What the agent says while it works

    func testWhatTheAgentSaysMidTurnGoesOnTheRowItIsAnsweringAndIsNotTheAnswer() {
        let state = machine([
            TestEvent.text("durable-1", seq: 1, text: "fix it"),
            TestEvent.started("durable-1", seq: 2),
            said("durable-1", seq: 3, text: "Reading the file first."),
            // Names no submission: it belongs to the turn that is running.
            said(nil, seq: 4, text: "Now the tests.", truncated: true)
        ])

        let record = state.record("durable-1")
        XCTAssertEqual(record?.interim.map(\.text), ["Reading the file first.", "Now the tests."])
        XCTAssertEqual(record?.interim.map(\.truncated), [false, true])
        // Not a terminal: the turn is still running and there is no reply yet.
        XCTAssertEqual(record?.state, .working)
        XCTAssertNil(record?.reply)
        XCTAssertTrue(state.hasRunningTurn)
        XCTAssertTrue(state.pendingAnnouncements.isEmpty)
    }

    func testTheAnswerStillArrivesOnceAndTheMidTurnMessagesStay() {
        let state = machine([
            TestEvent.text("durable-1", seq: 1, text: "fix it"),
            TestEvent.started("durable-1", seq: 2),
            said("durable-1", seq: 3, text: "Reading the file first."),
            TestEvent.final("durable-1", seq: 4, text: "Fixed.")
        ])

        let record = state.record("durable-1")
        XCTAssertEqual(record?.reply?.text, "Fixed.")
        XCTAssertEqual(record?.interim.map(\.text), ["Reading the file first."])
    }

    func testAnEmptyMidTurnMessageOrOneForATurnNeverSeenIsCountedAndShowsNothing() {
        let state = machine([
            TestEvent.text("durable-1", seq: 1, text: "fix it"),
            TestEvent.started("durable-1", seq: 2),
            said("durable-1", seq: 3, text: "  \n "),
            said("never-seen", seq: 4, text: "from a turn this phone knows nothing of")
        ])

        XCTAssertEqual(state.record("durable-1")?.interim, [])
        XCTAssertNil(state.record("never-seen"))
        XCTAssertEqual(state.ignoredEventKinds, ["turn.message", "turn.message"])
    }

    func testAMidTurnMessageDecodesFromTheWire() throws {
        let events = try ProtocolFixture.events("all-kinds")
        let event = try XCTUnwrap(events.first { $0.kind == .turnMessage })

        guard case .turnMessage(let payload) = event.payload else {
            return XCTFail("turn.message decoded to \(event.payload)")
        }
        XCTAssertEqual(payload.text, "Reading the file first.")
        XCTAssertEqual(payload.truncated, true)
        XCTAssertEqual(EventKind(rawValue: "turn.message"), .turnMessage)
        XCTAssertFalse(EventKind.turnMessage.isTerminal)
    }

    // MARK: - When things were said

    func testMessagesCarryTheTimeTheirEventsSaid() {
        let state = machine([
            at(TestEvent.text("durable-1", seq: 1, text: "hello"), "2026-11-14T09:30:00Z"),
            at(TestEvent.started("durable-1", seq: 2), "2026-11-14T09:30:01.250Z"),
            at(said("durable-1", seq: 3, text: "Looking."), "2026-11-14T09:30:05+00:00"),
            at(TestEvent.final("durable-1", seq: 4), "2026-11-14T09:31:00Z")
        ])

        let record = state.record("durable-1")
        XCTAssertEqual(record?.sentAt, ConversationEvent.parse(instant: "2026-11-14T09:30:00Z"))
        XCTAssertEqual(record?.interim.first?.at, ConversationEvent.parse(instant: "2026-11-14T09:30:05Z"))
        XCTAssertEqual(record?.reply?.at, ConversationEvent.parse(instant: "2026-11-14T09:31:00Z"))
    }

    func testAnInstantIsReadWithOrWithoutAFractionAndRefusedOtherwise() {
        let whole = ConversationEvent.parse(instant: "2026-11-14T09:30:00Z")
        XCTAssertNotNil(whole)
        XCTAssertEqual(
            ConversationEvent.parse(instant: "2026-11-14T09:30:00.500Z")?.timeIntervalSince(whole ?? .distantPast),
            0.5
        )
        XCTAssertEqual(ConversationEvent.parse(instant: "2026-11-14T14:30:00+05:00"), whole)
        XCTAssertNil(ConversationEvent.parse(instant: "yesterday"))
        XCTAssertNil(ConversationEvent.parse(instant: ""))
        // An event that says nothing about time has none: nothing is invented for it.
        XCTAssertNil(TestEvent.text("durable-1", seq: 1, text: "hello").emittedDate)
    }

    // MARK: - The running turn

    func testARunningTurnRemembersWhenItStartedAndTheToolsItStartedAndItsEndForgetsBoth() {
        var state = machine([
            TestEvent.text("durable-1", seq: 1, text: "go"),
            at(TestEvent.started("durable-1", seq: 2), "2026-11-14T09:30:00Z"),
            TestEvent.progress("durable-1", seq: 3, activity: .tool, toolName: "Read"),
            TestEvent.progress("durable-1", seq: 4, activity: .tool, toolName: "Read"),
            TestEvent.progress("durable-1", seq: 5, activity: .typing),
            TestEvent.progress("durable-1", seq: 6, activity: .tool, toolName: "Bash")
        ])

        XCTAssertEqual(state.turnStartedAt, ConversationEvent.parse(instant: "2026-11-14T09:30:00Z"))
        XCTAssertEqual(state.trail, ["Read", "Read", "Bash"])

        state.apply(TestEvent.final("durable-1", seq: 7))
        XCTAssertNil(state.turnStartedAt)
        XCTAssertEqual(state.trail, [])

        // A new turn starts its own trail.
        state.apply(TestEvent.text("durable-2", seq: 8, text: "again"))
        state.apply(TestEvent.started("durable-2", seq: 9))
        XCTAssertEqual(state.trail, [])
    }

    func testAVeryLongTurnKeepsItsLatestTools() {
        var events = [TestEvent.text("durable-1", seq: 1, text: "go"), TestEvent.started("durable-1", seq: 2)]
        for index in 0..<200 {
            events.append(TestEvent.progress("durable-1", seq: index + 3, activity: .tool, toolName: "T\(index)"))
        }
        let state = machine(events)

        XCTAssertEqual(state.trail.count, TurnStateMachine.maxTrail)
        XCTAssertEqual(state.trail.last, "T199")
    }

    func testRunsOfOneToolAreFolded() {
        let folded = TurnStateMachine.folded(["Read", "Read", "Read", "Bash", "Read"])

        XCTAssertEqual(folded.map(\.tool), ["Read", "Bash", "Read"])
        XCTAssertEqual(folded.map(\.count), [3, 1, 1])
        XCTAssertTrue(TurnStateMachine.folded([]).isEmpty)
    }

    // MARK: - What a message answers

    func testAReplyIsShownWithWhoWroteWhatItAnswersAndHowItStarts() {
        let state = machine([
            TestEvent.text("durable-1", seq: 1, text: "is it broken?", eventId: "event-question"),
            TestEvent.started("durable-1", seq: 2),
            said("durable-1", seq: 3, text: "Looking at   the\nlogs."),
            TestEvent.final("durable-1", seq: 4, text: "Yes. Want a PR?", eventId: "event-answer"),
            replying("durable-2", seq: 5, text: "yes please", to: "event-answer"),
            replying("durable-3", seq: 6, text: "to myself", to: "event-question"),
            replying("durable-4", seq: 7, text: "to what it said on the way", to: "message-3"),
            replying("durable-5", seq: 8, text: "to something gone", to: "event-expired")
        ])

        func quote(_ id: String) -> QuotedMessage? {
            state.record(id).flatMap { state.quoted(for: $0) }
        }

        XCTAssertNil(quote("durable-1"))
        XCTAssertEqual(
            quote("durable-2"),
            QuotedMessage(eventId: "event-answer", author: .agent, text: "Yes. Want a PR?")
        )
        XCTAssertEqual(
            quote("durable-3"),
            QuotedMessage(eventId: "event-question", author: .you, text: "is it broken?")
        )
        // One line, however the original was laid out.
        XCTAssertEqual(
            quote("durable-4"),
            QuotedMessage(eventId: "message-3", author: .agent, text: "Looking at the logs.")
        )
        // No longer among the messages this phone holds: still a reply, with nothing to quote.
        XCTAssertEqual(
            quote("durable-5"),
            QuotedMessage(eventId: "event-expired", author: .agent, text: "")
        )
    }

    func testAQuotationIsOneLineAndCutShort() {
        XCTAssertEqual(QuotedMessage.excerpt("  spaced \n\n out  "), "spaced out")
        let long = QuotedMessage.excerpt(String(repeating: "x", count: 400))
        XCTAssertEqual(long.count, QuotedMessage.maxLength + 1)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testTheMessageAReplyNamesIsTheEventThatCarriedTheWords() {
        let state = machine([TestEvent.text("durable-1", seq: 1, text: "hello", eventId: "event-1")])

        XCTAssertEqual(state.record("durable-1")?.textEventId, "event-1")
        XCTAssertEqual(state.message(eventId: "event-1")?.author, .you)
        XCTAssertNil(state.message(eventId: "event-2"))
    }
}
