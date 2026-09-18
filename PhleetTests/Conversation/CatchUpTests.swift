import XCTest
@testable import Phleet

/// The attach sequence, catch-up paging, and the cursor rules — driven through the model with
/// scripted doubles, so request *ordering* and request *values* are both assertable.
@MainActor
final class CatchUpTests: XCTestCase {

    private let origin = URL(string: "https://server.invalid")!

    private func makeModel(
        api: FakeFleetAPI,
        stream: FakeConversationStream,
        limits: SessionLimits = .documentedDefaults,
        identifiers: [String] = []
    ) -> ConversationModel {
        let store = InMemoryCredentialStore(
            credential: DeviceCredential(
                origin: "https://server.invalid",
                deviceId: "device-1",
                deviceSecret: "secret-1",
                clientInstanceId: "instance-1"
            )
        )
        let tokens = AccessTokenHolder(credentialStore: store, clock: TestClock()) { credential in
            try await api.mintToken(
                origin: URL(string: credential.origin)!,
                deviceId: credential.deviceId,
                deviceSecret: credential.deviceSecret
            )
        }

        var remaining = identifiers
        return ConversationModel(
            api: api,
            stream: stream,
            tokens: tokens,
            origin: origin,
            clientInstanceId: "instance-1",
            limits: limits,
            clock: TestClock(),
            newIdentifier: {
                remaining.isEmpty ? ClientIdentifier.random() : remaining.removeFirst()
            },
            randomFraction: { 0 },
            sleep: { _ in }
        )
    }

    private func open(nextSeq: Int, retainedFloorSeq: Int = 12) -> OpenConversationResponse {
        OpenConversationResponse(
            conversationId: "conversation-1",
            nextSeq: nextSeq,
            retainedFloorSeq: retainedFloorSeq,
            protocolVersion: ProtocolVersion.current
        )
    }

    private func page(
        events: [ConversationEvent] = [],
        nextAfterSeq: Int,
        hasMore: Bool = false,
        gap: CatchUpGap? = nil
    ) -> CatchUpResponse {
        CatchUpResponse(
            gap: gap,
            events: events,
            nextAfterSeq: nextAfterSeq,
            hasMore: hasMore,
            protocolVersion: ProtocolVersion.current
        )
    }

    private func closingScript(
        _ events: [ConversationEvent] = [],
        code: Int = 4409,
        nextSeq: Int = 41
    ) -> [ConversationStreamEvent] {
        [.hello(FakeConversationStream.hello(nextSeq: nextSeq))]
            + events.map { ConversationStreamEvent.event($0) }
            + [.closed(code: code, reason: nil)]
    }

    // MARK: - Attach order

    func testTheStreamIsAttachedAndHelloReceivedBeforeCatchUpIsIssued() async {
        let api = FakeFleetAPI()
        let stream = FakeConversationStream(scripts: [closingScript()])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()

        // Catch-up-then-attach leaves an interval between the read and the upgrade in which
        // appended events belong to neither, and the client cannot tell a quiet interval from a
        // lossy one.
        let openIndex = api.calls.firstIndex { if case .openConversation = $0 { return true } else { return false } }
        let catchUpIndex = api.calls.firstIndex { if case .catchUp = $0 { return true } else { return false } }

        XCTAssertNotNil(openIndex)
        XCTAssertNotNil(catchUpIndex)
        XCTAssertLessThan(openIndex!, catchUpIndex!)
        XCTAssertEqual(stream.attaches.count, 1)
    }

    // MARK: - The two cursors

    func testColdStartSendsTheColdStartCursorExplicitly() async {
        let api = FakeFleetAPI()
        api.openResults = [.success(open(nextSeq: 1, retainedFloorSeq: 0))]
        let stream = FakeConversationStream(scripts: [closingScript(nextSeq: 1)])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()

        XCTAssertEqual(api.catchUpCursors.first, 0)
        XCTAssertEqual(
            api.catchUpCursors.first,
            CatchUpCursor.coldStart,
            "not the recovery floor, not a negative value, and not omitted"
        )
    }

