import XCTest
@testable import Phleet

/// Closed runs, a run's history, cancelling a run and starting one.
@MainActor
final class RunsModelTests: XCTestCase {

    private func makeAPI() throws -> FakeControlAPI {
        let api = FakeControlAPI()
        api.closedResult = .success(try ControlFixture.closedRuns())
        api.historyResult = .success(try ControlFixture.history())
        api.typesResult = .success(try ControlFixture.workflowTypes())
        return api
    }

    private func designType() throws -> WorkflowType {
        try XCTUnwrap(ControlFixture.workflowTypes().first { $0.name == "UweDesignWorkflow" })
    }

    private let running = WorkflowRun(
        workflowId: "design/synthetic 7",
        runId: "run-design-1",
        workflowType: "UweDesignWorkflow",
        namespace: "fleet"
    )

    // MARK: - Decoding

    func testAClosedRunReadsItsOutcomeAndCloseTime() throws {
        let closed = try ControlFixture.closedRuns()
        XCTAssertEqual(
            closed.map(\.outcome),
            [.completed, .failed, .canceled, .failed, .other("ContinuedAsNew")]
        )
        XCTAssertNotNil(closed[0].closeTime)
        XCTAssertNil(closed[4].closeTime)
    }

    func testHistoryKeepsEveryEntryItCanIdentify() throws {
        let events = try ControlFixture.history()
        XCTAssertEqual(events.map(\.eventId), [1, 5, 9, 14, 20, 30])
        XCTAssertEqual(events[2].agent, "builder")
        XCTAssertEqual(events[4].signalName, "merge-approval")
        XCTAssertNil(events[5].timestamp, "a bad timestamp costs the timestamp, not the entry")
    }

    func testAnEventSaysWhetherItIsAFailure() throws {
        let events = try ControlFixture.history()
        XCTAssertEqual(events.map(\.isFailure), [false, false, false, true, false, false])
        XCTAssertTrue(WorkflowEvent(eventId: 1, eventType: "WorkflowTimedOut").isFailure)
    }

    func testAnEventIsWordedForReading() throws {
        let events = try ControlFixture.history()
        XCTAssertEqual(events[2].title, "Activity completed")
        XCTAssertEqual(events[2].subject, "builder · DelegateToAgentActivity")
        XCTAssertEqual(events[2].detail, "Opened the synthetic pull request")
        // A failure's message wins over any output.
        XCTAssertEqual(events[3].detail, "The synthetic reviewer did not answer")
        XCTAssertEqual(events[4].subject, "merge-approval")
        XCTAssertNil(events[0].subject)
    }

    func testAWorkflowTypeOffersOnlyInputsAFormCanProduce() throws {
        let type = try designType()
        // The array and the nested object are left out rather than rendered as text boxes.
        XCTAssertEqual(type.fields.map(\.name), ["issueNumber", "repo", "urgent"])
        XCTAssertEqual(type.fields.map(\.kind), [.number, .text, .toggle])
        XCTAssertEqual(type.fields.map(\.isRequired), [true, true, false])
        XCTAssertEqual(type.fields[1].help, "owner/name")
    }

    func testATypeWithNoSchemaOrABrokenOneHasNoFields() throws {
        let types = try ControlFixture.workflowTypes()
        XCTAssertEqual(types.map(\.name), ["UweDesignWorkflow", "NoInputWorkflow", "BrokenSchemaWorkflow"])
        XCTAssertTrue(types[1].fields.isEmpty)
        XCTAssertTrue(types[2].fields.isEmpty)
    }

    // MARK: - Closed runs

    func testClosedRunsAreSplitByWhetherTheyFinished() async throws {
        let api = try makeAPI()
        let model = RunsModel(api: api, connection: .fixture)
        XCTAssertEqual(model.closedLoad, .idle)

        await model.refreshClosed()

        XCTAssertEqual(model.closedLoad, .loaded)
        XCTAssertEqual(api.calls, [.closedRuns(hours: 24)])
        XCTAssertEqual(model.finished.map(\.workflowId), ["pr-synthetic-60"])
        XCTAssertEqual(
            model.stopped.map(\.workflowId),
            ["pr-synthetic-61", "design-synthetic-9", "advisory-synthetic-2", "advisory-synthetic-3"]
        )
    }

    func testAFailedReadKeepsTheListThatWasThere() async throws {
        let api = try makeAPI()
        let model = RunsModel(api: api, connection: .fixture)
        await model.refreshClosed()

        api.closedResult = .failure(ControlAPIError.transport("offline"))
        await model.refreshClosed()

        XCTAssertEqual(model.closedLoad, .failed(.unreachable))
        XCTAssertEqual(model.closed.count, 5)
    }

    // MARK: - History

    func testHistoryIsReadForThatRun() async throws {
        let api = try makeAPI()
        let model = RunsModel(api: api, connection: .fixture)
        XCTAssertNil(model.history(for: running))

        await model.loadHistory(for: running)

        XCTAssertEqual(api.calls, [.runHistory(namespace: "fleet", workflowId: "design/synthetic 7")])
        guard case .loaded(let events)? = model.history(for: running) else {
            return XCTFail("the history never loaded")
        }
        XCTAssertEqual(events.count, 6)
    }

    func testAFailedReloadKeepsTheHistoryAlreadyOnScreen() async throws {
        let api = try makeAPI()
        let model = RunsModel(api: api, connection: .fixture)
        await model.loadHistory(for: running)

        api.historyResult = .failure(ControlAPIError.transport("offline"))
        await model.loadHistory(for: running)

        guard case .loaded? = model.history(for: running) else {
            return XCTFail("a failed reload blanked the history")
        }
    }

