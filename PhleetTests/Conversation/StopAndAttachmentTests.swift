import XCTest
@testable import Phleet

/// Stopping a running turn and sending images: what the transcript does with the events, what
/// the model sends, and what it refuses to claim.
@MainActor
final class StopAndAttachmentTests: XCTestCase {

    private let origin = URL(string: "https://server.invalid")!

    private func makeModel(
        api: FakeFleetAPI,
        stream: FakeConversationStream,
        identifiers: [String] = [],
        prepareImage: @escaping (Data) -> Data? = { $0.isEmpty ? nil : $0 }
    ) -> ConversationModel {
        let store = InMemoryCredentialStore(
            credential: DeviceCredential(
                origin: "https://server.invalid",
                deviceId: "device-1",
                deviceSecret: "secret-1",
                clientInstanceId: "instance-1"
            )
        )
        let tokens = AccessTokenHolder(credentialStore: store, clock: TestClock()) { credential in
            try await api.mintToken(
                origin: URL(string: credential.origin)!,
                deviceId: credential.deviceId,
                deviceSecret: credential.deviceSecret
            )
        }
        var remaining = identifiers
        return ConversationModel(
            api: api,
            stream: stream,
            tokens: tokens,
            origin: origin,
            agent: ChatAgent(agentName: "agent-1", displayName: "Agent one"),
            clientInstanceId: "instance-1",
            clock: TestClock(),
            newIdentifier: {
                remaining.isEmpty ? ClientIdentifier.random() : remaining.removeFirst()
            },
            randomFraction: { 0 },
            prepareImage: prepareImage,
            sleep: { _ in }
        )
    }

    private func script(_ events: [ConversationEvent] = []) -> [ConversationStreamEvent] {
        [.hello(FakeConversationStream.hello(nextSeq: 41))]
            + events.map { ConversationStreamEvent.event($0) }
            + [.closed(code: 4409, reason: nil)]
    }

    private func machine(_ events: [ConversationEvent]) -> TurnStateMachine {
        var machine = TurnStateMachine()
        for event in events {
            machine.apply(event)
        }
        return machine
    }

    // MARK: - The transcript

    func testAStopsOwnReceiptPutsNoRowInTheTranscript() {
        // A stop is a submission of its own, with no words, that the agent closes as dropped.
        let state = machine([
            TestEvent.text("durable-1", seq: 41, text: "hello"),
            TestEvent.started("durable-1", seq: 42),
            TestEvent.controlAck(nil, seq: 43, hadRunningTask: true),
            TestEvent.canceled("durable-1", seq: 44, reason: .user, merged: ["durable-1"]),
            TestEvent.accepted("cancel-1", .dropped, seq: 45)
        ])

        XCTAssertEqual(state.orderedRecords.map(\.id), ["durable-1"])
        XCTAssertNil(state.record("cancel-1"))
        guard case .canceled(let payload) = state.record("durable-1")?.state else {
            return XCTFail("the stopped turn should read as cancelled")
        }
        XCTAssertTrue(payload.reason.wasInitiatedHere)
        XCTAssertFalse(state.hasRunningTurn)
    }

    func testAMessageThatReallyWasDroppedKeepsItsRow() {
        let state = machine([
            TestEvent.text("durable-1", seq: 41, text: "hello"),
            TestEvent.accepted("durable-1", .dropped, seq: 42)
        ])

        XCTAssertEqual(state.record("durable-1")?.state, .notRun(.dropped))
        XCTAssertEqual(state.record("durable-1")?.text, "hello")
    }

    func testAStopWithNothingRunningIsSaidOnceAndClosesNothing() {
        let state = machine([
            TestEvent.accepted("s1", .queued, seq: 1),
            TestEvent.controlAck(nil, seq: 2, hadRunningTask: false)
        ])

        let lines = state.entries.compactMap { entry -> SystemLine? in
            if case .systemLine(let line) = entry { return line }
            return nil
        }
        XCTAssertEqual(lines.map(\.kind), [.nothingToStop])
        XCTAssertEqual(state.record("s1")?.state, .waiting, "no terminal is invented for it")
        XCTAssertEqual(state.controlAckCount, 1)
    }

