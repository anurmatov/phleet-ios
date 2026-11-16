import XCTest
@testable import Phleet

/// One event's complete values: read when its screen opens and never before, for that exact
/// run and event, and stoppable while being read.
@MainActor
final class EventValuesModelTests: XCTestCase {

    private let run = WorkflowRun(
        workflowId: "design/synthetic 7",
        runId: "run-design-2",
        workflowType: "UweDesignWorkflow",
        namespace: "fleet",
        status: "Completed"
    )

    private let completed = WorkflowEvent(
        eventId: 9,
        eventType: "ActivityCompleted",
        inputSummary: "Implement the synthetic…",
        outputSummary: "Opened the synthetic…"
    )

    private func model(_ api: FakeControlAPI, event: WorkflowEvent? = nil) -> EventValuesModel {
        RunsModel(api: api, connection: .fixture).eventValues(of: event ?? completed, in: run)
    }

    func testNothingIsReadUntilTheEventsScreenOpens() {
        let api = FakeControlAPI()
        let values = model(api)
        XCTAssertEqual(values.fields, [.input, .output])
        XCTAssertEqual(values.state(of: .input), .idle)
        XCTAssertEqual(values.state(of: .output), .idle)
        XCTAssertTrue(api.calls.isEmpty, "complete values were read before the event was opened")
    }

    func testOpeningTheScreenReadsEachFieldOfThatEventOnce() async {
        let api = FakeControlAPI()
        api.eventValueResult = .success(.absent)
        let values = model(api)

        values.loadPending()
        await values.settle(.input)
        await values.settle(.output)

        XCTAssertEqual(api.calls.count, 2)
        XCTAssertTrue(api.calls.contains(.eventValue(values.request(for: .input))))
        XCTAssertTrue(api.calls.contains(.eventValue(values.request(for: .output))))

        // Coming back to the screen reads nothing that is already there.
        values.loadPending()
        await values.settle(.input)
        await values.settle(.output)
        XCTAssertEqual(api.calls.count, 2, "a value on screen was read again")
    }

    func testOpeningTheScreenDoesNotRetryAStoppedOrFailedRead() async {
        let api = FakeControlAPI()
        api.eventValueResult = .failure(ControlAPIError.transport("offline"))
        let values = model(api)
        values.loadPending()
        await values.settle(.input)
        await values.settle(.output)
        XCTAssertEqual(values.state(of: .input), .failed(.unreachable))

        values.loadPending()
        await values.settle(.input)
        XCTAssertEqual(api.calls.count, 2, "a failed read was repeated without being asked for")
    }

    func testAReadNamesTheExactRunEventAndFieldAndReadsOnlyThatField() async {
        let api = FakeControlAPI()
        let original = SyntheticText.unicode(scalars: 100_000)
        api.eventValueResult = .success(
            .complete(values: [EventPayloadText(encoding: "text/plain", text: original)], sourceEventId: 5)
        )
        let values = model(api)

        values.load(.input)
        await values.settle(.input)

        XCTAssertEqual(
            api.calls,
            [.eventValue(EventValueRequest(
                namespace: "fleet", workflowId: "design/synthetic 7", runId: "run-design-2",
                eventId: 9, field: .input
            ))]
        )
        guard case .loaded(.complete(let read, 5)) = values.state(of: .input) else {
            return XCTFail("the read value is not on screen: \(values.state(of: .input))")
        }
        XCTAssertTrue(SyntheticText.scalarsEqual(read.first?.text, original))
        XCTAssertEqual(values.state(of: .output), .idle, "the other field was read too")
    }

    func testAFieldThisEventDoesNotHaveIsNotRead() async {
        let api = FakeControlAPI()
        let values = model(api)
        values.load(.failure)
        await values.settle(.failure)
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(values.state(of: .failure), .idle)
    }

    func testAskingAgainWhileReadingSendsNothingMore() async {
        let api = FakeControlAPI()
        api.onEventValue = { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            return .absent
        }
        let values = model(api)
        values.load(.output)
        values.load(.output)
        await values.settle(.output)
        XCTAssertEqual(api.calls.count, 1)
        XCTAssertEqual(values.state(of: .output), .loaded(.absent))
    }

    func testStoppingCancelsTheReadAndALateAnswerChangesNothing() async {
        let api = FakeControlAPI()
        let started = expectation(description: "the read went out")
        var sawCancellation = false
        api.onEventValue = { _ in
            started.fulfill()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                sawCancellation = true
                throw error
            }
            return .absent
        }
        let values = model(api)
        values.load(.input)
        await fulfillment(of: [started], timeout: 5)

        values.stop(.input)