    func testAFirstReadThatFailsSaysSo() async throws {
        let api = try makeAPI()
        api.historyResult = .failure(ControlAPIError.transport("offline"))
        let model = RunsModel(api: api, connection: .fixture)

        await model.loadHistory(for: running)

        XCTAssertEqual(model.history(for: running), .failed)
    }

    // MARK: - Cancelling

    func testCancellingNamesTheRunNotJustTheWorkflow() async throws {
        let api = try makeAPI()
        let model = RunsModel(api: api, connection: .fixture)

        let accepted = await model.cancel(running)

        XCTAssertTrue(accepted)
        XCTAssertEqual(
            api.calls,
            [.cancelRun(namespace: "fleet", workflowId: "design/synthetic 7", runId: "run-design-1")]
        )
        XCTAssertEqual(model.cancelState(for: running), .requested)
    }

    func testAFailedCancelNamesWhy() async throws {
        let api = try makeAPI()
        api.cancelResult = .failure(ControlAPIError.unauthorized)
        let model = RunsModel(api: api, connection: .fixture)

        let accepted = await model.cancel(running)

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.cancelState(for: running), .failed(.tokenRejected))
    }

    // MARK: - Starting

    func testTypesAreListedByName() async throws {
        let api = try makeAPI()
        let model = RunsModel(api: api, connection: .fixture)

        await model.loadTypes()

        XCTAssertEqual(model.typesLoad, .loaded)
        XCTAssertEqual(
            model.types.map(\.name),
            ["BrokenSchemaWorkflow", "NoInputWorkflow", "UweDesignWorkflow"]
        )
    }

    func testAStartRequestCarriesTypedValuesAndOmitsWhatWasLeftEmpty() throws {
        let body = try StartWorkflow.body(
            type: try designType(),
            text: ["repo": "  example/project ", "issueNumber": "41"],
            toggles: ["urgent": true]
        )

        XCTAssertEqual(body.workflowType, "UweDesignWorkflow")
        XCTAssertEqual(body.namespace, "fleet")
        XCTAssertEqual(body.taskQueue, "fleet")
        XCTAssertEqual(
            body.input,
            ["repo": .text("example/project"), "issueNumber": .integer(41), "urgent": .toggle(true)]
        )

        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        )
        let input = try XCTUnwrap(encoded["input"] as? [String: Any])
        XCTAssertEqual(input["issueNumber"] as? Int, 41, "a number is sent as a number")
        XCTAssertEqual(input["urgent"] as? Bool, true)
        XCTAssertEqual(input["repo"] as? String, "example/project")
    }

    func testAnOptionalInputLeftEmptyIsNotSentAsAnEmptyString() throws {
        let type = WorkflowType(
            name: "T",
            namespace: "fleet",
            fields: [WorkflowInputField(name: "note", kind: .text, isRequired: false, help: nil)]
        )
        let body = try StartWorkflow.body(type: type, text: ["note": "   "], toggles: [:])
        XCTAssertTrue(body.input.isEmpty)
    }

    func testARequiredInputLeftEmptyIsRefusedBeforeAnythingIsSent() async throws {
        let api = try makeAPI()
        let model = RunsModel(api: api, connection: .fixture)

        let started = await model.start(try designType(), text: ["issueNumber": "41"], toggles: [:])

        XCTAssertNil(started)
        XCTAssertEqual(model.startState, .invalid(.missingRequired("repo")))
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testANumberInputThatIsNotANumberIsRefused() throws {
        XCTAssertThrowsError(
            try StartWorkflow.body(
                type: try designType(),
                text: ["repo": "example/project", "issueNumber": "forty-one"],
                toggles: [:]
            )
        ) { error in
            XCTAssertEqual(error as? StartWorkflowError, .notANumber("issueNumber"))
        }
    }

    func testStartingReportsTheNewRun() async throws {
        let api = try makeAPI()
        api.startResult = .success("UweDesignWorkflow-123")
        let model = RunsModel(api: api, connection: .fixture)

        let started = await model.start(
            try designType(),
            text: ["repo": "example/project", "issueNumber": "41"],
            toggles: [:]
        )

        XCTAssertEqual(started, "UweDesignWorkflow-123")
        XCTAssertEqual(model.startState, .started(workflowId: "UweDesignWorkflow-123"))

        model.resetStart()
        XCTAssertEqual(model.startState, .idle)
    }

    func testAFailedStartNamesWhy() async throws {
        let api = try makeAPI()
        api.startResult = .failure(ControlAPIError.refused(status: 500, message: "no worker"))
        let model = RunsModel(api: api, connection: .fixture)

        await model.start(
            try designType(),
            text: ["repo": "example/project", "issueNumber": "41"],
            toggles: [:]
        )

        XCTAssertEqual(model.startState, .failed(.refused("no worker")))
    }

    // MARK: - Running runs come from the fleet

    func testRunningRunsAreListedOldestFirst() async throws {
        let api = FakeControlAPI()
        api.workflowsResult = .success(try ControlFixture.runs())
        let fleet = ControlPlaneModel(
            api: api,
            stream: FakeControlLiveStream(),
            connection: .fixture,
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 1_000) },
            randomFraction: { 0 }
        )
        await fleet.refresh()

        XCTAssertEqual(
            fleet.runningRuns.map(\.workflowId),
            ["advisory-synthetic-1", "design/synthetic 7", "pr-synthetic-42", "pr-synthetic-50"]
        )
    }
}