    func testAnAcknowledgementThatSomethingWasRunningAddsNoLine() {
        let state = machine([
            TestEvent.started("s1", seq: 1),
            TestEvent.controlAck(nil, seq: 2, hadRunningTask: true)
        ])

        XCTAssertFalse(state.entries.contains { entry in
            if case .systemLine = entry { return true }
            return false
        })
        XCTAssertTrue(state.hasRunningTurn, "the turn's own terminal is what ends it")
    }

    func testImagesComeBackWithTheWordsTheyWereSentWith() {
        let image = AttachmentDescriptor(attachmentId: "a-1", contentType: "image/jpeg", byteSize: 3)
        var state = TurnStateMachine()
        state.apply(
            ConversationEvent(
                eventId: "text-1",
                seq: 41,
                kind: .submissionText,
                identity: TestEvent.identity(submissionId: "durable-1"),
                payload: .submissionText(SubmissionTextPayload(text: "look", attachments: [image]))
            )
        )

        XCTAssertEqual(state.record("durable-1")?.attachments, [image])
        XCTAssertEqual(state.record("durable-1")?.text, "look")
    }

    // MARK: - Stopping

    func testStopAsksForTheCurrentTurnAndWaitsForEventsToSayWhatHappened() async {
        let api = FakeFleetAPI()
        let stream = FakeConversationStream(scripts: [
            script([TestEvent.started("durable-1", seq: 41)]),
            script([
                TestEvent.controlAck(nil, seq: 42, hadRunningTask: true),
                TestEvent.canceled("durable-1", seq: 43, reason: .user, merged: ["durable-1"])
            ])
        ])
        let model = makeModel(api: api, stream: stream)
        _ = await model.runOnce()
        XCTAssertTrue(model.canStop)

        await model.stop()

        XCTAssertTrue(
            api.calls.contains(.cancel(conversationId: "conversation-1", scope: .current))
        )
        XCTAssertTrue(model.isStopping, "the answer to the request stops nothing")
        XCTAssertFalse(model.canStop, "a second stop is not offered while one is on its way")
        XCTAssertTrue(model.machine.hasRunningTurn)

        _ = await model.runOnce()

        XCTAssertFalse(model.isStopping)
        XCTAssertFalse(model.machine.hasRunningTurn)
        XCTAssertNil(model.stopFailure)
    }

    func testWithNothingRunningThereIsNothingToStop() async {
        let api = FakeFleetAPI()
        let model = makeModel(api: api, stream: FakeConversationStream(scripts: [script()]))
        _ = await model.runOnce()

        XCTAssertFalse(model.canStop)
        await model.stop()

        XCTAssertFalse(api.calls.contains(.cancel(conversationId: "conversation-1", scope: .current)))
    }

    func testAStopThatWasNotSentSaysSoAndCanBeAskedAgain() async {
        let api = FakeFleetAPI()
        api.cancelResults = [.failure(FleetAPIError.transport("offline"))]
        let stream = FakeConversationStream(scripts: [
            script([TestEvent.started("durable-1", seq: 41)])
        ])
        let model = makeModel(api: api, stream: stream)
        _ = await model.runOnce()

        await model.stop()

        XCTAssertEqual(model.stopFailure, .notSent)
        XCTAssertFalse(model.isStopping)
        XCTAssertTrue(model.canStop)
    }

    func testStoppingAnAgentWhoseChatWasTurnedOffSaysThat() async {
        let api = FakeFleetAPI()
        api.cancelResults = [
            .failure(FleetAPIError.refused(.agentUnavailable, status: 409, message: nil))
        ]
        let stream = FakeConversationStream(scripts: [
            script([TestEvent.started("durable-1", seq: 41)])
        ])
        let model = makeModel(api: api, stream: stream)
        _ = await model.runOnce()

        await model.stop()

        XCTAssertEqual(model.stopFailure, .agentUnavailable)
    }

