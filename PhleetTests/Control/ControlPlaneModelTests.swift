import XCTest
@testable import Phleet

/// The fleet model: reading, the live socket, and deciding a gate.
///
/// Driven through `refresh()`, `apply(_:)` and `decide(…)` directly. The two loops that call
/// them on a timer are thin, and exercising them here would mean asserting on scheduling.
@MainActor
final class ControlPlaneModelTests: XCTestCase {

    private func makeAPI() throws -> FakeControlAPI {
        let api = FakeControlAPI()
        api.agentsResult = .success(try ControlFixture.agents())
        api.workflowsResult = .success(try ControlFixture.runs())
        api.registryResult = .success(try ControlFixture.registry())
        return api
    }

    private func makeModel(
        _ api: FakeControlAPI,
        connection: ControlConnection = .fixture,
        stream: FakeControlLiveStream = FakeControlLiveStream()
    ) -> ControlPlaneModel {
        ControlPlaneModel(
            api: api,
            stream: stream,
            connection: connection,
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 1_000) },
            randomFraction: { 0 }
        )
    }

    private func mergeGate(_ model: ControlPlaneModel) throws -> PendingGate {
        try XCTUnwrap(model.gates.first { $0.signal.name == "merge-approval" })
    }

    private func approve(_ gate: PendingGate) throws -> SignalButton {
        try XCTUnwrap(gate.signal.buttons.first { !$0.requiresComment })
    }

    // MARK: - Reading

    func testARefreshFillsAgentsAndGates() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        XCTAssertEqual(model.status, .loading)

        await model.refresh()

        XCTAssertEqual(model.status, .current(isLive: false))
        XCTAssertEqual(model.agents.map(\.agentName), ["planner", "builder", "reviewer", "spare"])
        XCTAssertEqual(model.gates.map(\.signal.name), ["design-approval", "merge-approval"])
        XCTAssertEqual(model.lastUpdated, Date(timeIntervalSince1970: 1_000))
    }

    func testEveryReadPresentsTheStoredConnection() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()

        XCTAssertEqual(api.calls, [.signalRegistry, .agents, .workflows])
        XCTAssertTrue(api.connections.allSatisfy { $0 == .fixture })
    }

    func testAFailedReadKeepsWhatWasAlreadyOnScreen() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()

        api.agentsResult = .failure(ControlAPIError.transport("offline"))
        await model.refresh()

        XCTAssertEqual(model.status, .failed(.unreachable))
        XCTAssertEqual(model.agents.count, 4, "a failed read must not blank the fleet")
        XCTAssertEqual(model.gates.count, 2)
    }

    func testAReadFailureNamesWhereTheProblemIs() async throws {
        let cases: [(ControlAPIError, ControlPlaneModel.Failure)] = [
            (.accessDenied, .accessDenied),
            (.transport("x"), .unreachable),
            (.decoding("x"), .unexpectedAnswer),
            (.refused(status: 500, message: nil), .unexpectedAnswer)
        ]
        for (error, expected) in cases {
            let api = try makeAPI()
            api.registryResult = .failure(error)
            let model = makeModel(api)
            await model.refresh()
            XCTAssertEqual(model.status, .failed(expected), "\(error)")
        }
    }

    func testAnAgentTheOrchestratorNoLongerListsIsGone() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()

        api.agentsResult = .success(try ControlFixture.agents().filter { $0.agentName != "spare" })
        await model.refresh()

        XCTAssertNil(model.agent(named: "spare"), "agents are replaced on a read, not merged")
        XCTAssertEqual(model.agents.count, 3)
    }

    // MARK: - The live socket

    func testALiveAgentFrameUpdatesThatAgentAndMarksTheFleetLive() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        XCTAssertEqual(model.agent(named: "reviewer")?.health, .idle)

        let frame = try XCTUnwrap(
            try ControlLiveFrame.decode(text: ControlFixture.text("live-agent"))
        )
        model.apply(.frame(frame))

        XCTAssertEqual(model.agent(named: "reviewer")?.health, .working)
        XCTAssertEqual(model.agents.count, 4)
        XCTAssertEqual(model.status, .current(isLive: true))
    }

    func testALiveWorkflowsFrameRemovesAGateThatMovedOn() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        XCTAssertEqual(model.gates.count, 2)

        let frame = try XCTUnwrap(
            try ControlLiveFrame.decode(text: ControlFixture.text("live-workflows"))
        )
        model.apply(.frame(frame))

        XCTAssertTrue(model.gates.isEmpty, "the only listed run is past its gate")
    }

    func testAnEndedSocketLeavesTheFleetCurrentButNotLive() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        model.apply(.frame(.agent(FleetAgent(agentName: "builder", effectiveStatus: "idle"))))
        XCTAssertEqual(model.status, .current(isLive: true))

        model.apply(.ended)

        // The HTTPS reads are the source of truth; losing the socket costs freshness only.
        XCTAssertEqual(model.status, .current(isLive: false))
        XCTAssertEqual(model.agents.count, 4)
    }

    func testAnUndecodableFrameChangesNothing() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()

        model.apply(.undecodableFrame)

        XCTAssertEqual(model.status, .current(isLive: false))
        XCTAssertEqual(model.agents.count, 4)
    }

    // MARK: - Deciding

    func testAnAcceptedDecisionSendsTheGateAsShownAndTakesItOffTheList() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        let gate = try mergeGate(model)

        let sent = await model.decide(gate: gate, button: try approve(gate), comment: "")

        XCTAssertTrue(sent)
        XCTAssertEqual(
            api.calls.last,
            .sendSignal(
                namespace: "fleet",
                workflowId: "pr-synthetic-42",
                body: SignalRequestBody(
                    signalName: "merge-approval",
                    workflowType: "UwePrImplementationWorkflow",
                    payload: #"{"Decision":"approved"}"#,
                    runId: "run-merge-1",
                    expectedGateRef: "gate-synthetic-a"
                )
            )
        )
        // The orchestrator still lists the run in its gate phase for a moment. It must not
        // invite a second answer.
        XCTAssertFalse(model.isWaiting(gate))
        XCTAssertEqual(model.gates.map(\.signal.name), ["design-approval"])
        XCTAssertNil(model.decisionState(for: gate))
    }

    func testAnAnsweredGateStaysOffTheListAcrossReadsThatStillShowIt() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        let gate = try mergeGate(model)
        await model.decide(gate: gate, button: try approve(gate), comment: "")

        await model.refresh()

        XCTAssertFalse(model.isWaiting(gate))
    }

    func testANewVisitToAnAnsweredGateIsOfferedAgain() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        let gate = try mergeGate(model)
        await model.decide(gate: gate, button: try approve(gate), comment: "")

        // Changes were requested, the work was redone, and the same run is back at the gate.
        let revisited = WorkflowRun(
            workflowId: gate.run.workflowId,
            runId: gate.run.runId,
            workflowType: gate.run.workflowType,
            namespace: gate.run.namespace,
            phase: "merge-approval",
            gateRef: "gate-synthetic-b"
        )
        model.apply(.frame(.workflows([revisited])))

        XCTAssertEqual(model.gates.count, 1)
        XCTAssertEqual(model.gates.first?.run.gateRef, "gate-synthetic-b")
        XCTAssertTrue(model.answeredGateIds.isEmpty, "the answered visit is no longer listed")
    }

    func testAChangedGateIsReportedAndTheFleetIsReadAgain() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        let gate = try mergeGate(model)
        let readsBefore = api.count(of: .workflows)
        api.signalResult = .failure(ControlAPIError.gateChanged("stale_gate"))

        let sent = await model.decide(gate: gate, button: try approve(gate), comment: "")

        XCTAssertFalse(sent)
        XCTAssertEqual(model.decisionState(for: gate), .failed(.gateChanged))
        XCTAssertEqual(api.count(of: .workflows), readsBefore + 1)
        XCTAssertTrue(model.isWaiting(gate), "nothing was sent, so nothing was answered")
    }

    func testAChangedGateThatHasGoneDropsItsFailureWithIt() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        let gate = try mergeGate(model)
        api.signalResult = .failure(ControlAPIError.gateChanged("stale_phase"))
        api.onSendSignal = { api.workflowsResult = .success([]) }

        await model.decide(gate: gate, button: try approve(gate), comment: "")

        XCTAssertFalse(model.isWaiting(gate))
        XCTAssertNil(model.decisionState(for: gate))
    }

    func testARefusedOperatorTokenIsNamedAsThat() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        let gate = try mergeGate(model)
        api.signalResult = .failure(ControlAPIError.unauthorized)

        await model.decide(gate: gate, button: try approve(gate), comment: "")

        XCTAssertEqual(model.decisionState(for: gate), .failed(.tokenRejected))
        XCTAssertTrue(model.isWaiting(gate))
    }

    func testAnInterruptedRequestIsAnUnknownOutcomeNotAFailure() async throws {
        // The request may have reached the workflow. Reading again is what settles it.
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        let gate = try mergeGate(model)
        let readsBefore = api.count(of: .workflows)
        api.signalResult = .failure(ControlAPIError.transport("lost"))

        await model.decide(gate: gate, button: try approve(gate), comment: "")

        XCTAssertEqual(model.decisionState(for: gate), .failed(.outcomeUnknown))
        XCTAssertEqual(api.count(of: .workflows), readsBefore + 1)
    }

    func testTheOrchestratorsOwnWordsAreKeptForARefusal() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        let gate = try mergeGate(model)
        api.signalResult = .failure(ControlAPIError.refused(status: 400, message: "run_required"))

        await model.decide(gate: gate, button: try approve(gate), comment: "")

        XCTAssertEqual(model.decisionState(for: gate), .failed(.refused("run_required")))
    }

    func testAMissingRequiredCommentNeverReachesTheNetwork() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        let gate = try mergeGate(model)
        let reject = try XCTUnwrap(gate.signal.buttons.first { $0.label == "Reject" })

        let sent = await model.decide(gate: gate, button: reject, comment: "  ")

        XCTAssertFalse(sent)
        XCTAssertEqual(model.decisionState(for: gate), .failed(.commentRequired))
        XCTAssertTrue(api.sentSignals.isEmpty)
    }

    func testAReadOnlyConnectionSaysSoAndSendsNothingThatChangesState() async throws {
        let api = try makeAPI()
        api.signalResult = .failure(ControlAPIError.readOnly)
        let model = makeModel(api, connection: .readOnlyFixture)
        await model.refresh()
        XCTAssertFalse(model.canDecide)
        let gate = try mergeGate(model)

        await model.decide(gate: gate, button: try approve(gate), comment: "")

        XCTAssertEqual(model.decisionState(for: gate), .failed(.readOnly))
        XCTAssertTrue(model.isWaiting(gate))
    }

    func testAFailureCanBeClearedBeforeTryingAgain() async throws {
        let api = try makeAPI()
        let model = makeModel(api)
        await model.refresh()
        let gate = try mergeGate(model)
        api.signalResult = .failure(ControlAPIError.unauthorized)
        await model.decide(gate: gate, button: try approve(gate), comment: "")

        model.clearDecisionFailure(for: gate)

        XCTAssertNil(model.decisionState(for: gate))
    }

    // MARK: - The loops

    func testStartingReadsOnceAndAttachesTheSocket() async throws {
        let api = try makeAPI()
        let stream = FakeControlLiveStream(scripts: [[.ended]])
        var sleeps = 0
        let model = ControlPlaneModel(
            api: api,
            stream: stream,
            connection: .fixture,
            sleep: { _ in
                sleeps += 1
                // Park both loops after their first pass, so the test observes exactly one.
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            },
            now: { Date(timeIntervalSince1970: 1_000) },
            randomFraction: { 0 }
        )

        model.start()
        model.start()

        for _ in 0..<FakeFleetAPI.maxGateYields where sleeps < 2 {
            await Task.yield()
        }
        model.stop()

        XCTAssertEqual(api.count(of: .agents), 1, "a second start must not start a second loop")
        XCTAssertEqual(stream.attachCount, 1)
        XCTAssertEqual(model.agents.count, 4)
    }
}