    func testTheStreamAttachesAtTheLiveTailFloorAndCatchUpDoesNot() async {
        // The exact regression: a conversation at seq 900 with a client that has processed 10.
        let api = FakeFleetAPI()
        api.openResults = [.success(open(nextSeq: 900))]
        api.catchUpResults = [.success(page(nextAfterSeq: 10))]
        let stream = FakeConversationStream(scripts: [closingScript(nextSeq: 900)])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()

        XCTAssertEqual(stream.attachFloors, [899])
        XCTAssertEqual(api.catchUpCursors, [0])
        XCTAssertNotEqual(stream.attachFloors.first, api.catchUpCursors.first)
    }

    func testAFreshConversationAttachesAtZeroWithoutUnderflow() async {
        for nextSeq in [0, 1] {
            let api = FakeFleetAPI()
            api.openResults = [.success(open(nextSeq: nextSeq, retainedFloorSeq: 0))]
            let stream = FakeConversationStream(scripts: [closingScript(nextSeq: nextSeq)])
            let model = makeModel(api: api, stream: stream)

            _ = await model.runOnce()
            XCTAssertEqual(stream.attachFloors, [0])
        }
    }

    func testEveryAttachUsesAFloorDerivedFromItsOwnOpenResponse() async {
        let api = FakeFleetAPI()
        api.openResults = [
            .success(open(nextSeq: 900)),
            .success(open(nextSeq: 950))
        ]
        let stream = FakeConversationStream(scripts: [
            closingScript(code: 4500, nextSeq: 900),
            closingScript(code: 4409, nextSeq: 950)
        ])
        let model = makeModel(api: api, stream: stream)

        await model.run()

        XCTAssertEqual(stream.attachFloors, [899, 949])
    }

    // MARK: - Paging

    func testCatchUpPagesWhileHasMoreIsTrue() async {
        let api = FakeFleetAPI()
        api.catchUpResults = [
            .success(page(events: [TestEvent.started("s1", seq: 1)], nextAfterSeq: 1, hasMore: true)),
            .success(page(events: [TestEvent.progress("s1", seq: 2)], nextAfterSeq: 2, hasMore: true)),
            .success(page(events: [TestEvent.final("s1", seq: 3, merged: ["s1"])], nextAfterSeq: 3))
        ]
        let stream = FakeConversationStream(scripts: [closingScript()])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()

        XCTAssertEqual(api.catchUpCursors, [0, 1, 2])
        XCTAssertTrue(model.machine.record("s1")?.state.isTerminal == true)
        XCTAssertEqual(model.lastAppliedSeq, 3)
    }

    func testAnEventOnTheStreamAndInCatchUpIsAppliedOnce() async {
        let shared = TestEvent.final("s1", seq: 41, merged: ["s1"], eventId: "shared-event")
        let api = FakeFleetAPI()
        api.catchUpResults = [.success(page(events: [shared], nextAfterSeq: 41))]
        let stream = FakeConversationStream(scripts: [closingScript([shared])])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()

        XCTAssertEqual(model.machine.orderedRecords.compactMap(\.reply).count, 1)
    }

    func testAGapIsRenderedAndNeverDropped() async {
        let api = FakeFleetAPI()
        api.catchUpResults = [
            .success(page(
                nextAfterSeq: 20,
                gap: CatchUpGap(fromSeq: 1, toSeq: 19, retainedFloorSeq: 20)
            ))
        ]
        let stream = FakeConversationStream(scripts: [closingScript()])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()

        let gaps = model.machine.entries.filter {
            if case .systemLine(let line) = $0 { return line.kind == .replayGap }
            return false
        }
        XCTAssertEqual(gaps.count, 1, "silent history loss is the failure the person cannot detect")
    }

    // MARK: - Limits