    // MARK: - Images

    private let bytes = Data("abc".utf8)
    private let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testAnImageIsReservedUploadedWithItsOwnTokenAndThenNamedByTheMessage() async {
        let api = FakeFleetAPI()
        let model = makeModel(
            api: api,
            stream: FakeConversationStream(scripts: [script()]),
            identifiers: ["image-1", "local-1", "key-1"]
        )
        _ = await model.runOnce()
        XCTAssertTrue(model.addImage(bytes))

        let sent = await model.send("what is this?")

        let relevant = api.calls.filter { call in
            switch call {
            case .reserveAttachment, .uploadAttachment, .submit: return true
            default: return false
            }
        }
        XCTAssertEqual(
            relevant,
            [
                .reserveAttachment(conversationId: "conversation-1", byteSize: 3, sha256: digest),
                // The reservation's token, never the sign-in.
                .uploadAttachment(attachmentId: "attachment-1", uploadToken: "upload-token-1", byteCount: 3),
                .submit(
                    conversationId: "conversation-1",
                    submissionId: "local-1",
                    idempotencyKey: "key-1",
                    text: "what is this?"
                )
            ]
        )
        XCTAssertEqual(api.submittedAttachments, [[SubmissionAttachmentRef(attachmentId: "attachment-1")]])
        XCTAssertEqual(sent?.attachments, [SubmissionAttachmentRef(attachmentId: "attachment-1")])
        XCTAssertTrue(model.draftImages.isEmpty)
        XCTAssertNil(model.attachmentFailure)
        // Its own row shows it from the bytes just uploaded, without a download.
        XCTAssertEqual(model.machine.record("local-1")?.attachments.map(\.attachmentId), ["attachment-1"])
        XCTAssertEqual(model.images.data(for: "attachment-1"), bytes)
    }

    func testAMessageWithNothingAttachedLeavesTheKeyOutOfItsBody() async {
        let api = FakeFleetAPI()
        let model = makeModel(api: api, stream: FakeConversationStream(scripts: [script()]))
        _ = await model.runOnce()

        await model.send("just words")

        XCTAssertEqual(api.submittedAttachments, [[]])
        XCTAssertFalse(api.calls.contains { call in
            if case .reserveAttachment = call { return true }
            return false
        })
    }

    func testAServerWithImagesOffSendsNothingAndWithdrawsThePicker() async {
        let api = FakeFleetAPI()
        // The routes are not mapped at all, so the answer is a bare 404 with no protocol body.
        api.reserveResults = [.failure(FleetAPIError.unexpectedStatus(404))]
        let model = makeModel(api: api, stream: FakeConversationStream(scripts: [script()]))
        _ = await model.runOnce()
        model.addImage(bytes)

        let sent = await model.send("what is this?")

        XCTAssertNil(sent)
        XCTAssertEqual(model.attachmentFailure, .unsupportedServer)
        XCTAssertTrue(model.attachmentsUnsupported)
        XCTAssertFalse(model.canAddImage)
        XCTAssertTrue(api.submissions.isEmpty, "the words are not sent without their image")
        XCTAssertTrue(model.machine.orderedRecords.isEmpty, "nothing is shown as sent")
    }

    func testAnUploadThatDidNotCompleteKeepsTheDraftAndSendsOnTheNextTry() async {
        let api = FakeFleetAPI()
        api.uploadResults = [
            .failure(FleetAPIError.transport("offline")),
            .success(SealedAttachmentResponse(
                attachmentId: "attachment-1",
                protocolVersion: ProtocolVersion.current
            ))
        ]
        let model = makeModel(api: api, stream: FakeConversationStream(scripts: [script()]))
        _ = await model.runOnce()
        model.addImage(bytes)

        let first = await model.send("what is this?")

        XCTAssertNil(first)
        XCTAssertEqual(model.attachmentFailure, .notSent)
        XCTAssertEqual(model.draftImages.count, 1, "the image is still in the composer")
        XCTAssertTrue(api.submissions.isEmpty)

        let second = await model.send("what is this?")

        XCTAssertNotNil(second)
        XCTAssertEqual(api.submissions.count, 1)
        XCTAssertTrue(model.draftImages.isEmpty)
    }

