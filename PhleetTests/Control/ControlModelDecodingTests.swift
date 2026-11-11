import XCTest
@testable import Phleet

/// What the orchestrator sends, and what this build makes of it.
///
/// The fixtures are written from the orchestrator's serializer, not captured from a running one,
/// and each carries something a newer or sloppier server could send. The rule under test is the
/// same throughout: a bad field costs that field, a bad element costs that element, and neither
/// costs the list.
final class ControlModelDecodingTests: XCTestCase {

    // MARK: - Agents

    func testAnAgentListKeepsEveryAgentItCanName() throws {
        let agents = try ControlFixture.agents()
        XCTAssertEqual(agents.map(\.agentName), ["builder", "reviewer", "planner", "spare"])
    }

    func testTheUnnamedEntryIsCountedAsDroppedRatherThanFailingTheList() throws {
        let list = try JSONDecoder().decode(
            LossyList<FleetAgent>.self,
            from: ControlFixture.data("agents")
        )
        XCTAssertEqual(list.items.count, 4)
        XCTAssertEqual(list.droppedCount, 1)
    }

    func testAnAgentReadsTheFieldsAGlanceNeeds() throws {
        let builder = try XCTUnwrap(ControlFixture.agents().first { $0.agentName == "builder" })

        XCTAssertEqual(builder.title, "Builder")
        XCTAssertEqual(builder.model, "example-model")
        XCTAssertEqual(builder.role, "developer")
        XCTAssertEqual(builder.taskSummary, "Implement the synthetic change")
        XCTAssertEqual(builder.queuedCount, 2)
        XCTAssertEqual(builder.priorityQueuedCount, 1)
        XCTAssertEqual(builder.backgroundTaskCount, 2)
        XCTAssertEqual(builder.version, "1.2.3")
        XCTAssertEqual(builder.health, .working)
        XCTAssertNotNil(builder.lastSeen)
    }

    func testAnAgentWithNoDisplayNameIsTitledByItsName() throws {
        let reviewer = try XCTUnwrap(ControlFixture.agents().first { $0.agentName == "reviewer" })
        XCTAssertEqual(reviewer.title, "reviewer")
        XCTAssertNil(reviewer.taskSummary)
        XCTAssertEqual(reviewer.health, .idle)
    }

    func testAFieldOfTheWrongTypeCostsOnlyThatField() throws {
        // `queuedCount` is a string and `lastSeen` is not a timestamp. Both agents survive.
        let agents = try ControlFixture.agents()
        let planner = try XCTUnwrap(agents.first { $0.agentName == "planner" })
        XCTAssertEqual(planner.queuedCount, 0)
        XCTAssertEqual(planner.health, .down)

        let spare = try XCTUnwrap(agents.first { $0.agentName == "spare" })
        XCTAssertNil(spare.lastSeen)
        XCTAssertEqual(spare.health, .notProvisioned)
    }

    // MARK: - Health

    func testHealthIsDerivedFromTheEffectiveStatus() {
        XCTAssertEqual(AgentHealth.derive(effectiveStatus: "dead", currentTask: "x"), .down)
        XCTAssertEqual(AgentHealth.derive(effectiveStatus: "stale", currentTask: nil), .stale)
        XCTAssertEqual(AgentHealth.derive(effectiveStatus: "busy", currentTask: "x"), .working)
        XCTAssertEqual(AgentHealth.derive(effectiveStatus: "active", currentTask: "  "), .idle)
        XCTAssertEqual(AgentHealth.derive(effectiveStatus: "idle", currentTask: nil), .idle)
        XCTAssertEqual(AgentHealth.derive(effectiveStatus: "offline", currentTask: nil), .stopped)
        XCTAssertEqual(
            AgentHealth.derive(effectiveStatus: "not_provisioned", currentTask: nil),
            .notProvisioned
        )
    }

    func testAnUnrecognisedStatusIsKeptAsItselfAndNeverReadAsHealthy() {
        let health = AgentHealth.derive(effectiveStatus: "quarantined", currentTask: "x")
        XCTAssertEqual(health, .unknown("quarantined"))
        XCTAssertNotEqual(health, .working)
        XCTAssertNotEqual(health, .idle)

        XCTAssertEqual(AgentHealth.derive(effectiveStatus: nil, currentTask: nil), .unknown(""))
    }

    func testAgentsThatNeedAttentionSortFirst() throws {
        let ordered = try ControlFixture.agents().sorted(by: FleetAgent.glanceOrder)
        // down, then working, then idle, then never provisioned.
        XCTAssertEqual(ordered.map(\.agentName), ["planner", "builder", "reviewer", "spare"])
    }

    // MARK: - Workflows

