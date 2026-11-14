import XCTest
@testable import Phleet

/// The share sheet's behaviour: who to, what, one send, and what is said when it does not go.
@MainActor
final class ShareModelTests: XCTestCase {

    private let builder = ChatAgent(agentName: "builder", displayName: "Builder")
    private let reviewer = ChatAgent(agentName: "reviewer", displayName: "Reviewer")

    private func makeModel(
        control: FakeControlAPI = FakeControlAPI(),
        chat: FakeFleetAPI = FakeFleetAPI(),
        text: String = ""
    ) -> ShareModel {
        var identifiers = ["submission-id", "idempotency-key"]
        let actions = QuickActions(
            credentialStore: InMemoryCredentialStore(credential: .fixture),
            controlAPI: control,
            makeChatAPI: { _ in chat },
            newIdentifier: { identifiers.isEmpty ? "extra" : identifiers.removeFirst() }
        )
        // Empty bytes stand for something that is not an image; anything else passes through.
        return ShareModel(actions: actions, text: text, prepareImage: { $0.isEmpty ? nil : $0 })
    }

    private func listing(_ agents: [ChatAgent]) -> FakeControlAPI {
        let control = FakeControlAPI()
        control.chatAgentsResult = .success(ChatAgentList(available: true, agents: agents))
        return control
    }

    // MARK: - Who to

    func testTheFirstAgentListedIsChosenUntilAnotherIs() async {
        let model = makeModel(control: listing([builder, reviewer]))

        await model.loadAgents()

        XCTAssertEqual(model.agents, .loaded([builder, reviewer]))
        XCTAssertEqual(model.selectedAgent, builder)

        model.selectedAgentName = "reviewer"
        await model.loadAgents()
        XCTAssertEqual(model.selectedAgent, reviewer, "reading the list again keeps the choice")
    }

    func testWithNoAgentToSendToNothingCanBeSent() async {
        let model = makeModel(control: listing([]), text: "look at this")

        await model.loadAgents()

        XCTAssertEqual(model.agents, .loaded([]))
        XCTAssertFalse(model.canSend)
    }

    func testAListThatCouldNotBeReadSaysWhy() async {
        let control = FakeControlAPI()
        control.chatAgentsResult = .failure(ControlAPIError.transport("offline"))
        let model = makeModel(control: control, text: "look at this")

        await model.loadAgents()

        XCTAssertEqual(model.agents, .failed(.unreachable))
        XCTAssertFalse(model.canSend)
    }

    // MARK: - What

    func testSharedTextAndAnAddressBecomeParagraphsInTheOrderGiven() {
        let model = makeModel()

        model.add(texts: ["  A page title  ", "", "https://example.invalid/page"])
        model.add(texts: ["a second share"])

        XCTAssertEqual(
            model.text,
            "A page title\n\nhttps://example.invalid/page\n\na second share"
        )
    }

    func testAnImageThatCannotBeReadOrIsOneTooManyIsCountedNotDroppedSilently() {
        let model = makeModel()

        model.add(image: Data())
        for index in 0..<(ShareModel.maxImages + 1) {
            model.add(image: Data([UInt8(index)]))
        }

        XCTAssertEqual(model.images.count, ShareModel.maxImages)
        XCTAssertEqual(model.skippedImageCount, 2)
    }

    func testNothingToSendMeansNoSend() async {
        let model = makeModel(control: listing([builder]), text: "   ")
        await model.loadAgents()

        XCTAssertFalse(model.canSend)

        model.add(image: Data([1]))
        XCTAssertTrue(model.canSend, "an image alone is something to send")
    }

    // MARK: - Sending

    func testASendGoesOnceToTheChosenAgentsThreadWithItsImages() async {
        let chat = FakeFleetAPI()
        let model = makeModel(control: listing([builder, reviewer]), chat: chat, text: "what is this?")
        await model.loadAgents()
        model.selectedAgentName = "reviewer"
        model.add(image: Data("abc".utf8))

        await model.send()

        XCTAssertEqual(model.sending, .sent(agentName: "Reviewer"))
        XCTAssertFalse(model.canSend, "what was sent is not offered for sending again")
        XCTAssertEqual(
            chat.calls,
            [
                .openConversation(externalRef: "main", agent: "reviewer", clientInstanceId: "instance-1"),
                .reserveAttachment(
                    conversationId: "conversation-1",
                    byteSize: 3,
                    sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                ),
                .uploadAttachment(attachmentId: "attachment-1", uploadToken: "upload-token-1", byteCount: 3),
                .submit(
                    conversationId: "conversation-1",
                    submissionId: "submission-id",
                    idempotencyKey: "idempotency-key",
                    text: "what is this?"
                )
            ]
        )
        XCTAssertEqual(chat.submittedAttachments, [[SubmissionAttachmentRef(attachmentId: "attachment-1")]])
    }

    func testASendThatDidNotCompleteSaysSoAndCanBeTriedByThePerson() async {
        let chat = FakeFleetAPI()
        chat.submitResults = [.failure(FleetAPIError.transport("offline"))]
        let model = makeModel(control: listing([builder]), chat: chat, text: "hello")
        await model.loadAgents()

        await model.send()

        XCTAssertEqual(model.sending, .failed(.unreachable))
        XCTAssertEqual(chat.submissions.count, 1, "not tried again on its own")
        XCTAssertTrue(model.canSend, "the person may send again, with the failure in front of them")
    }

    func testAServerWithImagesOffSendsNothing() async {
        let chat = FakeFleetAPI()
        chat.reserveResults = [.failure(FleetAPIError.unexpectedStatus(404))]
        let model = makeModel(control: listing([builder]), chat: chat, text: "what is this?")
        await model.loadAgents()
        model.add(image: Data("abc".utf8))

        await model.send()

        XCTAssertEqual(model.sending, .failed(.imagesUnsupported))
        XCTAssertTrue(chat.submissions.isEmpty, "the words are not sent without their image")
    }

    func testAnAgentWhoseChatWasTurnedOffIsSaidAsThat() async {
        let chat = FakeFleetAPI()
        chat.openResults = [
            .failure(FleetAPIError.refused(.agentUnavailable, status: 409, message: nil))
        ]
        let model = makeModel(control: listing([builder]), chat: chat, text: "hello")
        await model.loadAgents()

        await model.send()

        XCTAssertEqual(model.sending, .failed(.agentUnavailable))
    }

    func testEveryFailureHasWordsOfItsOwn() {
        let failures: [QuickActions.Failure] = [
            .signedOut, .unreachable, .agentUnavailable, .tooLong, .imagesUnsupported, .refused
        ]
        let messages = failures.map(\.localizedMessage)

        XCTAssertEqual(Set(messages).count, failures.count)
        for (failure, message) in zip(failures, messages) {
            XCTAssertNotEqual(message, failure.messageKey, "\(failure.messageKey) is missing")
        }
    }
}