    func testTheClientNeverRequestsALimitAboveTheServerMaximum() async {
        let api = FakeFleetAPI()
        let limits = SessionLimits(
            inboundTextBytes: 32768,
            catchUpLimitDefault: 5000,
            catchUpLimitMax: 100,
            identifierMaxLength: 128,
            outboundBufferEvents: 256
        )
        let stream = FakeConversationStream(scripts: [closingScript()])
        let model = makeModel(api: api, stream: stream, limits: limits)

        _ = await model.runOnce()

        XCTAssertEqual(api.catchUpLimits, [100])
    }

    func testAnOverMaximumLimitIsSurfacedRatherThanRetriedIdentically() async {
        let api = FakeFleetAPI()
        api.catchUpResults = [
            .failure(FleetAPIError.refused(.unsupportedKind, status: 400, message: nil))
        ]
        let stream = FakeConversationStream(scripts: [closingScript()])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()

        // The server does not clamp, by design, and clamping client-side would convert a
        // detectable fault into silent partial history.
        XCTAssertEqual(api.catchUpCursors.count, 1)
        XCTAssertTrue(model.clientDefects.contains("catchUp.limit"))
    }

    // MARK: - invalid_cursor

    func testAnInvalidCursorResetsToTheRecoveryFloorAndCatchesUpAgain() async {
        let api = FakeFleetAPI()
        api.openResults = [.success(open(nextSeq: 900, retainedFloorSeq: 20))]
        api.catchUpResults = [
            .failure(FleetAPIError.refused(.invalidCursor, status: 400, message: nil)),
            .success(page(nextAfterSeq: 30))
        ]
        let stream = FakeConversationStream(scripts: [closingScript(nextSeq: 900)])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()

        XCTAssertEqual(api.catchUpCursors, [0, 19])
        XCTAssertEqual(model.invalidCursorRecoveries, 1, "never a silent continuation")
    }

    func testTheRecoveryFloorDoesNotUnderflowOnAFreshConversation() async {
        let api = FakeFleetAPI()
        api.openResults = [.success(open(nextSeq: 1, retainedFloorSeq: 0))]
        api.catchUpResults = [
            .failure(FleetAPIError.refused(.invalidCursor, status: 400, message: nil)),
            .success(page(nextAfterSeq: 0))
        ]
        let stream = FakeConversationStream(scripts: [closingScript(nextSeq: 1)])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()

        XCTAssertEqual(api.catchUpCursors, [0, 0])
        XCTAssertTrue(
            model.clientDefects.isEmpty,
            "the guard is what stops the recovery attempt answering with a second invalid_cursor"
        )
    }

    // MARK: - The bounded buffer

    func testOverflowDiscardsTheBufferAndIssuesExactlyOneExtraRound() async {
        let limits = SessionLimits(
            inboundTextBytes: 32768,
            catchUpLimitDefault: 200,
            catchUpLimitMax: 1000,
            identifierMaxLength: 128,
            outboundBufferEvents: 4
        )
        let api = FakeFleetAPI()
        let stream = FakeConversationStream(scripts: [[
            .hello(FakeConversationStream.hello())
        ]])
        stream.finishesAfterScript = false

        // Frames only reach the buffer while a catch-up is genuinely in flight: once the client
        // is live it applies them directly. So they are put on the wire from inside the catch-up
        // call, and the catch-up is made to suspend while they are consumed.
        api.catchUpSuspensions = 64
        var pushed = false
        api.onCatchUp = { _ in
            guard !pushed else { return }
            pushed = true
            stream.push(
                (1...5).map { .event(TestEvent.progress("s1", seq: $0)) }
                    + [.closed(code: 4409, reason: nil)],
                finishing: true
            )
        }

        let model = makeModel(api: api, stream: stream, limits: limits)
        _ = await model.runOnce()

        XCTAssertEqual(model.catchUpRounds, 2, "one initial round plus the one the overflow owes")
        XCTAssertEqual(
            api.catchUpCursors,
            [0, 0],
            "the extra round is issued from lastApplied, and the floor does not move, so it terminates"
        )
    }

    // MARK: - Sending

