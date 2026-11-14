import XCTest
@testable import Phleet

/// Terminating and restarting a run, how far back closed runs are read, what led to a gate, and
/// the schedules and memory models.
@MainActor
final class RunAndScheduleActionsTests: XCTestCase {

    private let running = WorkflowRun(
        workflowId: "design/synthetic 7",
        runId: "run-design-1",
        workflowType: "UweDesignWorkflow",
        namespace: "fleet"
    )

    private let failed = WorkflowRun(
        workflowId: "pr-42",
        runId: "run-pr-1",
        workflowType: "UwePrImplementationWorkflow",
        namespace: "fleet",
        status: "Failed"
    )

    // MARK: - Terminating

    func testATerminateNamesTheRunAndIsRecordedAsRequested() async {
        let api = FakeControlAPI()
        let model = RunsModel(api: api, connection: .fixture)

        let accepted = await model.terminate(running)

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.terminateState(for: running), .requested)
        XCTAssertEqual(
            api.calls,
            [.terminateRun(namespace: "fleet", workflowId: "design/synthetic 7", runId: "run-design-1")]
        )
        XCTAssertNil(model.cancelState(for: running), "a terminate is not a cancel")
    }

    func testATerminateThatDidNotCompleteSaysItsOutcomeIsUnknown() async {
        let api = FakeControlAPI()
        api.terminateResult = .failure(ControlAPIError.transport("offline"))
        let model = RunsModel(api: api, connection: .fixture)

        let accepted = await model.terminate(running)

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.terminateState(for: running), .failed(.outcomeUnknown))
    }

    // MARK: - Restarting

    func testARestartNamesTheClosedRunAndReportsTheNewOne() async {
        let api = FakeControlAPI()
        api.restartResult = .success(RestartedRun(newWorkflowId: "pr-42-again", newRunId: "run-2"))
        let model = RunsModel(api: api, connection: .fixture)

        let restarted = await model.restart(failed)

        XCTAssertEqual(restarted?.newWorkflowId, "pr-42-again")
        XCTAssertEqual(model.restartState(for: failed), .restarted(workflowId: "pr-42-again"))
        XCTAssertEqual(
            api.calls,
            [.restartRun(namespace: "fleet", workflowId: "pr-42", runId: "run-pr-1")]
        )
    }

    func testARefusedRestartCarriesTheServersWords() async {
        let api = FakeControlAPI()
        api.restartResult = .failure(
            ControlAPIError.refused(status: 500, message: "Failed to restart workflow")
        )
        let model = RunsModel(api: api, connection: .fixture)

        let restarted = await model.restart(failed)

        XCTAssertNil(restarted)
        XCTAssertEqual(
            model.restartState(for: failed),
            .failed(.refused("Failed to restart workflow"))
        )
    }

    func testRestartedRunDecodesWithOrWithoutARunIdentifier() throws {
        let whole = #"{"message":"m","newWorkflowId":"w-2","newRunId":"r-2"}"#
        XCTAssertEqual(
            try JSONDecoder().decode(RestartedRun.self, from: Data(whole.utf8)),
            RestartedRun(newWorkflowId: "w-2", newRunId: "r-2")
        )
        let bare = #"{"newWorkflowId":"w-2"}"#
        XCTAssertNil(try JSONDecoder().decode(RestartedRun.self, from: Data(bare.utf8)).newRunId)
    }

    // MARK: - The window

    func testClosedRunsAreReadForTheLastDayUntilAnotherWindowIsChosen() async {
        let api = FakeControlAPI()
        let model = RunsModel(api: api, connection: .fixture)

        await model.refreshClosed()
        await model.setWindow(hours: 72)

        XCTAssertEqual(model.windowHours, 72)
        XCTAssertEqual(api.calls, [.closedRuns(hours: 24), .closedRuns(hours: 72)])
    }

    func testAWindowThatIsNotOfferedIsNotAskedFor() async {
        let api = FakeControlAPI()
        let model = RunsModel(api: api, connection: .fixture)

        // More than the orchestrator reads: it would cap the answer and the label would lie.
        await model.setWindow(hours: 720)
        // The window already in use: nothing to read again.
        await model.setWindow(hours: 24)

        XCTAssertEqual(model.windowHours, 24)
        XCTAssertTrue(api.calls.isEmpty)
    }

    // MARK: - What led to a gate

    private func fleetModel(_ api: FakeControlAPI) -> ControlPlaneModel {
        ControlPlaneModel(
            api: api,
            stream: FakeControlLiveStream(),
            connection: .fixture,
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 1_000) },
            randomFraction: { 0 }
        )
    }

    private func waitingModel(_ api: FakeControlAPI) async throws -> (ControlPlaneModel, PendingGate) {
        api.agentsResult = .success(try ControlFixture.agents())
        api.workflowsResult = .success(try ControlFixture.runs())
        api.registryResult = .success(try ControlFixture.registry())
        let model = fleetModel(api)
        await model.refresh()
        let gate = try XCTUnwrap(model.gates.first { $0.signal.name == "merge-approval" })
        return (model, gate)
    }

    func testGateActivityIsReadFromThatExactRun() async throws {
        let api = FakeControlAPI()
        api.historyResult = .success([
            WorkflowEvent(eventId: 1, eventType: "WorkflowStarted"),
            WorkflowEvent(eventId: 2, eventType: "ActivityCompleted", agent: "builder", outputSummary: "Built")
        ])
        let (model, gate) = try await waitingModel(api)

        await model.loadGateActivity(for: gate)

        XCTAssertEqual(
            api.count(of: .exactRunHistory(
                namespace: gate.run.namespace,
                workflowId: gate.run.workflowId,
                runId: gate.run.runId
            )),
            1,
            "the run is named by its run identifier, never as the latest run of the workflow"
        )
        guard case .loaded(let events)? = model.gateActivity(for: gate) else {
            return XCTFail("expected the activity to have loaded")
        }
        XCTAssertEqual(events.map(\.eventId), [2])
    }

    func testAnUnreadableHistoryIsSaidAndTheGateStillWaits() async throws {
        let api = FakeControlAPI()
        api.onExactHistory = { throw ControlAPIError.transport("offline") }
        let (model, gate) = try await waitingModel(api)

        await model.loadGateActivity(for: gate)

        XCTAssertEqual(model.gateActivity(for: gate), .unavailable)
        XCTAssertTrue(model.isWaiting(gate), "a decision never depended on the history")
    }

    func testActivityIsForgottenWithTheGateItBelongedTo() async throws {
        let api = FakeControlAPI()
        let (model, gate) = try await waitingModel(api)
        await model.loadGateActivity(for: gate)
        XCTAssertNotNil(model.gateActivity(for: gate))

        api.workflowsResult = .success([])
        await model.refresh()

        XCTAssertNil(model.gateActivity(for: gate))
    }

    // MARK: - Schedules

    private let nightly = FleetSchedule(
        scheduleId: "nightly",
        namespace: "fleet",
        workflowType: "UweNightly",
        cronExpression: "0 3 * * *"
    )

    func testSchedulesAreListedByIdentifier() async {
        let api = FakeControlAPI()
        api.schedulesResult = .success([
            FleetSchedule(scheduleId: "weekly", namespace: "fleet"),
            nightly
        ])
        let model = SchedulesModel(api: api, connection: .fixture)

        await model.refresh()

        XCTAssertEqual(model.load, .loaded)
        XCTAssertEqual(model.schedules.map(\.scheduleId), ["nightly", "weekly"])
    }

    func testAFailedReadKeepsTheSchedulesThatWereListed() async {
        let api = FakeControlAPI()
        api.schedulesResult = .success([nightly])
        let model = SchedulesModel(api: api, connection: .fixture)
        await model.refresh()

        api.schedulesResult = .failure(ControlAPIError.transport("offline"))
        await model.refresh()

        XCTAssertEqual(model.load, .failed(.unreachable))
        XCTAssertEqual(model.schedules, [nightly])
    }

    func testPausingAScheduleReadsTheListAgainRatherThanAssumingTheResult() async {
        let api = FakeControlAPI()
        api.schedulesResult = .success([nightly])
        let model = SchedulesModel(api: api, connection: .fixture)
        await model.refresh()

        let paused = FleetSchedule(
            scheduleId: "nightly",
            namespace: "fleet",
            workflowType: "UweNightly",
            cronExpression: "0 3 * * *",
            isPaused: true
        )
        api.onScheduleAction = { api.schedulesResult = .success([paused]) }

        let accepted = await model.perform(.pause, on: nightly)

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.actionState(for: nightly), .done(.pause))
        XCTAssertEqual(model.schedule(id: nightly.id)?.isPaused, true)
        XCTAssertEqual(
            api.calls,
            [
                .schedules,
                .scheduleAction(namespace: "fleet", scheduleId: "nightly", action: .pause),
                .schedules
            ]
        )
    }

    func testARefusedScheduleActionChangesNothingAndSaysWhy() async {
        let api = FakeControlAPI()
        api.schedulesResult = .success([nightly])
        api.scheduleActionResult = .failure(
            ControlAPIError.refused(status: 404, message: "Schedule not found")
        )
        let model = SchedulesModel(api: api, connection: .fixture)
        await model.refresh()

        let accepted = await model.perform(.trigger, on: nightly)

        XCTAssertFalse(accepted)
        XCTAssertEqual(
            model.actionState(for: nightly),
            .failed(.trigger, .refused("Schedule not found"))
        )
        XCTAssertEqual(api.count(of: .schedules), 1, "nothing is read again after a refusal")
    }

    func testWhatIsOfferedFollowsWhetherTheScheduleIsPaused() {
        XCTAssertEqual(ScheduleAction.available(for: nightly), [.trigger, .pause])
        XCTAssertEqual(
            ScheduleAction.available(
                for: FleetSchedule(scheduleId: "nightly", namespace: "fleet", isPaused: true)
            ),
            [.unpause, .trigger]
        )
    }

    // MARK: - Memory

    func testASearchIsSentTrimmedAndItsResultsAreShownUnderItsWords() async {
        let api = FakeControlAPI()
        api.memorySearchResult = .success([MemorySearchResult(id: "m-1", title: "Deploying")])
        let model = MemoryModel(api: api, connection: .fixture)

        await model.run(query: "  how do we deploy  ")

        XCTAssertEqual(api.calls, [.searchMemory(query: "how do we deploy")])
        XCTAssertEqual(model.answeredQuery, "how do we deploy")
        XCTAssertEqual(model.search, .found([MemorySearchResult(id: "m-1", title: "Deploying")]))
    }

    func testABlankSearchAsksTheServerNothing() async {
        let api = FakeControlAPI()
        let model = MemoryModel(api: api, connection: .fixture)

        await model.run(query: "   ")

        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(model.search, .idle)
    }

    func testAFailedSearchSaysWhy() async {
        let api = FakeControlAPI()
        api.memorySearchResult = .failure(ControlAPIError.accessDenied)
        let model = MemoryModel(api: api, connection: .fixture)

        await model.run(query: "deploy")

        XCTAssertEqual(model.search, .failed(.accessDenied))
    }

    func testAMemoryIsReadInFullAndAFailedRereadKeepsIt() async {
        let api = FakeControlAPI()
        let model = MemoryModel(api: api, connection: .fixture)

        await model.loadDocument(id: "m-1")
        let loaded = model.document(id: "m-1")

        api.memoryResult = .failure(ControlAPIError.transport("offline"))
        await model.loadDocument(id: "m-1")

        XCTAssertEqual(
            loaded,
            .loaded(MemoryDocument(id: "memory-1", title: "Synthetic memory", content: "Synthetic content"))
        )
        XCTAssertEqual(model.document(id: "m-1"), loaded)
        XCTAssertEqual(api.calls, [.memory(id: "m-1"), .memory(id: "m-1")])
    }

    func testAMemoryThatCouldNeverBeReadSaysSo() async {
        let api = FakeControlAPI()
        api.memoryResult = .failure(ControlAPIError.refused(status: 404, message: nil))
        let model = MemoryModel(api: api, connection: .fixture)

        await model.loadDocument(id: "gone")

        XCTAssertEqual(model.document(id: "gone"), .failed)
    }
}