    func testARunThatCannotBeAddressedIsDropped() throws {
        let runs = try ControlFixture.runs()
        XCTAssertEqual(runs.count, 5)
        XCTAssertFalse(runs.contains { $0.workflowId.hasPrefix("a-run-with-no-run-id") })
    }

    func testARunReadsItsGateIdentity() throws {
        let run = try XCTUnwrap(ControlFixture.runs().first { $0.workflowId == "pr-synthetic-42" })
        XCTAssertEqual(run.runId, "run-merge-1")
        XCTAssertEqual(run.workflowType, "UwePrImplementationWorkflow")
        XCTAssertEqual(run.namespace, "fleet")
        XCTAssertEqual(run.phase, "merge-approval")
        XCTAssertEqual(run.gateRef, "gate-synthetic-a")
        XCTAssertEqual(run.prNumber, 42)
        XCTAssertEqual(run.issueNumber, 41)
        XCTAssertEqual(run.repo, "example/project")
        XCTAssertTrue(run.isRunning)
    }

    // MARK: - Signals

    func testTheRegistryReadsButtonsAndPhases() throws {
        let registry = try ControlFixture.registry()
        let merge = try XCTUnwrap(
            registry["UwePrImplementationWorkflow"]?.first { $0.name == "merge-approval" }
        )
        XCTAssertEqual(merge.validPhases, ["merge-approval"])
        // The fourth button has no payload and is dropped; the other three survive.
        XCTAssertEqual(merge.buttons.map(\.label), ["Approve Merge", "Request Changes", "Reject"])
        XCTAssertEqual(merge.buttons[0].payload, #"{"Decision":"approved"}"#)
        XCTAssertFalse(merge.buttons[0].requiresComment)
        XCTAssertTrue(merge.buttons[1].requiresComment)
    }

    func testASignalWithNoPhaseListReadsAsNoPhaseList() throws {
        let advisory = try XCTUnwrap(ControlFixture.registry()["ExternalAdvisoryWorkflow"]?.first)
        XCTAssertNil(advisory.validPhases)
    }

    // MARK: - Timestamps

    func testTheOrchestratorsSevenDigitFractionParses() throws {
        let parsed = try XCTUnwrap(ControlTimestamp.parse("2026-01-15T10:30:05.1234567+00:00"))
        let whole = try XCTUnwrap(ControlTimestamp.parse("2026-01-15T10:30:05+00:00"))
        XCTAssertEqual(parsed.timeIntervalSince(whole), 0.1234567, accuracy: 0.000_001)
    }

    func testAnOffsetIsHonoured() throws {
        let utc = try XCTUnwrap(ControlTimestamp.parse("2026-01-15T10:00:00Z"))
        let plusTwo = try XCTUnwrap(ControlTimestamp.parse("2026-01-15T12:00:00.5+02:00"))
        XCTAssertEqual(plusTwo.timeIntervalSince(utc), 0.5, accuracy: 0.000_001)
    }

    func testSomethingThatIsNotATimestampIsNilRatherThanAGuess() {
        XCTAssertNil(ControlTimestamp.parse("not-a-timestamp"))
        XCTAssertNil(ControlTimestamp.parse("2026-01-15T10:00:00.+00:00"))
        XCTAssertNil(ControlTimestamp.parse(""))
    }

    // MARK: - Live frames

    func testABareObjectIsAnAgentFrame() throws {
        let frame = try ControlLiveFrame.decode(text: ControlFixture.text("live-agent"))
        guard case .agent(let agent)? = frame else {
            return XCTFail("a frame with no type is an agent's state")
        }
        XCTAssertEqual(agent.agentName, "reviewer")
        XCTAssertEqual(agent.health, .working)
    }

    func testAWorkflowsEnvelopeIsAWorkflowsFrame() throws {
        let frame = try ControlLiveFrame.decode(text: ControlFixture.text("live-workflows"))
        guard case .workflows(let runs)? = frame else {
            return XCTFail("a frame typed workflows carries the run list")
        }
        XCTAssertEqual(runs.map(\.workflowId), ["pr-synthetic-42"])
        XCTAssertEqual(runs.first?.phase, "merging")
    }

    func testAnEnvelopeOfAnUnknownTypeIsSkippedRatherThanFailing() throws {
        XCTAssertNil(try ControlLiveFrame.decode(text: ControlFixture.text("live-unknown-type")))
    }

    func testABareObjectThatIsNotAnAgentIsAnError() {
        XCTAssertThrowsError(try ControlLiveFrame.decode(text: #"{"somethingElse":1}"#))
        XCTAssertThrowsError(try ControlLiveFrame.decode(text: "not json"))
    }
}