    func testWhatCannotBeReadAsAnImageIsRefusedBeforeAnythingIsSent() async {
        let api = FakeFleetAPI()
        let model = makeModel(api: api, stream: FakeConversationStream(scripts: [script()]))

        XCTAssertFalse(model.addImage(Data()))

        XCTAssertEqual(model.attachmentFailure, .unreadable)
        XCTAssertTrue(model.draftImages.isEmpty)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testAFifthImageIsRefused() {
        let model = makeModel(api: FakeFleetAPI(), stream: FakeConversationStream())
        for _ in 0..<ConversationModel.maxImagesPerMessage {
            XCTAssertTrue(model.addImage(bytes))
        }

        XCTAssertFalse(model.canAddImage)
        XCTAssertFalse(model.addImage(bytes))
        XCTAssertEqual(model.attachmentFailure, .tooMany)
        XCTAssertEqual(model.draftImages.count, ConversationModel.maxImagesPerMessage)
    }

    func testRemovingAPickedImageTakesItOutOfTheMessage() {
        let model = makeModel(
            api: FakeFleetAPI(),
            stream: FakeConversationStream(),
            identifiers: ["image-1", "image-2"]
        )
        model.addImage(bytes)
        model.addImage(bytes)

        model.removeImage(id: "image-1")

        XCTAssertEqual(model.draftImages.map(\.id), ["image-2"])
    }

    // MARK: - Reading images back

    func testAnImageIsReadOnceAndAFailedReadIsTriedAgain() async {
        var answers: [Result<Data, Error>] = [
            .failure(FleetAPIError.transport("offline")),
            .success(Data("abc".utf8))
        ]
        var reads = 0
        let images = AttachmentImages { _ in
            reads += 1
            return try answers.removeFirst().get()
        }

        await images.load("a-1")
        XCTAssertEqual(images.state(for: "a-1"), .failed)

        await images.load("a-1")
        await images.load("a-1")

        XCTAssertEqual(images.data(for: "a-1"), Data("abc".utf8))
        XCTAssertEqual(reads, 2, "a loaded image is not read again")
    }

    func testOnlyTheMostRecentImagesAreKept() {
        let images = AttachmentImages { _ in Data() }
        for index in 0...AttachmentImages.limit {
            images.store(Data([UInt8(index)]), for: "a-\(index)")
        }

        XCTAssertNil(images.state(for: "a-0"), "the oldest goes when the limit is passed")
        XCTAssertNotNil(images.state(for: "a-\(AttachmentImages.limit)"))
        XCTAssertEqual(images.states.count, AttachmentImages.limit)
    }

    // MARK: - Preparing an image

    func testAPickedImageBecomesAJPEGNoLargerThanTheLongSideSent() throws {
        let size = CGSize(width: 3000, height: 1000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let picked = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let png = try XCTUnwrap(picked.pngData())

        let jpeg = try XCTUnwrap(ImagePreparation.jpeg(from: png))
        let decoded = try XCTUnwrap(UIImage(data: jpeg))

        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "the bytes are a JPEG")
        XCTAssertEqual(decoded.size.width * decoded.scale, ImagePreparation.maxSide, accuracy: 1)
        XCTAssertEqual(decoded.size.height * decoded.scale, 683, accuracy: 2)
        XCTAssertLessThanOrEqual(jpeg.count, ImagePreparation.maxBytes)
    }

    func testBytesThatAreNotAnImageArePreparedAsNothing() {
        XCTAssertNil(ImagePreparation.jpeg(from: Data("not an image".utf8)))
        XCTAssertNil(ImagePreparation.jpeg(from: Data()))
    }

    func testTheDigestIsLowercaseHexOfTheBytes() {
        XCTAssertEqual(ImagePreparation.sha256Hex(bytes), digest)
    }

    // MARK: - The wire

    func testASubmissionWithNoAttachmentsEncodesExactlyAsItAlwaysDid() throws {
        let body = SubmissionBody(type: .create, submissionId: "s-1", idempotencyKey: "k-1", text: "hi")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            ["protocol", "type", "submissionId", "idempotencyKey", "text"]
        )
    }

