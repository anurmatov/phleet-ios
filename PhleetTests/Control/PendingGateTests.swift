import XCTest
@testable import Phleet

/// Which runs are waiting for a person, and what is sent when one is answered.
final class PendingGateTests: XCTestCase {

    private func gates() throws -> [PendingGate] {
        PendingGates.derive(runs: try ControlFixture.runs(), registry: try ControlFixture.registry())
    }

    private func mergeGate() throws -> PendingGate {
        try XCTUnwrap(try gates().first { $0.signal.name == "merge-approval" })
    }

    private func button(_ label: String, at gate: PendingGate) throws -> SignalButton {
        try XCTUnwrap(gate.signal.buttons.first { $0.label == label })
    }

    // MARK: - Which runs are waiting

    func testOnlyRunningRunsInAPhaseASignalNamesAreWaiting() throws {
        // Of the five readable runs: one is in a phase no signal names, one has completed while
        // still reporting a gate phase, and one accepts a signal at any time. None of those
        // three is waiting for anyone.
        XCTAssertEqual(
            try gates().map(\.run.workflowId),
            ["design/synthetic 7", "pr-synthetic-42"]
        )
    }

    func testTheRunThatHasWaitedLongestComesFirst() throws {
        let waiting = try gates()
        XCTAssertEqual(waiting.first?.signal.name, "design-approval")
        XCTAssertEqual(waiting.last?.signal.name, "merge-approval")
    }

    func testACompletedRunIsNotWaitingEvenInAGatePhase() throws {
        XCTAssertFalse(try gates().contains { $0.run.workflowId == "pr-synthetic-30" })
    }

    func testASignalAcceptedAtAnyTimeDoesNotPutARunOnTheList() throws {
        // `validPhases: null` means the orchestrator does not say when the signal is expected.
        // Listing every such run as waiting would bury the ones that are.
        XCTAssertFalse(try gates().contains { $0.run.workflowType == "ExternalAdvisoryWorkflow" })
    }

    func testTheWorkflowTypeIsLookedUpWithoutRegardToCase() throws {
        let registry = try ControlFixture.registry()
        let run = WorkflowRun(
            workflowId: "w1",
            runId: "r1",
            workflowType: "uwedesignworkflow",
            namespace: "fleet",
            phase: "design-approval"
        )
        XCTAssertEqual(PendingGates.derive(runs: [run], registry: registry).count, 1)
    }

    func testARunWithNoPhaseIsNotWaiting() throws {
        let run = WorkflowRun(
            workflowId: "w1",
            runId: "r1",
            workflowType: "UweDesignWorkflow",
            namespace: "fleet",
            phase: nil
        )
        XCTAssertTrue(
            PendingGates.derive(runs: [run], registry: try ControlFixture.registry()).isEmpty
        )
    }

    func testASecondVisitToTheSameGateIsADifferentGate() throws {
        // The same run stopping at the same gate again is a new question: what is under review
        // changed. It must not inherit "already answered" from the first visit.
        let registry = try ControlFixture.registry()
        func visit(_ gateRef: String) -> WorkflowRun {
            WorkflowRun(
                workflowId: "pr-1",
                runId: "run-1",
                workflowType: "UwePrImplementationWorkflow",
                namespace: "fleet",
                phase: "merge-approval",
                gateRef: gateRef
            )
        }
        let first = try XCTUnwrap(PendingGates.derive(runs: [visit("a")], registry: registry).first)
        let second = try XCTUnwrap(PendingGates.derive(runs: [visit("b")], registry: registry).first)
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: - What is sent

    func testADecisionWithoutACommentSendsTheButtonsPayloadByteForByte() throws {
        let gate = try mergeGate()
        let body = try SignalRequest.body(
            gate: gate,
            button: try button("Approve Merge", at: gate),
            comment: "   "
        )

        XCTAssertEqual(body.payload, #"{"Decision":"approved"}"#)
        XCTAssertEqual(body.signalName, "merge-approval")
        XCTAssertEqual(body.workflowType, "UwePrImplementationWorkflow")
    }

    func testADecisionCarriesTheRunAndGateThatWereOnScreen() throws {
        // These two are what let the orchestrator refuse an answer to a question that is no
        // longer being asked.
        let gate = try mergeGate()
        let body = try SignalRequest.body(
            gate: gate,
            button: try button("Approve Merge", at: gate),
            comment: ""
        )
        XCTAssertEqual(body.runId, "run-merge-1")
        XCTAssertEqual(body.expectedGateRef, "gate-synthetic-a")
    }

    func testACommentIsMergedIntoThePayloadUnderTheKeyWorkflowsRead() throws {
        let gate = try mergeGate()
        let body = try SignalRequest.body(
            gate: gate,
            button: try button("Request Changes", at: gate),
            comment: "  Please split \"this\" change.\n"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(body.payload.utf8)) as? [String: String]
        )
        XCTAssertEqual(
            object,
            ["Decision": "changes_requested", "Comment": "Please split \"this\" change."]
        )
    }

    func testAButtonThatRequiresACommentRefusesAnEmptyOne() throws {
        let gate = try mergeGate()
        XCTAssertThrowsError(
            try SignalRequest.body(
                gate: gate,
                button: try button("Reject", at: gate),
                comment: " \n "
            )
        ) { error in
            XCTAssertEqual(error as? SignalRequestError, .commentRequired)
        }
    }

    func testACommentIsNeverMergedIntoAPayloadThatIsNotAnObject() {
        for payload in ["[1,2]", "\"approved\"", "not json", ""] {
            XCTAssertThrowsError(
                try SignalRequest.merging(comment: "why", into: payload),
                "\(payload) is not an object"
            ) { error in
                XCTAssertEqual(error as? SignalRequestError, .payloadNotAnObject)
            }
        }
    }

    func testTheRequestBodyEncodesTheFieldsTheOrchestratorReads() throws {
        let gate = try mergeGate()
        let body = try SignalRequest.body(
            gate: gate,
            button: try button("Approve Merge", at: gate),
            comment: ""
        )
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: String]
        )
        XCTAssertEqual(
            encoded,
            [
                "signalName": "merge-approval",
                "workflowType": "UwePrImplementationWorkflow",
                "payload": #"{"Decision":"approved"}"#,
                "runId": "run-merge-1",
                "expectedGateRef": "gate-synthetic-a"
            ]
        )
    }

    func testAGateWithNoReferenceOmitsTheExpectedReference() throws {
        let design = try XCTUnwrap(try gates().first { $0.signal.name == "design-approval" })
        let body = try SignalRequest.body(
            gate: design,
            button: try button("Approve", at: design),
            comment: ""
        )
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        )
        XCTAssertNil(encoded["expectedGateRef"])
        XCTAssertEqual(encoded["runId"] as? String, "run-design-1")
    }
}
