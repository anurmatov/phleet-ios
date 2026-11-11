import SwiftUI
import XCTest
@testable import Phleet

/// The control-plane rows, rendered across the Dynamic Type range.
///
/// Same rule as `DynamicTypeRenderingTests`: a zero-height render is the signal that a row
/// collapsed or failed to lay out at all, and the accessibility sizes are where that happens.
@MainActor
final class ControlRenderingTests: XCTestCase {

    private let sizes: [DynamicTypeSize] = [
        .xSmall, .medium, .xxxLarge,
        .accessibility1, .accessibility3, .accessibility5
    ]

    private func assertRenders(
        _ view: some View,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for size in sizes {
            let renderer = ImageRenderer(
                content: view
                    .environment(\.dynamicTypeSize, size)
                    .frame(width: 390)
            )
            renderer.scale = 1

            guard let image = renderer.uiImage else {
                XCTFail("\(label) produced no render at \(size)", file: file, line: line)
                continue
            }
            XCTAssertGreaterThan(
                image.size.height,
                0,
                "\(label) collapsed to zero height at \(size)",
                file: file,
                line: line
            )
        }
    }

    private let gate = PendingGate(
        run: WorkflowRun(
            workflowId: "pr-synthetic-42",
            runId: "run-1",
            workflowType: "UwePrImplementationWorkflow",
            namespace: "fleet",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            prNumber: 42,
            repo: "example/a-repository-with-a-name-long-enough-to-wrap",
            phase: "merge-approval",
            gateRef: "gate-a"
        ),
        signal: SignalDefinition(
            name: "merge-approval",
            label: "merge approval",
            buttons: [SignalButton(label: "Approve Merge", payload: "{}")],
            validPhases: ["merge-approval"]
        )
    )

    func testAGateRowRendersAtEverySize() {
        assertRenders(GateRow(gate: gate), "a gate row")
    }

    func testAnAgentRowRendersInEveryState() {
        let statuses = ["busy", "idle", "stale", "dead", "offline", "not_provisioned", "novel"]
        for status in statuses {
            let agent = FleetAgent(
                agentName: "builder",
                displayName: "An agent with a display name long enough to wrap",
                currentTask: "A task description long enough to wrap onto a second line at "
                    + "ordinary sizes and well beyond it at accessibility sizes.",
                effectiveStatus: status,
                queuedCount: 3
            )
            assertRenders(AgentRow(agent: agent), "an agent row (\(status))")
        }
    }

    func testTheStatusAndUpdatedLinesRender() {
        assertRenders(
            FleetStatusRow(symbolName: "wifi.slash", messageKey: "fleet.status.unreachable"),
            "the status row"
        )
        for isLive in [true, false] {
            assertRenders(
                FleetUpdatedLine(lastUpdated: Date(timeIntervalSince1970: 1_700_000_000), isLive: isLive),
                "the updated line"
            )
        }
    }

    func testEveryDecisionFailureRenders() {
        let failures: [ControlPlaneModel.DecisionFailure] = [
            .readOnly, .tokenRejected, .accessDenied, .gateChanged, .commentRequired,
            .outcomeUnknown, .refused(nil), .refused("run_required")
        ]
        for failure in failures {
            assertRenders(GateFailureRow(failure: failure), "a decision failure (\(failure))")
        }
    }

    // MARK: - Wording

    func testEveryHealthStateHasItsOwnWordsAndSymbol() {
        let states: [AgentHealth] = [
            .down, .stale, .working, .idle, .stopped, .notProvisioned, .unknown("")
        ]
        for state in states {
            XCTAssertNotEqual(
                state.localizedLabel,
                state.labelKey,
                "\(state.labelKey) is missing from Localizable.xcstrings"
            )
        }
        // State is never carried by colour alone: the three that share a tint differ in shape.
        XCTAssertEqual(Set(states.map(\.symbolName)).count, states.count)
        XCTAssertEqual(Set(states.map(\.localizedLabel)).count, states.count)
    }

    func testAnUnrecognisedStatusIsShownAsTheOrchestratorSpelledIt() {
        XCTAssertEqual(AgentHealth.unknown("quarantined").localizedLabel, "quarantined")
    }

    func testARunIsDescribedByItsRepositoryAndReference() {
        XCTAssertEqual(
            RunSubject.text(for: gate.run),
            "example/a-repository-with-a-name-long-enough-to-wrap · PR #42"
        )

        let issueOnly = WorkflowRun(
            workflowId: "w1",
            runId: "r1",
            workflowType: "T",
            namespace: "fleet",
            issueNumber: 12345,
            repo: "example/project"
        )
        // An identifier, not a quantity: no grouping separator.
        XCTAssertEqual(RunSubject.text(for: issueOnly), "example/project · Issue #12345")

        let bare = WorkflowRun(workflowId: "w1", runId: "r1", workflowType: "T", namespace: "fleet")
        XCTAssertEqual(RunSubject.text(for: bare), "w1")
    }

    func testAGateIsHeadedByItsSignalWithACapital() {
        XCTAssertEqual(gate.heading, "Merge approval")
    }

    func testARowSpeaksAsOneSentence() {
        XCTAssertEqual(
            GateRow.spokenLabel(for: gate),
            "Merge approval. example/a-repository-with-a-name-long-enough-to-wrap · PR #42"
        )
        let agent = FleetAgent(
            agentName: "builder",
            displayName: "Builder",
            currentTask: "Implement the change",
            effectiveStatus: "busy"
        )
        XCTAssertEqual(AgentRow.spokenLabel(for: agent), "Builder. Working. Implement the change")
    }
}