    func testARetriedSendReusesTheSameIdentifiers() async {
        let api = FakeFleetAPI()
        api.submitResults = [.failure(FleetAPIError.transport("dropped"))]
        let stream = FakeConversationStream(scripts: [closingScript()])
        let model = makeModel(api: api, stream: stream, identifiers: ["s-1", "k-1"])

        _ = await model.runOnce()
        let submission = await model.send("hello")
        XCTAssertEqual(model.sendFailure, .notKnownToHaveHappened)

        await model.retrySend(submissionId: try! XCTUnwrap(submission?.submissionId))

        // A non-2xx never means "did not happen"; it means "not known to have happened", and a
        // fresh id on retry is how one message becomes two turns.
        XCTAssertEqual(api.submissions.count, 2)
        XCTAssertEqual(api.submissions[0].submissionId, api.submissions[1].submissionId)
        XCTAssertEqual(api.submissions[0].idempotencyKey, api.submissions[1].idempotencyKey)
    }

    func testSendAgainIssuesNewIdentifiers() async {
        let api = FakeFleetAPI()
        let stream = FakeConversationStream(scripts: [closingScript()])
        let model = makeModel(
            api: api,
            stream: stream,
            identifiers: ["s-1", "k-1", "s-2", "k-2"]
        )

        _ = await model.runOnce()
        let first = await model.send("hello")
        let second = await model.sendAgain(after: try! XCTUnwrap(first?.submissionId))

        // The single exception to the reuse rule, and it exists only behind an explicit tap.
        XCTAssertEqual(first?.submissionId, "s-1")
        XCTAssertEqual(second?.submissionId, "s-2")
        XCTAssertNotEqual(first?.idempotencyKey, second?.idempotencyKey)
    }

    func testTheComposerBlocksTextOverTheByteLimitAndCountsBytesNotCharacters() async {
        let api = FakeFleetAPI()
        let stream = FakeConversationStream(scripts: [closingScript()])
        let model = makeModel(api: api, stream: stream)
        _ = await model.runOnce()

        // Four bytes per character, so the byte count is four times the character count. A
        // character-based check would let this through.
        let oversize = String(repeating: "🙂", count: 8193)
        XCTAssertEqual(oversize.utf8.count, 32772)
        XCTAssertGreaterThan(oversize.utf8.count, 32768)
        XCTAssertFalse(model.isWithinInboundLimit(oversize))

        let before = api.submissions.count
        let submission = await model.send(oversize)
        XCTAssertNil(submission)
        XCTAssertEqual(model.sendFailure, .tooLarge)
        XCTAssertEqual(api.submissions.count, before, "nothing is sent")
    }

    func testAServerSideTooLargeIsHandledWithoutDuplicatingTheSubmission() async {
        let api = FakeFleetAPI()
        api.submitResults = [
            .failure(FleetAPIError.refused(.payloadTooLarge, status: 413, message: nil))
        ]
        let stream = FakeConversationStream(scripts: [closingScript()])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()
        _ = await model.send("within the local limit")

        XCTAssertEqual(model.sendFailure, .tooLarge)
        XCTAssertEqual(api.submissions.count, 1, "no retry, no duplicate")
    }

    func testAnIdempotencyConflictIsSurfacedRatherThanWorkedAround() async {
        let api = FakeFleetAPI()
        api.submitResults = [
            .failure(FleetAPIError.refused(.idempotencyConflict, status: 409, message: nil))
        ]
        let stream = FakeConversationStream(scripts: [closingScript()])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()
        _ = await model.send("hello")

        XCTAssertEqual(model.sendFailure, .idempotencyConflict)
        XCTAssertTrue(model.clientDefects.contains("submission.idempotencyKey"))
        XCTAssertEqual(api.submissions.count, 1)
    }

    // MARK: - Close handling