        XCTAssertEqual(values.state(of: .input), .stopped)
        // Give the cancelled request every chance to answer.
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sawCancellation, "the request was not cancelled")
        XCTAssertEqual(values.state(of: .input), .stopped, "a late answer replaced the stop")
    }

    func testLeavingTheScreenCancelsReadsInFlightAndComingBackReadsThemAgain() async {
        let api = FakeControlAPI()
        var cancelled = 0
        api.onEventValue = { _ in
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                cancelled += 1
                throw error
            }
            return .absent
        }
        let values = model(api)
        values.loadPending()
        XCTAssertEqual(values.state(of: .input), .loading)
        XCTAssertEqual(values.state(of: .output), .loading)

        values.pause()

        // Not asked for, rather than a stop nobody pressed.
        XCTAssertEqual(values.state(of: .input), .idle)
        XCTAssertEqual(values.state(of: .output), .idle)
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(cancelled, 2, "leaving the screen left a read running")
        XCTAssertEqual(values.state(of: .input), .idle, "a cancelled read changed the screen")

        api.onEventValue = nil
        api.eventValueResult = .success(.absent)
        values.loadPending()
        await values.settle(.input)
        await values.settle(.output)
        XCTAssertEqual(values.state(of: .input), .loaded(.absent))
        XCTAssertEqual(values.state(of: .output), .loaded(.absent))
    }

    func testLeavingTheScreenKeepsWhatWasReadAndWhatWasStopped() async {
        let api = FakeControlAPI()
        api.eventValueResult = .success(.absent)
        let values = model(api)
        values.load(.input)
        await values.settle(.input)

        api.onEventValue = { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .absent
        }
        values.load(.output)
        values.stop(.output)

        values.pause()

        XCTAssertEqual(values.state(of: .input), .loaded(.absent))
        XCTAssertEqual(values.state(of: .output), .stopped)
    }

    func testAStoppedOrFailedReadCanBeReadAgain() async {
        let api = FakeControlAPI()
        api.eventValueResult = .failure(ControlAPIError.refused(status: 503, message: "history_timeout"))
        let values = model(api)
        values.load(.output)
        await values.settle(.output)
        XCTAssertEqual(values.state(of: .output), .failed(.timedOut))

        api.eventValueResult = .success(.tooLarge(limitBytes: 1_048_576))
        values.load(.output)
        await values.settle(.output)
        XCTAssertEqual(values.state(of: .output), .loaded(.tooLarge(limitBytes: 1_048_576)))
        XCTAssertEqual(api.calls.count, 2)
    }

    func testAnOlderServerIsNamedAndTheHistoryIsUntouched() async throws {
        let api = FakeControlAPI()
        api.historyResult = .success([completed])
        api.eventValueResult = .failure(ControlAPIError.refused(status: 404, message: nil))
        let runs = RunsModel(api: api, connection: .fixture)
        await runs.loadHistory(for: run)
        let values = runs.eventValues(of: completed, in: run)

        values.load(.output)
        await values.settle(.output)

        XCTAssertEqual(values.state(of: .output), .failed(.notOffered))
        XCTAssertEqual(runs.history(for: run), .loaded([completed]))
    }

    func testAnAnswerThatFailsItsChecksIsNotShown() async {
        let api = FakeControlAPI()
        api.eventValueResult = .failure(EventValueAnswerError.identityMismatch)
        let values = model(api)
        values.load(.input)
        await values.settle(.input)
        XCTAssertEqual(values.state(of: .input), .failed(.unreadableAnswer))
    }

    func testEveryTransportFailureIsNamed() {
        let cases: [(Error, EventValuesModel.Failure)] = [
            (ControlAPIError.unauthorized, .tokenRejected),
            (ControlAPIError.accessDenied, .accessDenied),
            (ControlAPIError.transport("offline"), .unreachable),
            (ControlAPIError.decoding("EventValueEnvelope"), .unreadableAnswer),
            (ControlAPIError.refused(status: 404, message: "not_found"), .notFound),
            (ControlAPIError.refused(status: 404, message: nil), .notOffered),
            (ControlAPIError.refused(status: 405, message: nil), .notOffered),
            (ControlAPIError.refused(status: 503, message: "history_unavailable"), .historyUnavailable),
            (ControlAPIError.refused(status: 503, message: "history_timeout"), .timedOut),
            (ControlAPIError.refused(status: 503, message: nil), .refused(nil)),
            (ControlAPIError.gateChanged("conflict"), .refused("conflict")),
            (EventValueAnswerError.inconsistent, .unreadableAnswer),
            (EventValueAnswerError.unrecognized, .unreadableAnswer)
        ]
        for (error, expected) in cases {
            XCTAssertEqual(EventValuesModel.failure(for: error), expected, "\(error)")
        }
    }
}
