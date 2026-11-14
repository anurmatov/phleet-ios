import XCTest
@testable import Phleet

/// What a shortcut does without the app's screens: sign in from the stored credential, read what
/// is waiting, send one message.
final class QuickActionsTests: XCTestCase {

    private func makeActions(
        control: FakeControlAPI = FakeControlAPI(),
        chat: FakeFleetAPI = FakeFleetAPI(),
        store: InMemoryCredentialStore = InMemoryCredentialStore(credential: .fixture)
    ) -> QuickActions {
        var identifiers = ["submission-id", "idempotency-key"]
        return QuickActions(
            credentialStore: store,
            controlAPI: control,
            makeChatAPI: { _ in chat },
            newIdentifier: { identifiers.isEmpty ? "extra" : identifiers.removeFirst() }
        )
    }

    private func failure(_ operation: () async throws -> Void) async -> QuickActions.Failure? {
        do {
            try await operation()
            return nil
        } catch {
            return error as? QuickActions.Failure
        }
    }

    // MARK: - Signing in

    func testWithNoSignInNothingIsAskedOfAnyServer() async {
        let control = FakeControlAPI()
        let actions = makeActions(control: control, store: InMemoryCredentialStore())

        let failed = await failure { _ = try await actions.fleetSummary() }

        XCTAssertEqual(failed, .signedOut)
        XCTAssertTrue(control.calls.isEmpty)
    }

    func testARefusedSignInIsSaidAndTheCredentialIsLeftAlone() async {
        let control = FakeControlAPI()
        control.mintResults = [.failure(ControlAPIError.unauthorized)]
        let store = InMemoryCredentialStore(credential: .fixture)
        let actions = makeActions(control: control, store: store)

        let failed = await failure { _ = try await actions.fleetSummary() }

        XCTAssertEqual(failed, .signedOut)
        // Ending a sign-in belongs to the app's token holder, the one place allowed to.
        XCTAssertEqual(store.deleteCount, 0)
        XCTAssertNotNil(try store.load())
    }

    func testEveryReadCarriesTheTokenThatWasMinted() async throws {
        let control = FakeControlAPI()
        let actions = makeActions(control: control)

        _ = try await actions.fleetSummary()

        XCTAssertEqual(control.mintCount(), 1)
        // The mint itself goes out with no token; everything after it carries the one it minted.
        XCTAssertEqual(
            control.accessTokens,
            [nil, "access-token-1", "access-token-1", "access-token-1"]
        )
    }

    // MARK: - What is waiting

    func testTheSummaryCountsWhatIsWaitingAndNamesWhoIsDown() async throws {
        let control = FakeControlAPI()
        control.agentsResult = .success(try ControlFixture.agents())
        control.workflowsResult = .success(try ControlFixture.runs())
        control.registryResult = .success(try ControlFixture.registry())
        let expected = PendingGates.derive(
            runs: try ControlFixture.runs(),
            registry: try ControlFixture.registry()
        )
        let down = try ControlFixture.agents().filter { $0.health.needsAttention }

        let summary = try await makeActions(control: control).fleetSummary()

        XCTAssertEqual(summary.waiting.count, expected.count)
        XCTAssertFalse(summary.waiting.isEmpty, "the fixture has runs waiting at gates")
        XCTAssertEqual(Set(summary.needingAttention), Set(down.map(\.title)))
        XCTAssertEqual(summary.agentCount, try ControlFixture.agents().count)
    }

    func testAnUnreachableFleetIsNotReportedAsAQuietOne() async {
        let control = FakeControlAPI()
        control.registryResult = .failure(ControlAPIError.transport("offline"))

        let failed = await failure { _ = try await makeActions(control: control).fleetSummary() }

        XCTAssertEqual(failed, .unreachable)
    }

    func testTheSpokenSummarySaysNothingIsWaitingInWords() {
        let quiet = QuickActions.FleetSummary(waiting: [], needingAttention: [], agentCount: 3)
        let busy = QuickActions.FleetSummary(
            waiting: ["Merge approval — example/project"],
            needingAttention: ["Planner"],
            agentCount: 3
        )

        XCTAssertFalse(quiet.spoken.isEmpty)
        XCTAssertFalse(quiet.spoken.contains("shortcut."), "a catalog key was spoken as itself")
        XCTAssertTrue(busy.spoken.contains("Merge approval — example/project"))
        XCTAssertTrue(busy.spoken.contains("Planner"))
        XCTAssertTrue(busy.spoken.contains("1"))
    }

    // MARK: - Sending

