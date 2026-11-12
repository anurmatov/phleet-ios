import XCTest
@testable import Phleet

@MainActor
final class HumanInputModelTests: XCTestCase {
    private func setup(
        mode: String = "choice", connection: ControlConnection = .fixture
    ) throws -> (FakeControlAPI, ControlPlaneModel, PendingGate) {
        let api = FakeControlAPI()
        let gate = HumanInputTests.gate()
        api.workflowsResult = .success([gate.run])
        api.registryResult = .success([gate.run.workflowType: [gate.signal]])
        api.historyResult = .success(try HumanInputTests.history(mode: mode))
        return (api, ControlPlaneModel(api: api, stream: FakeControlLiveStream(), connection: connection), gate)
    }

    func testLoadingOrAbsentHistorySendsNothingIncludingRegistryBypass() async throws {
        let (api, model, gate) = try setup()
        let beforeRefresh = await model.answerHumanInput(gate: gate, value: "option_b", comment: "")
        XCTAssertFalse(beforeRefresh)
        await model.refresh()
        let beforeHistory = await model.answerHumanInput(gate: gate, value: "option_b", comment: "")
        XCTAssertFalse(beforeHistory)
        let bypass = await model.decide(gate: gate, button: SignalButton(label: "Answer", payload: "{}"), comment: "")
        XCTAssertFalse(bypass)
        XCTAssertTrue(api.sentSignals.isEmpty)
    }

    func testAllModesUseExactIdentityAndOnlyRawAnswerArguments() async throws {
        for (mode, value) in [("choice", "option_b"), ("text", "  raw\n🧭 {{literal}} "), ("approve-reject", "rejected")] {
            let (api, model, gate) = try setup(mode: mode)
            await model.refresh()
            await model.loadHumanInput(for: gate)
            XCTAssertTrue(api.calls.contains(.exactRunHistory(namespace: "fleet", workflowId: "human-input-sample", runId: "request-run")))
            let accepted = await model.answerHumanInput(gate: gate, value: value, comment: " \ncomment ")
            XCTAssertTrue(accepted)
            let body = try XCTUnwrap(api.sentSignals.first)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.payload.utf8)) as? [String: String])
            XCTAssertEqual(payload, ["Value": value, "Comment": " \ncomment "])
            XCTAssertEqual(body.expectedGateRef, gate.run.gateRef)
            XCTAssertEqual(body.runId, gate.run.runId)
            XCTAssertFalse(model.isWaiting(gate))
            let twice = await model.answerHumanInput(gate: gate, value: value, comment: "")
            XCTAssertFalse(twice)
            XCTAssertEqual(api.sentSignals.count, 1)
        }
    }

    func testReadOnlyInvalidSelectionAndLimitsSendNothing() async throws {
        for connection in [ControlConnection.fixture, .readOnlyFixture] {
            let (api, model, gate) = try setup(connection: connection)
            await model.refresh()
            await model.loadHumanInput(for: gate)
            for (value, comment) in [("", ""), ("Second\n🧭", ""), ("option_b", String(repeating: "x", count: 2001))] {
                let accepted = await model.answerHumanInput(gate: gate, value: value, comment: comment)
                XCTAssertFalse(accepted)
            }
            if connection.operatorToken == nil {
                let accepted = await model.answerHumanInput(gate: gate, value: "option_b", comment: "")
                XCTAssertFalse(accepted)
            }
            XCTAssertTrue(api.sentSignals.isEmpty)
        }
    }

    func testHistoryFailureAndMalformedInputAreNotActionable() async throws {
        let results: [Result<[WorkflowEvent], Error>] = [
            .failure(ControlAPIError.transport("offline")), .success([]),
            .success([WorkflowEvent(eventId: 1, eventType: "WorkflowStarted", inputSummary: "{}")])
        ]
        for result in results {
            let (api, model, gate) = try setup()
            api.historyResult = result
            await model.refresh()
            await model.loadHumanInput(for: gate)
            XCTAssertEqual(model.humanInputStates[gate.id], .unavailable)
            let accepted = await model.answerHumanInput(gate: gate, value: "option_b", comment: "")
            XCTAssertFalse(accepted)
            XCTAssertTrue(api.sentSignals.isEmpty)
        }
    }

    func testReplacementRunAndFailedRefreshRefuseStaleScreen() async throws {
        let (api, model, gate) = try setup()
        await model.refresh()
        await model.loadHumanInput(for: gate)
        api.workflowsResult = .failure(ControlAPIError.transport("offline"))
        await model.refresh()
        let offline = await model.answerHumanInput(gate: gate, value: "option_b", comment: "")
        XCTAssertFalse(offline)
        api.workflowsResult = .success([HumanInputTests.gate(runId: "replacement", ref: "replacement").run])
        await model.refresh()
        let replaced = await model.answerHumanInput(gate: gate, value: "option_b", comment: "")
        XCTAssertFalse(replaced)
        XCTAssertTrue(api.sentSignals.isEmpty)
    }

    func testLateHistoryCannotRebindToReplacementOrReopenedVisit() async throws {
        let (api, model, gate) = try setup()
        await model.refresh()
        var resume: CheckedContinuation<[WorkflowEvent], Error>?
        api.onExactHistory = { try await withCheckedThrowingContinuation { resume = $0 } }
        let load = Task { await model.loadHumanInput(for: gate) }
        for _ in 0..<FakeFleetAPI.maxGateYields where resume == nil { await Task.yield() }
        let pending = try XCTUnwrap(resume)
        XCTAssertEqual(model.humanInputStates[gate.id], .loading)
        let loading = await model.answerHumanInput(gate: gate, value: "option_b", comment: "")
        XCTAssertFalse(loading)
        model.apply(.frame(.workflows([])))
        model.apply(.frame(.workflows([gate.run])))
        pending.resume(returning: try HumanInputTests.history())
        await load.value
        XCTAssertNil(model.humanInput(for: gate))
        XCTAssertTrue(api.sentSignals.isEmpty)
    }

    func testUnknownSendRefreshesSameRunWithoutReplay() async throws {
        let (api, model, gate) = try setup()
        await model.refresh()
        await model.loadHumanInput(for: gate)
        api.signalResult = .failure(ControlAPIError.transport("lost response"))
        let accepted = await model.answerHumanInput(gate: gate, value: "option_b", comment: "")
        XCTAssertFalse(accepted)
        XCTAssertEqual(api.sentSignals.count, 1)
        XCTAssertEqual(api.count(of: .exactRunHistory(namespace: "fleet", workflowId: "human-input-sample", runId: "request-run")), 2)
        XCTAssertEqual(model.decisionState(for: gate), .failed(.outcomeUnknown))
    }

    func testNotificationRequiresExactPendingIdentityAfterRefresh() async throws {
        let (api, model, gate) = try setup()
        let target = GateNotificationTarget(namespace: "fleet", workflowId: "human-input-sample", runId: "request-run", signal: "request-input")
        let current = await model.gateForNotification(target)
        XCTAssertEqual(current, gate)
        api.workflowsResult = .success([HumanInputTests.gate(runId: "replacement", ref: "replacement").run])
        let replacement = await model.gateForNotification(target)
        XCTAssertNil(replacement)
        XCTAssertTrue(api.sentSignals.isEmpty)
    }
}
