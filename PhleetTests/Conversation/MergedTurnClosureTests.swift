import XCTest
@testable import Phleet

/// The rule that stops an injected message spinning forever.
///
/// A submission dispositioned `injected`, or coalesced with others at turn start, **never**
/// receives a terminal whose `identity.submissionId` is its own. Correlating strictly by
/// `submissionId` leaves it working with no path to a terminal, and nothing on screen says so.
final class MergedTurnClosureTests: XCTestCase {

    private func machine(_ events: [ConversationEvent]) -> TurnStateMachine {
        var machine = TurnStateMachine()
        for event in events {
            machine.apply(event)
        }
        return machine
    }

    // MARK: - Injected submissions

    func testAnInjectedSubmissionOwnsNoProgressIndicator() {
        let state = machine([
            TestEvent.accepted("s1", .ran, seq: 1),
            TestEvent.started("s1", seq: 2),
            TestEvent.accepted("s2", .injected, seq: 3)
        ])

        XCTAssertEqual(state.record("s2")?.state, .attached(hostSubmissionId: "s1"))
        XCTAssertFalse(
            state.record("s2")?.state.ownsProgressIndicator == true,
            "there is no separate turn for it to indicate"
        )
        XCTAssertTrue(state.record("s1")?.state.ownsProgressIndicator == true)
    }

    // MARK: - mergedSubmissionIds

    func testATerminalClosesEveryIdItLists() {
        var state = TurnStateMachine()
        state.registerLocalSubmission(id: "s1", text: "first")
        state.registerLocalSubmission(id: "s2", text: "second")
        state.apply(TestEvent.accepted("s1", .ran, seq: 1))
        state.apply(TestEvent.started("s1", seq: 2))
        state.apply(TestEvent.accepted("s2", .injected, seq: 3))
        state.apply(TestEvent.final("s1", seq: 4, text: "One answer.", merged: ["s1", "s2"]))

        XCTAssertTrue(state.record("s1")?.state.isTerminal == true)
        XCTAssertTrue(state.record("s2")?.state.isTerminal == true)

        // One turn produced one answer, and the interface says so.
        let replies = state.orderedRecords.compactMap(\.reply)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.text, "One answer.")

        // The reply attaches to the last of the group in send order; every member carries the
        // marker, because every member was answered together.
        XCTAssertEqual(state.record("s2")?.reply?.text, "One answer.")
        XCTAssertNil(state.record("s1")?.reply)
        XCTAssertTrue(state.record("s1")?.isAnsweredTogether == true)
        XCTAssertTrue(state.record("s2")?.isAnsweredTogether == true)
    }

    func testASoleSubmissionIsNotMarkedAsAnsweredTogether() {
        var state = TurnStateMachine()
        state.registerLocalSubmission(id: "s1", text: "only")
        state.apply(TestEvent.started("s1", seq: 1))
        state.apply(TestEvent.final("s1", seq: 2, merged: ["s1"]))

        XCTAssertFalse(state.record("s1")?.isAnsweredTogether == true)
        XCTAssertNotNil(state.record("s1")?.reply)
    }

    func testAMergedIdTheClientHasNeverSeenIsIgnored() {
        var state = TurnStateMachine()
        state.registerLocalSubmission(id: "s1", text: "mine")
        state.apply(TestEvent.started("s1", seq: 1))
        state.apply(TestEvent.final("s1", seq: 2, merged: ["s1", "from-another-device"]))

        XCTAssertNil(
            state.record("from-another-device"),
            "no placeholder message is synthesised for a submission nobody here sent"
        )
        XCTAssertEqual(state.orderedRecords.count, 1)
        XCTAssertEqual(state.ignoredMergedIds, ["from-another-device"])
    }

    // MARK: - Terminals that carry no merged list

    func testATurnErrorClosesEverySubmissionAttachedToItsTurn() {
        // `turn.error` and `turn.outcome_unknown` carry `{ code, message }` and `{ reason }` —
        // no merged list at all. Attachment is the only thing that can close an injected message
        // whose host turn failed.
        let state = machine([
            TestEvent.accepted("s1", .ran, seq: 1),
            TestEvent.started("s1", seq: 2),
            TestEvent.accepted("s2", .injected, seq: 3),
            TestEvent.error("s1", seq: 4)
        ])

        guard case .failed = state.record("s2")?.state else {
            return XCTFail("an injected message whose host turn errored must read as errored")
        }
        XCTAssertTrue(state.unresolvedSubmissionIds.isEmpty)
    }

    func testATurnOutcomeUnknownClosesEverySubmissionAttachedToItsTurn() {
        let state = machine([
            TestEvent.accepted("s1", .ran, seq: 1),
            TestEvent.started("s1", seq: 2),
            TestEvent.accepted("s2", .injected, seq: 3),
            TestEvent.outcomeUnknown("s1", seq: 4)
        ])

        XCTAssertEqual(state.record("s2")?.state, .outcomeUnknown(.attemptAbandoned))
        XCTAssertTrue(state.unresolvedSubmissionIds.isEmpty)
    }

    // MARK: - The invariant

    func testNoSubmissionIsLeftWorkingOnceASequenceEndsWithATerminal() throws {
        // A property-style sweep: every recorded fixture, replayed, checked for the one thing
        // that must never be true.
        for name in ProtocolFixture.allNames {
            let events = try ProtocolFixture.events(name)
            guard let last = events.last, last.kind.isTerminal else { continue }

            let state = machine(events)
            XCTAssertTrue(
                state.unresolvedSubmissionIds.isEmpty,
                "\(name): \(state.unresolvedSubmissionIds) left working with no path to a terminal"
            )
        }
    }

    func testTheInjectionFixtureProducesExactlyOneReply() throws {
        let state = machine(try ProtocolFixture.events("merged-injection"))

        XCTAssertEqual(state.orderedRecords.compactMap(\.reply).count, 1)
        XCTAssertEqual(state.orderedRecords.count, 2)
        XCTAssertTrue(state.orderedRecords.allSatisfy(\.state.isTerminal))
    }

    func testTheHostErrorFixtureLeavesNothingWorking() throws {
        let state = machine(try ProtocolFixture.events("host-error-closes-injected"))

        XCTAssertTrue(state.unresolvedSubmissionIds.isEmpty)
        XCTAssertEqual(state.orderedRecords.count, 2)
    }

    func testEveryFixtureReplaysWithoutSynthesisingRecords() throws {
        for name in ProtocolFixture.allNames {
            let events = try ProtocolFixture.events(name)
            let state = machine(events)

            let namedByEvents = Set(events.compactMap(\.identity.submissionId))
            let recorded = Set(state.orderedRecords.map(\.id))
            XCTAssertTrue(
                recorded.isSubset(of: namedByEvents),
                "\(name): records exist for submissions no event named"
            )
        }
    }
}