    func testAMessageGoesToTheAgentsOwnThreadOnce() async throws {
        let chat = FakeFleetAPI()
        let actions = makeActions(chat: chat)

        try await actions.send("status?", toAgentNamed: "builder")

        XCTAssertEqual(
            chat.calls,
            [
                .openConversation(externalRef: "main", agent: "builder", clientInstanceId: "instance-1"),
                .submit(
                    conversationId: "conversation-1",
                    submissionId: "submission-id",
                    idempotencyKey: "idempotency-key",
                    text: "status?"
                )
            ]
        )
        XCTAssertEqual(chat.accessTokensPresented, ["access-token-1", "access-token-1"])
    }

    func testAnAgentWithChatOffIsSaidAndNothingIsSubmitted() async {
        let chat = FakeFleetAPI()
        chat.openResults = [
            .failure(FleetAPIError.refused(.agentUnavailable, status: 409, message: nil))
        ]

        let failed = await failure {
            try await makeActions(chat: chat).send("status?", toAgentNamed: "quiet")
        }

        XCTAssertEqual(failed, .agentUnavailable)
        XCTAssertTrue(chat.submissions.isEmpty)
    }

    func testASendThatDidNotCompleteIsNotTriedAgain() async {
        let chat = FakeFleetAPI()
        chat.submitResults = [.failure(FleetAPIError.transport("offline"))]

        let failed = await failure {
            try await makeActions(chat: chat).send("status?", toAgentNamed: "builder")
        }

        XCTAssertEqual(failed, .unreachable)
        XCTAssertEqual(chat.submissions.count, 1, "one message must never become two turns")
    }

    func testAMessageOverTheLimitIsRefusedBeforeAnythingIsSent() async {
        let control = FakeControlAPI()
        let chat = FakeFleetAPI()
        let tooLong = String(repeating: "a", count: SessionLimits.documentedDefaults.inboundTextBytes + 1)

        let failed = await failure {
            try await makeActions(control: control, chat: chat).send(tooLong, toAgentNamed: "builder")
        }

        XCTAssertEqual(failed, .tooLong)
        XCTAssertTrue(control.calls.isEmpty)
        XCTAssertTrue(chat.calls.isEmpty)
    }

    func testImagesGoUpBeforeTheMessageThatNamesThem() async throws {
        let chat = FakeFleetAPI()
        let actions = makeActions(chat: chat)

        try await actions.send("look", images: [Data("abc".utf8)], toAgentNamed: "builder")

        let kinds = chat.calls.map { call -> String in
            switch call {
            case .openConversation: return "open"
            case .reserveAttachment: return "reserve"
            case .uploadAttachment: return "upload"
            case .submit: return "submit"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["open", "reserve", "upload", "submit"])
        XCTAssertEqual(chat.submittedAttachments, [[SubmissionAttachmentRef(attachmentId: "attachment-1")]])
        // The upload route is never given the sign-in: open, reserve and submit only.
        XCTAssertEqual(chat.accessTokensPresented.count, 3)
    }

    func testAnImageThatDidNotGoUpSendsNothing() async {
        let chat = FakeFleetAPI()
        chat.uploadResults = [.failure(FleetAPIError.transport("offline"))]

        let failed = await failure {
            try await makeActions(chat: chat).send("look", images: [Data("abc".utf8)], toAgentNamed: "builder")
        }

        XCTAssertEqual(failed, .unreachable)
        XCTAssertTrue(chat.submissions.isEmpty)
    }

    func testABare404IsImagesOffOnlyWhenThereWereImagesToSend() async {
        let withImages = FakeFleetAPI()
        withImages.reserveResults = [.failure(FleetAPIError.unexpectedStatus(404))]
        let first = await failure {
            try await makeActions(chat: withImages).send("look", images: [Data([1])], toAgentNamed: "builder")
        }
        XCTAssertEqual(first, .imagesUnsupported)

        // The same status on a message with nothing attached says nothing about images.
        let wordsOnly = FakeFleetAPI()
        wordsOnly.submitResults = [.failure(FleetAPIError.unexpectedStatus(404))]
        let second = await failure {
            try await makeActions(chat: wordsOnly).send("look", toAgentNamed: "builder")
        }
        XCTAssertEqual(second, .unreachable)
    }

    func testOnlyAgentsThatTakeChatAreOffered() async throws {
        let control = FakeControlAPI()
        control.chatAgentsResult = .success(
            ChatAgentList(
                available: true,
                agents: [ChatAgent(agentName: "builder", displayName: "Builder")]
            )
        )

        let offered = try await makeActions(control: control).chatAgents()

        XCTAssertEqual(offered.map(\.agentName), ["builder"])

        control.chatAgentsResult = .success(ChatAgentList(available: false, agents: []))
        let none = try await makeActions(control: control).chatAgents()
        XCTAssertTrue(none.isEmpty)
    }
}