    func testASubmissionNamesItsAttachmentsInOrder() throws {
        let body = SubmissionBody(
            type: .create,
            submissionId: "s-1",
            idempotencyKey: "k-1",
            text: "hi",
            attachments: [
                SubmissionAttachmentRef(attachmentId: "a-1"),
                SubmissionAttachmentRef(attachmentId: "a-2")
            ]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        )
        let attachments = try XCTUnwrap(object["attachments"] as? [[String: String]])

        XCTAssertEqual(
            attachments,
            [["attachmentId": "a-1", "kind": "image"], ["attachmentId": "a-2", "kind": "image"]]
        )
    }

    func testACancelAndAReservationCarryTheProtocolField() throws {
        let cancel = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(CancelBody(scope: .current))
            ) as? [String: String]
        )
        XCTAssertEqual(cancel, ["protocol": ProtocolVersion.current, "scope": "current"])

        let reserve = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    ReserveAttachmentBody(
                        kind: "image",
                        contentType: "image/jpeg",
                        byteSize: 3,
                        sha256: digest,
                        fileName: "image.jpg"
                    )
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(reserve["protocol"] as? String, ProtocolVersion.current)
        XCTAssertEqual(reserve["byteSize"] as? Int, 3)
        XCTAssertEqual(reserve["sha256"] as? String, digest)
    }

    func testAttachmentDescriptorsAreReadFromTheWordsAndABadOneCostsOnlyItself() throws {
        let json = """
        {"protocol":"\(ProtocolVersion.current)","eventId":"e-1","seq":41,"kind":"submission.text",
         "identity":{"conversationId":"c-1","submissionId":"s-1"},
         "payload":{"text":"look","attachments":[
            {"attachmentId":"a-1","kind":"image","contentType":"image/png","byteSize":12,"fileName":"p.png"},
            {"kind":"image"},
            {"attachmentId":"a-2","kind":"document"}
         ]}}
        """
        let event = try ConversationEvent.decode(from: Data(json.utf8))

        guard case .submissionText(let payload) = event.payload else {
            return XCTFail("expected a submission.text payload")
        }
        XCTAssertEqual(payload.text, "look")
        XCTAssertEqual(payload.attachments.map(\.attachmentId), ["a-1", "a-2"])
        XCTAssertEqual(payload.attachments.first?.byteSize, 12)
        XCTAssertEqual(payload.attachments.map(\.isImage), [true, false])
    }

    func testWordsWithNothingAttachedDecodeWithNoAttachments() throws {
        let json = """
        {"protocol":"\(ProtocolVersion.current)","eventId":"e-1","seq":41,"kind":"submission.text",
         "identity":{"conversationId":"c-1","submissionId":"s-1"},"payload":{"text":"hi"}}
        """
        let event = try ConversationEvent.decode(from: Data(json.utf8))

        XCTAssertEqual(event.payload, .submissionText(SubmissionTextPayload(text: "hi")))
    }

    func testAnAttachmentsBytesMoveThroughOneAddressBuiltFromItsIdentifier() throws {
        XCTAssertEqual(
            URLSessionFleetAPIClient.attachmentPath("01JATTACHMENT"),
            "/v1/attachments/01JATTACHMENT/content"
        )
        // An identifier that is not one cannot reshape the path.
        XCTAssertEqual(
            URLSessionFleetAPIClient.attachmentPath("../../v1/session"),
            "/v1/attachments/%2E%2E%2F%2E%2E%2Fv1%2Fsession/content"
        )
    }
}
