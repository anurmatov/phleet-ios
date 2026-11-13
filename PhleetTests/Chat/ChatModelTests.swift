import XCTest
@testable import Phleet

/// Who can be chatted with, and one thread with each.
@MainActor
final class ChatModelTests: XCTestCase {

    private let builder = ChatAgent(agentName: "builder", displayName: "Builder")
    private let reviewer = ChatAgent(agentName: "reviewer", displayName: "Reviewer")

    private func makeModel(
        control: FakeControlAPI = FakeControlAPI(),
        chat: FakeFleetAPI = FakeFleetAPI()
    ) -> ChatModel {
        let store = InMemoryCredentialStore(credential: .fixture)
        let tokens = AccessTokenHolder(credentialStore: store, clock: TestClock()) { _ in
            MintTokenResponse(accessToken: "access-token-1", expiresInSeconds: 900)
        }
        return ChatModel(
            api: control,
            connection: .unsignedFixture,
            chatAPI: chat,
            tokens: tokens
        ) { agent, limits in
            ConversationModel(
                api: chat,
                stream: FakeConversationStream(),
                tokens: tokens,
                origin: ControlConnection.unsignedFixture.origin,
                agent: agent,
                clientInstanceId: "instance-1",
                limits: limits
            )
        }
    }

    // MARK: - The list

    func testTheChatEnabledAgentsAreListed() async {
        let control = FakeControlAPI()
        control.chatAgentsResult = .success(ChatAgentList(available: true, agents: [builder, reviewer]))
        let model = makeModel(control: control)
        XCTAssertEqual(model.state, .loading)

        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.agents, [builder, reviewer])
        XCTAssertEqual(control.calls, [.chatAgents])
    }

    func testAServerWithoutChatSaysSo() async {
        let control = FakeControlAPI()
        control.chatAgentsResult = .success(ChatAgentList(available: false, agents: []))
        let model = makeModel(control: control)

        await model.load()

        XCTAssertEqual(model.state, .notAvailable)
        XCTAssertTrue(model.agents.isEmpty)
    }

    func testNoAgentWithChatOnIsAnEmptyListNotAFailure() async {
        let model = makeModel()

        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertTrue(model.agents.isEmpty)
    }

    func testAFailedReadKeepsWhatWasListedAndSaysWhy() async {
        let control = FakeControlAPI()
        control.chatAgentsResult = .success(ChatAgentList(available: true, agents: [builder]))
        let model = makeModel(control: control)
        await model.load()

        control.chatAgentsResult = .failure(ControlAPIError.transport("offline"))
        await model.load()

        XCTAssertEqual(model.state, .failed(.unreachable))
        XCTAssertEqual(model.agents, [builder])
    }

    func testAReadReplacesTheListSoAnAgentWhoseChatWasTurnedOffIsGone() async {
        let control = FakeControlAPI()
        control.chatAgentsResult = .success(ChatAgentList(available: true, agents: [builder, reviewer]))
        let model = makeModel(control: control)
        await model.load()

        control.chatAgentsResult = .success(ChatAgentList(available: true, agents: [reviewer]))
        await model.load()

        XCTAssertEqual(model.agents, [reviewer])
    }

    // MARK: - Threads

    func testEachAgentHasOneThreadForTheLifeOfTheSignIn() {
        let model = makeModel()

        let first = model.conversation(for: builder)
        let again = model.conversation(for: builder)
        let other = model.conversation(for: reviewer)

        XCTAssertTrue(first === again, "leaving a thread and coming back keeps its transcript")
        XCTAssertFalse(first === other)
        XCTAssertEqual(first.agent, builder)
        XCTAssertEqual(other.agent, reviewer)
    }

    func testTheChatServicesLimitsAreReadOnceAndSizeTheThreads() async {
        let chat = FakeFleetAPI()
        let limits = SessionLimits(
            inboundTextBytes: 1024,
            catchUpLimitDefault: 50,
            catchUpLimitMax: 100,
            identifierMaxLength: 128,
            outboundBufferEvents: 64
        )
        chat.sessionResults = [
            .success(SessionResponse(
                principalId: "owner",
                limits: limits,
                protocolVersion: ProtocolVersion.current
            ))
        ]
        let model = makeModel(chat: chat)

        await model.load()
        await model.load()

        XCTAssertEqual(model.limits, limits)
        XCTAssertEqual(chat.calls.filter { $0 == .session }.count, 1)
        XCTAssertEqual(chat.accessTokensPresented, ["access-token-1"])
        XCTAssertEqual(model.conversation(for: builder).limits, limits)
    }

    func testLimitsThatCannotBeReadLeaveTheDocumentedDefaults() async {
        let chat = FakeFleetAPI()
        chat.sessionResults = [.failure(FleetAPIError.unexpectedStatus(502))]
        let model = makeModel(chat: chat)

        await model.load()

        XCTAssertEqual(model.state, .loaded, "chat works within the defaults")
        XCTAssertEqual(model.limits, .documentedDefaults)
    }

    // MARK: - Reading the orchestrator's answer

    func testTheListIsReadAsTheOrchestratorWritesIt() throws {
        let json = Data(
            #"""
            {"available":true,"agents":[
              {"agentName":"builder","displayName":"Builder"},
              {"agentName":"reviewer","displayName":"  "},
              {"agentName":"planner"},
              {"displayName":"No name"},
              {"agentName":""},
              {"agentName":"tester","displayName":"Tester","somethingNew":1}
            ]}
            """#.utf8
        )
        let list = try JSONDecoder().decode(ChatAgentList.self, from: json)

        XCTAssertTrue(list.available)
        XCTAssertEqual(
            list.agents,
            [
                ChatAgent(agentName: "builder", displayName: "Builder"),
                // A blank or missing display name falls back to the name, as the orchestrator's does.
                ChatAgent(agentName: "reviewer", displayName: "reviewer"),
                ChatAgent(agentName: "planner", displayName: "planner"),
                ChatAgent(agentName: "tester", displayName: "Tester")
            ],
            "an entry with no name cannot be chatted with, and is dropped"
        )
    }

    func testAnAnswerThatDoesNotSayWhetherChatIsAvailableIsNotThisRoutes() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(ChatAgentList.self, from: Data(#"{"agents":[]}"#.utf8))
        )
    }
}
