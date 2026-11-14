import XCTest
@testable import Phleet

/// The chat list beyond names: when a thread was last active, and whether it has moved on since
/// this phone last showed it.
@MainActor
final class ChatListTests: XCTestCase {

    private let builder = ChatAgent(agentName: "builder", displayName: "Builder")
    private let reviewer = ChatAgent(agentName: "reviewer", displayName: "Reviewer")

    private func makeModel(
        chat: FakeFleetAPI,
        preferences: PreferenceStore = InMemoryPreferenceStore()
    ) -> ChatModel {
        let control = FakeControlAPI()
        control.chatAgentsResult = .success(
            ChatAgentList(available: true, agents: [builder, reviewer])
        )
        let store = InMemoryCredentialStore(credential: .fixture)
        let tokens = AccessTokenHolder(credentialStore: store, clock: TestClock()) { _ in
            MintTokenResponse(accessToken: "access-token-1", expiresInSeconds: 900)
        }
        return ChatModel(
            api: control,
            connection: .unsignedFixture,
            chatAPI: chat,
            tokens: tokens,
            preferences: preferences
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

    private func threads(_ summaries: [ConversationSummary]) -> FakeFleetAPI {
        let chat = FakeFleetAPI()
        chat.conversationsResults = [
            .success(ConversationListResponse(
                conversations: summaries,
                protocolVersion: ProtocolVersion.current
            ))
        ]
        return chat
    }

    func testAThreadThatHasMovedOnSinceItWasShownIsMarked() async {
        let active = Date(timeIntervalSince1970: 1_700_000_000)
        let chat = threads([
            ConversationSummary(
                conversationId: "c-1",
                agent: "builder",
                externalRef: "main",
                nextSeq: 42,
                lastActivityAt: active
            )
        ])
        let model = makeModel(chat: chat)

        await model.load()

        XCTAssertTrue(model.hasNewActivity(builder))
        XCTAssertEqual(model.lastActivity(builder), active)
        // Never written to: nothing to mark, and no time to show.
        XCTAssertFalse(model.hasNewActivity(reviewer))
        XCTAssertNil(model.lastActivity(reviewer))
    }

    func testReadingAThreadClearsItsMarkUntilItMovesOnAgain() async {
        let chat = threads([
            ConversationSummary(conversationId: "c-1", agent: "builder", externalRef: "main", nextSeq: 42)
        ])
        let model = makeModel(chat: chat)
        await model.load()

        // The newest event is at 41: one less than the position the next will take.
        model.markSeen(builder, position: 41)
        XCTAssertFalse(model.hasNewActivity(builder))

        chat.conversationsResults = [
            .success(ConversationListResponse(
                conversations: [
                    ConversationSummary(conversationId: "c-1", agent: "builder", externalRef: "main", nextSeq: 44)
                ],
                protocolVersion: ProtocolVersion.current
            ))
        ]
        await model.load()

        XCTAssertTrue(model.hasNewActivity(builder))
    }

    func testHowFarAThreadWasReadIsRememberedAndNeverMovesBack() async {
        let preferences = InMemoryPreferenceStore()
        let chat = threads([
            ConversationSummary(conversationId: "c-1", agent: "builder", externalRef: "main", nextSeq: 42)
        ])
        let first = makeModel(chat: chat, preferences: preferences)
        first.markSeen(builder, position: 41)
        first.markSeen(builder, position: 12)

        let second = makeModel(chat: chat, preferences: preferences)
        await second.load()

        XCTAssertEqual(second.seenPositions, ["builder": 41])
        XCTAssertFalse(second.hasNewActivity(builder))
    }

    func testOnlyTheThreadBothClientsOpenIsCounted() async {
        let chat = threads([
            ConversationSummary(conversationId: "c-9", agent: "builder", externalRef: "another", nextSeq: 90)
        ])
        let model = makeModel(chat: chat)

        await model.load()

        XCTAssertFalse(model.hasNewActivity(builder))
    }

    func testAListThatCouldNotBeReadLeavesTheAgentsListedWithNoMarks() async {
        let chat = FakeFleetAPI()
        chat.conversationsResults = [.failure(FleetAPIError.transport("offline"))]
        let model = makeModel(chat: chat)

        await model.load()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.agents, [builder, reviewer])
        XCTAssertFalse(model.hasNewActivity(builder))
    }

    func testTheRowSaysHowTheAgentIsDoingAndThatThereIsSomethingNew() {
        let down = FleetAgent(agentName: "builder", displayName: "Builder", effectiveStatus: "dead")
        let working = FleetAgent(
            agentName: "builder",
            displayName: "Builder",
            currentTask: "Reviewing pull request 42",
            effectiveStatus: "busy"
        )

        XCTAssertEqual(
            ChatAgentRow.spokenLabel(for: builder, fleetAgent: down, hasNewActivity: true)
                .components(separatedBy: ". ").count,
            3
        )
        XCTAssertEqual(ChatAgentRow.spokenLabel(for: builder), "Builder")
        XCTAssertEqual(
            ChatAgentRow.caption(for: builder, fleetAgent: working),
            "Reviewing pull request 42"
        )
        XCTAssertEqual(
            ChatAgentRow.caption(for: builder, fleetAgent: down),
            AgentHealth.down.localizedLabel
        )
        // Not listed by the fleet: the name, when it differs from what the agent is called.
        XCTAssertEqual(ChatAgentRow.caption(for: builder, fleetAgent: nil), "builder")
    }

    func testConversationSummariesDecodeTheServersShape() throws {
        let json = """
        {"protocol":"\(ProtocolVersion.current)","conversations":[
          {"conversationId":"c-1","agent":"builder","externalRef":"main","nextSeq":41,
           "retainedFloorSeq":12,"lastActivityAt":"2026-11-12T10:00:00+00:00"},
          {"agent":"no id"}
        ]}
        """
        let list = try JSONDecoder().decode(ConversationListResponse.self, from: Data(json.utf8))

        XCTAssertEqual(list.conversations.count, 1)
        XCTAssertEqual(list.conversations.first?.nextSeq, 41)
        XCTAssertNotNil(list.conversations.first?.lastActivityAt)
    }
}