    func testA4413MidSessionReconnectsAndCatchesUp() async {
        let api = FakeFleetAPI()
        let stream = FakeConversationStream(scripts: [
            closingScript([TestEvent.started("s1", seq: 41)], code: 4413),
            closingScript(code: 4409)
        ])
        let model = makeModel(api: api, stream: stream)

        await model.run()

        XCTAssertEqual(model.lastCloseAction, .disarm)
        XCTAssertEqual(stream.attaches.count, 2)
        XCTAssertGreaterThanOrEqual(api.catchUpCursors.count, 2, "the reconnect catches up")
    }

    func testA4413OnTheFirstFrameReattachesAtAFloorFromAFreshOpen() async {
        let api = FakeFleetAPI()
        api.openResults = [
            .success(open(nextSeq: 900)),
            .success(open(nextSeq: 1200))
        ]
        let stream = FakeConversationStream(scripts: [
            // No frame applied between hello and the close: the attach floor was wrong, not the
            // client slow. Reattaching at the same floor would loop forever.
            [.hello(FakeConversationStream.hello(nextSeq: 900)), .closed(code: 4413, reason: nil)],
            closingScript(code: 4409, nextSeq: 1200)
        ])
        let model = makeModel(api: api, stream: stream)

        await model.run()

        XCTAssertEqual(stream.attachFloors, [899, 1199])
        XCTAssertNotEqual(stream.attachFloors[0], stream.attachFloors[1])
    }

    func testA4409DisarmsAndPerformsNoFurtherAttempts() async {
        let api = FakeFleetAPI()
        let stream = FakeConversationStream(scripts: [closingScript(code: 4409)])
        let model = makeModel(api: api, stream: stream)

        await model.run()

        XCTAssertEqual(stream.attaches.count, 1, "zero reconnect attempts after a supersede")
        XCTAssertEqual(model.connectionState, .superseded)
    }

    func testA4403IsTerminalWithNoReconnect() async {
        let api = FakeFleetAPI()
        let stream = FakeConversationStream(scripts: [closingScript(code: 4403)])
        let model = makeModel(api: api, stream: stream)

        await model.run()

        XCTAssertEqual(stream.attaches.count, 1)
        XCTAssertEqual(model.connectionState, .notPermitted)
    }

    func testTokenExpiryMidStreamReconnectsAndRendersTheTerminalExactlyOnce() async {
        let terminal = TestEvent.final("s1", seq: 42, merged: ["s1"], eventId: "terminal-once")
        let api = FakeFleetAPI()
        api.catchUpResults = [
            .success(page(nextAfterSeq: 0)),
            // The reconnect's catch-up carries the terminal the dropped connection missed.
            .success(page(events: [TestEvent.started("s1", seq: 41), terminal], nextAfterSeq: 42))
        ]
        let stream = FakeConversationStream(scripts: [
            [.hello(FakeConversationStream.hello()), .closed(code: 4401, reason: nil)],
            // And the live stream repeats it, which dedupe absorbs.
            closingScript([terminal], code: 4409)
        ])
        let model = makeModel(api: api, stream: stream)

        await model.run()

        XCTAssertEqual(stream.attaches.count, 2)
        XCTAssertEqual(
            model.machine.orderedRecords.compactMap(\.reply).count,
            1,
            "the terminal is rendered exactly once, with no duplicate entry"
        )
        XCTAssertGreaterThanOrEqual(api.mintCallCount, 1)
    }

    // MARK: - Cursor

    func testTheCursorIsWrittenWithReadNeverAboveDelivered() async {
        let api = FakeFleetAPI()
        api.catchUpResults = [.success(page(nextAfterSeq: 30))]
        let stream = FakeConversationStream(scripts: [closingScript()])
        let model = makeModel(api: api, stream: stream)

        _ = await model.runOnce()

        let cursors = api.calls.compactMap { call -> (Int, Int?)? in
            if case .cursor(_, let delivered, let read) = call { return (delivered, read) }
            return nil
        }
        XCTAssertFalse(cursors.isEmpty)
        for (delivered, read) in cursors {
            XCTAssertLessThanOrEqual(read ?? 0, delivered)
        }
    }
}
