import XCTest
@testable import Phleet

/// The small pure pieces under the control plane's newer screens: searching what was read,
/// linking a run to its pull request, choosing what to show beside a decision, and reading
/// schedules and memories off the wire.
final class ControlExtrasTests: XCTestCase {

    // MARK: - Search

    private let builder = FleetAgent(
        agentName: "adev",
        displayName: "Builder",
        model: "opus",
        role: "developer",
        currentTask: "Implementing pull request 42",
        effectiveStatus: "busy"
    )

    func testAnEmptySearchMatchesEverything() {
        XCTAssertTrue(ListSearch.matches(builder, query: ""))
        XCTAssertTrue(ListSearch.matches(builder, query: "   "))
    }

    func testEveryWordMustBeFoundSomewhereInAnyOrder() {
        XCTAssertTrue(ListSearch.matches(builder, query: "42 builder"))
        XCTAssertTrue(ListSearch.matches(builder, query: "DEVELOPER"))
        XCTAssertFalse(ListSearch.matches(builder, query: "builder reviewer"))
    }

    func testARunIsFoundByItsSubjectItsTypeAndItsPhase() {
        let run = WorkflowRun(
            workflowId: "pr-42",
            runId: "run-1",
            workflowType: "UwePrImplementationWorkflow",
            namespace: "fleet",
            prNumber: 42,
            repo: "example/project",
            phase: "merge-approval"
        )

        XCTAssertTrue(ListSearch.matches(run, query: "project 42"))
        XCTAssertTrue(ListSearch.matches(run, query: "implementation"))
        XCTAssertTrue(ListSearch.matches(run, query: "merge"))
        XCTAssertFalse(ListSearch.matches(run, query: "design"))
    }

    // MARK: - Links

    private func run(repo: String?, pr: Int? = nil, issue: Int? = nil) -> WorkflowRun {
        WorkflowRun(
            workflowId: "w",
            runId: "r",
            workflowType: "T",
            namespace: "fleet",
            issueNumber: issue,
            prNumber: pr,
            repo: repo
        )
    }

    func testARunLinksToItsPullRequestElseItsIssue() {
        XCTAssertEqual(
            RunLinks.webURL(for: run(repo: "example/project", pr: 42, issue: 7))?.absoluteString,
            "https://github.com/example/project/pull/42"
        )
        XCTAssertEqual(
            RunLinks.webURL(for: run(repo: "example/project", issue: 7))?.absoluteString,
            "https://github.com/example/project/issues/7"
        )
    }

    func testARunWithNoNumberOrNoRepositoryHasNoLink() {
        XCTAssertNil(RunLinks.webURL(for: run(repo: "example/project")))
        XCTAssertNil(RunLinks.webURL(for: run(repo: nil, pr: 42)))
        XCTAssertNil(RunLinks.webURL(for: run(repo: "  ", pr: 42)))
    }

    func testARepositoryThatIsNotOwnerAndNameIsNeverMadeIntoAPath() {
        for repository in [
            "project",
            "example/project/extra",
            "example/../other",
            "example/pro ject",
            "example/project?tab=x",
            "example/project#frag",
            "/project",
            "example/"
        ] {
            XCTAssertNil(
                RunLinks.webURL(for: run(repo: repository, pr: 1)),
                "\(repository) must not produce a link"
            )
        }
    }

    // MARK: - What led to a gate

    func testTheGateDigestKeepsTheNewestTellingEntriesNewestFirst() {
        let events = [
            WorkflowEvent(eventId: 1, eventType: "WorkflowStarted"),
            WorkflowEvent(eventId: 2, eventType: "TimerStarted"),
            WorkflowEvent(eventId: 3, eventType: "ActivityCompleted", agent: "builder", outputSummary: "Built"),
            WorkflowEvent(eventId: 4, eventType: "ActivityScheduled", agent: "reviewer"),
            WorkflowEvent(eventId: 5, eventType: "ActivityFailed", agent: "reviewer", failureMessage: "No"),
            WorkflowEvent(eventId: 6, eventType: "SignalReceived", signalName: "design-approval")
        ]

        XCTAssertEqual(GateActivityDigest.recent(from: events, limit: 2).map(\.eventId), [6, 5])
        XCTAssertEqual(GateActivityDigest.recent(from: events).map(\.eventId), [6, 5, 3])
    }

