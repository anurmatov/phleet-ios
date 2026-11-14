import XCTest
@testable import Phleet

/// Acting on an agent, and reading its log.
@MainActor
final class ControlActionsTests: XCTestCase {

    private func makeModel(
        _ api: FakeControlAPI,
        connection: ControlConnection = .fixture
    ) -> ControlPlaneModel {
        ControlPlaneModel(
            api: api,
            stream: FakeControlLiveStream(),
            connection: connection,
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 1_000) },
            randomFraction: { 0 }
        )
    }

    // MARK: - Requests

    func testAnAgentActionIsAWriteToThatAgentsRoute() throws {
        let request = try ControlRequest.make(
            connection: .fixture,
            method: "POST",
            percentEncodedPath: ControlRequest.agentActionPath(agentName: "builder", action: .restart)
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://fleet.example.invalid/api/agents/builder/restart"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token-1")
    }

    func testEachActionHasItsOwnRoute() {
        XCTAssertEqual(
            AgentAction.allCases.map { ControlRequest.agentActionPath(agentName: "a b", action: $0) },
            [
                "/api/agents/a%20b/cancel",
                "/api/agents/a%20b/restart",
                "/api/agents/a%20b/stop",
                "/api/agents/a%20b/start"
            ]
        )
    }

    func testCancellingARunNamesTheRunAndCarriesNoSecretInTheURL() throws {
        let request = try ControlRequest.make(
            connection: .fixture,
            method: "POST",
            percentEncodedPath: ControlRequest.cancelRunPath(
                namespace: "fleet",
                workflowId: "design/synthetic 7"
            ),
            query: [URLQueryItem(name: "runId", value: "run-design-1")]
        )
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertEqual(
            url,
            "https://fleet.example.invalid/api/workflows/fleet/cancel/design%2Fsynthetic%207"
                + "?runId=run-design-1"
        )
        for secret in ["client-id-1", "client-secret-1", "access-token-1"] {
            XCTAssertFalse(url.contains(secret))
        }
    }

    func testTheLogSocketCarriesBothTokensInHeadersOnly() throws {
        let request = try XCTUnwrap(
            URLSessionAgentLogStream.upgradeRequest(.fixture, agentName: "builder")
        )
        XCTAssertEqual(request.url?.absoluteString, "wss://fleet.example.invalid/ws/logs/builder")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: ControlRequest.accessClientIdHeader),
            "client-id-1"
        )
        // Through the dashboard's address a socket needs a sign-in, like any read.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token-1")
    }

    func testAProblemDocumentsDetailIsReadAsTheMessage() {
        // Some routes answer a failure with a problem document rather than `{ "error": … }`.
        let body = Data(#"{"title":"An error occurred","status":500,"detail":"Failed to restart"}"#.utf8)
        XCTAssertEqual(
            URLSessionControlAPIClient.failure(status: 500, body: body),
            .refused(status: 500, message: "Failed to restart")
        )
    }

    // MARK: - What is offered

    func testActionsOfferedFollowTheAgentsState() {
        XCTAssertEqual(
            AgentAction.available(for: .working),
            [.cancelTask, .restart, .stop, .reprovision]
        )
        XCTAssertEqual(AgentAction.available(for: .idle), [.restart, .stop, .reprovision])
        // "No heartbeat" may mean hung or stopped. A restart is right for both.
        XCTAssertEqual(AgentAction.available(for: .down), [.restart, .stop, .reprovision])
        XCTAssertEqual(AgentAction.available(for: .stale), [.restart, .stop, .reprovision])
        // Reprovisioning brings a stopped agent up as well as applying its saved settings.
        XCTAssertEqual(AgentAction.available(for: .stopped), [.start, .reprovision])
        // Never provisioned: there is no container to recreate, and that stays on the dashboard.
        XCTAssertTrue(AgentAction.available(for: .notProvisioned).isEmpty)
    }

    func testOnlyStartingIsNotDisruptive() {
        XCTAssertEqual(AgentAction.allCases.filter { !$0.isDisruptive }, [.start])
    }

    // MARK: - Performing

    func testAnAcceptedActionIsRecordedAsRequestedAndTheFleetIsReadAgain() async {
        let api = FakeControlAPI()
        api.agentsResult = .success([FleetAgent(agentName: "planner", effectiveStatus: "dead")])
        let model = makeModel(api)
        await model.refresh()
        api.onAgentAction = {
            api.agentsResult = .success([FleetAgent(agentName: "planner", effectiveStatus: "idle")])
        }

        let accepted = await model.perform(.restart, on: "planner")

        XCTAssertTrue(accepted)
        XCTAssertEqual(api.count(of: .agentAction(agentName: "planner", action: .restart)), 1)
        XCTAssertEqual(model.agentActionState(for: "planner"), .requested(.restart))
        // The agent's own state is the evidence that it worked, so it is read straight away.
        XCTAssertEqual(model.agent(named: "planner")?.health, .idle)
    }

    func testAFailedActionNamesWhy() async {
        let cases: [(ControlAPIError, ControlPlaneModel.ActionFailure)] = [
            (.unauthorized, .tokenRejected),
            (.accessDenied, .accessDenied),
            (.transport("lost"), .outcomeUnknown),
            (.refused(status: 500, message: "Failed to restart"), .refused("Failed to restart"))
        ]
        for (error, expected) in cases {
            let api = FakeControlAPI()
            api.agentActionResult = .failure(error)
            let model = makeModel(api)

            let accepted = await model.perform(.stop, on: "builder")

            XCTAssertFalse(accepted, "\(error)")
            XCTAssertEqual(model.agentActionState(for: "builder"), .failed(.stop, expected), "\(error)")
        }
    }

    func testAnUnknownOutcomeIsSettledByReadingAgain() async {
        let api = FakeControlAPI()
        api.agentActionResult = .failure(ControlAPIError.transport("lost"))
        let model = makeModel(api)

        await model.perform(.restart, on: "builder")

        XCTAssertEqual(api.count(of: .agents), 1)
    }

    func testAStateCanBeClearedBeforeChoosingAgain() async {
        let api = FakeControlAPI()
        let model = makeModel(api)
        await model.perform(.restart, on: "builder")

        model.clearAgentActionState(for: "builder")

        XCTAssertNil(model.agentActionState(for: "builder"))
    }

    // MARK: - The log tail

    func testAFrameIsSplitIntoLines() {
        var tail = LogTail()
        tail.append("one\ntwo\n")
        tail.append("three")

        XCTAssertEqual(tail.lines.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(tail.lines.map(\.number), [1, 2, 3])
    }

    func testABlankLineInsideAFrameIsKept() {
        var tail = LogTail()
        tail.append("one\n\ntwo\n")
        XCTAssertEqual(tail.lines.map(\.text), ["one", "", "two"])
    }

    func testCarriageReturnsAreRemoved() {
        var tail = LogTail()
        tail.append("one\r\ntwo\r\n")
        XCTAssertEqual(tail.lines.map(\.text), ["one", "two"])
    }

    func testOnlyTheNewestLinesAreKeptAndTheDropIsCounted() {
        var tail = LogTail(capacity: 3)
        tail.append("1\n2\n3\n4\n5")

        XCTAssertEqual(tail.lines.map(\.text), ["3", "4", "5"])
        XCTAssertEqual(tail.droppedCount, 2)
        // Identity survives lines falling off the front.
        XCTAssertEqual(tail.lines.map(\.number), [3, 4, 5])
    }

    func testClearingStartsAgainFromTheBeginning() {
        var tail = LogTail(capacity: 2)
        tail.append("1\n2\n3")
        tail.removeAll()
        tail.append("a")

        XCTAssertEqual(tail.lines.map(\.text), ["a"])
        XCTAssertEqual(tail.lines.map(\.number), [1])
        XCTAssertEqual(tail.droppedCount, 0)
    }

    // MARK: - The log model

    func testTheLogModelFollowsUntilTheSocketEnds() {
        let model = AgentLogModel(
            stream: FakeAgentLogStream(),
            connection: .fixture,
            agentName: "builder"
        )
        XCTAssertEqual(model.state, .connecting)

        model.apply(.text("one\ntwo"))
        XCTAssertEqual(model.state, .following)

        model.apply(.ended)
        XCTAssertEqual(model.state, .ended)
        XCTAssertEqual(model.tail.lines.map(\.text), ["one", "two"], "what arrived stays on screen")
    }

    func testStartingAsksForThatAgentsLog() async {
        let stream = FakeAgentLogStream(script: [.text("hello"), .ended])
        let model = AgentLogModel(stream: stream, connection: .fixture, agentName: "builder")

        model.start()
        for _ in 0..<FakeFleetAPI.maxGateYields where model.state != .ended {
            await Task.yield()
        }

        XCTAssertEqual(stream.agentNames, ["builder"])
        XCTAssertEqual(model.tail.lines.map(\.text), ["hello"])
        XCTAssertEqual(model.state, .ended)
    }

    func testEnvironmentBuildsALogModelOnlyWhenSignedIn() async {
        let store = InMemoryCredentialStore()
        let environment = AppEnvironment(
            credentialStore: store,
            legacyCredentialStore: InMemoryLegacyCredentialStore(),
            api: FakeFleetAPI(),
            stream: FakeConversationStream(),
            controlAPI: FakeControlAPI(),
            controlStream: FakeControlLiveStream(),
            controlLogStream: FakeAgentLogStream(),
            launchArguments: [],
            launchEnvironment: [:]
        )
        XCTAssertNil(environment.makeAgentLogModel(agentName: "builder"))
        XCTAssertNil(environment.runs)

        try? store.save(.fixture)
        environment.finishSetup(
            SetupOutcome(
                credential: .fixture,
                tokens: AccessTokenHolder(credentialStore: store, clock: TestClock()) { _ in
                    MintTokenResponse(accessToken: "access-token-1", expiresInSeconds: 900)
                }
            )
        )
        XCTAssertEqual(environment.makeAgentLogModel(agentName: "builder")?.agentName, "builder")
        XCTAssertNotNil(environment.runs)

        await environment.signOut()
        XCTAssertNil(environment.runs, "the runs model is torn down with the sign-in")
        XCTAssertNil(environment.makeAgentLogModel(agentName: "builder"))
    }

    func testTheLogSocketIsOpenedSignedIn() async {
        let base = FakeAgentLogStream(script: [.text("hello"), .ended])
        let store = InMemoryCredentialStore(credential: .fixture)
        let tokens = AccessTokenHolder(credentialStore: store, clock: TestClock()) { _ in
            MintTokenResponse(accessToken: "access-token-1", expiresInSeconds: 900)
        }
        let model = AgentLogModel(
            stream: SignedInAgentLogStream(base: base, tokens: tokens),
            connection: .unsignedFixture,
            agentName: "builder"
        )

        model.start()
        for _ in 0..<FakeFleetAPI.maxGateYields where model.state != .ended {
            await Task.yield()
        }

        XCTAssertEqual(base.agentNames, ["builder"])
        XCTAssertEqual(base.accessTokens, ["access-token-1"])
        XCTAssertEqual(model.tail.lines.map(\.text), ["hello"])
    }
}