    func testAHistoryOfOnlyBookkeepingIsShownRatherThanNothing() {
        let events = [
            WorkflowEvent(eventId: 1, eventType: "WorkflowStarted"),
            WorkflowEvent(eventId: 2, eventType: "TimerStarted")
        ]
        XCTAssertEqual(GateActivityDigest.recent(from: events).map(\.eventId), [2, 1])
    }

    // MARK: - Decoding

    func testSchedulesAreReadLenientlyAndOneThatCannotBeAddressedIsDropped() throws {
        let json = """
        [
          {"scheduleId":"nightly","namespace":"fleet","workflowType":"UweNightly",
           "cronExpression":"0 3 * * *","paused":true,"memo":"Nightly"},
          {"scheduleId":"bare","namespace":"fleet","paused":"yes","unknown":1},
          {"namespace":"fleet"},
          {"scheduleId":"","namespace":"fleet"}
        ]
        """
        let list = try JSONDecoder().decode(LossyList<FleetSchedule>.self, from: Data(json.utf8))

        XCTAssertEqual(list.droppedCount, 2)
        XCTAssertEqual(
            list.items,
            [
                FleetSchedule(
                    scheduleId: "nightly",
                    namespace: "fleet",
                    workflowType: "UweNightly",
                    cronExpression: "0 3 * * *",
                    isPaused: true,
                    note: "Nightly"
                ),
                // A field of the wrong shape costs that field, not the schedule.
                FleetSchedule(scheduleId: "bare", namespace: "fleet")
            ]
        )
    }

    func testAMemoryWithNoTitleIsListedUnderItsIdentifier() throws {
        let json = """
        [{"id":"m-1","title":"  ","project":"fleet","type":"reference","tags":["a"],"snippet":"s"},
         {"title":"no id"}]
        """
        let list = try JSONDecoder().decode(LossyList<MemorySearchResult>.self, from: Data(json.utf8))

        XCTAssertEqual(list.droppedCount, 1)
        XCTAssertEqual(list.items.first?.title, "m-1")
        XCTAssertEqual(list.items.first?.tags, ["a"])
    }

    func testAMemoryDocumentNeedsItsContent() throws {
        let whole = #"{"id":"m-1","title":"T","content":"C","agent":"builder","tags":[]}"#
        XCTAssertEqual(
            try JSONDecoder().decode(MemoryDocument.self, from: Data(whole.utf8)),
            MemoryDocument(id: "m-1", title: "T", content: "C", agent: "builder")
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(MemoryDocument.self, from: Data(#"{"id":"m-1"}"#.utf8))
        )
    }

    // MARK: - Requests

    func testTheNewRoutesEscapeWhatTheyAreGiven() {
        XCTAssertEqual(
            ControlRequest.terminateRunPath(namespace: "fleet", workflowId: "design/synthetic 7"),
            "/api/workflows/fleet/terminate/design%2Fsynthetic%207"
        )
        XCTAssertEqual(
            ControlRequest.restartRunPath(namespace: "fleet", workflowId: "pr-42"),
            "/api/workflows/fleet/restart/pr-42"
        )
        XCTAssertEqual(
            ControlRequest.scheduleActionPath(
                namespace: "fleet",
                scheduleId: "nightly/build",
                action: .trigger
            ),
            "/api/schedules/fleet/trigger/nightly%2Fbuild"
        )
        XCTAssertEqual(ControlRequest.memoryPath(id: "a b"), "/api/memory/a%20b")
        XCTAssertEqual(
            ControlRequest.agentActionPath(agentName: "planner", action: .reprovision),
            "/api/agents/planner/reprovision"
        )
    }

    func testAMemorySearchPutsOnlyItsWordsInTheURL() throws {
        let request = try ControlRequest.make(
            connection: .fixture,
            method: "GET",
            percentEncodedPath: ControlRequest.memorySearchPath,
            query: [URLQueryItem(name: "q", value: "how do we deploy?")]
        )
        let url = try XCTUnwrap(request.url?.absoluteString)

        XCTAssertTrue(url.hasPrefix("https://fleet.example.invalid/api/memory/search?q="))
        XCTAssertFalse(url.contains("access-token-1"), "the access token never rides in a URL")
        XCTAssertFalse(url.contains("client-secret-1"), "the service token never rides in a URL")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token-1")
    }
}
