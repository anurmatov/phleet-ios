import Foundation
import Observation

/// One thread: open it, attach the stream, catch up, send, and keep the connection alive.
///
/// The attach order is deliberate and is the decision the whole type is built around. The stream
/// is attached **before** catch-up is issued, because catch-up-then-attach leaves an interval
/// between the read and the upgrade in which appended events belong to neither, and the client
/// cannot tell a quiet interval from a lossy one. Buffering from `hello` onward means there is
/// no interval at all, and one code path serves first connect, clean resume and post-`4413`
/// recovery alike.
@MainActor
@Observable
final class ConversationModel {

    /// One durable thread per agent. Client-chosen, and what makes open idempotent across
    /// reinstall, signing in again, and the dashboard: a conversation is found again by the
    /// person, the agent and this reference, so the same person opening "main" with the same
    /// agent from the phone or the browser gets the same conversation. Each agent has a single
    /// model context, so more than one thread with it would look separate without being so.
    nonisolated static let externalRef = "main"

    /// A hard stop on paging, so a server that always reports `hasMore` cannot spin the app.
    nonisolated static let maxCatchUpPages = 200

    /// The initial round plus the one an overflow owes.
    nonisolated static let maxCatchUpRoundsPerAttach = 2

    /// Cursor writes are coalesced to at most one per this interval.
    nonisolated static let cursorCoalescingSeconds: Double = 5

    enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case live
        /// Backing off before the next attempt.
        case waiting(seconds: Int)
        case rateLimited(seconds: Int)
        /// `4409`. Automatic reconnect is switched off, not merely delayed.
        case superseded
        /// `4403`. Terminal, no retry.
        case notPermitted
        /// The thread itself is gone or refused.
        case unavailable
        /// `agent_unavailable`: chat is off for this agent. Someone turns it on in the agent's
        /// settings; asking again until then changes nothing, so nothing is retried.
        case agentUnavailable
        /// The device credential is dead.
        case revoked
        /// Nothing is reachable. The thread stays readable and sending still works, because
        /// sending is HTTPS.
        case offline
    }

    /// Why a send did not land.
    enum SendFailure: Equatable, Sendable {
        /// Over `inboundTextBytes`. Surfaced against the composer, never retried.
        case tooLarge
        /// `409 idempotency_conflict` — a defect in local id generation. Surfaced, and never
        /// worked around by generating a new id.
        case idempotencyConflict
        /// `409 agent_unavailable` — chat was turned off for this agent. Nothing was sent.
        case agentUnavailable
        /// Anything else. "Not known to have happened", which is not the same as "did not
        /// happen": a retry reuses the same ids.
        case notKnownToHaveHappened
    }

    /// Why a stop was not sent.
    enum StopFailure: Equatable, Sendable {
        /// `409 agent_unavailable` — chat was turned off for this agent.
        case agentUnavailable
        /// The request did not complete. Nothing is known to have been stopped.
        case notSent
    }

    /// Why an image could not be attached, or could not be sent.
    enum AttachmentFailure: Equatable, Sendable {
        /// Not an image this phone can read, or one that cannot be brought under the size limit.
        case unreadable
        /// More than a message may carry.
        case tooMany
        /// This server has no attachment routes: images are a separate switch on the chat
        /// service, and it is off.
        case unsupportedServer
        /// The server refused the image.
        case refused
        /// The upload did not complete. The message was not sent, and the draft is kept.
        case notSent
    }

    /// An image picked for the message being written: already converted, not yet uploaded.
    struct OutgoingImage: Equatable, Sendable, Identifiable {
        let id: String
        let jpeg: Data
    }

    /// A submission this device sent, kept so a retry can reuse its identifiers.
    struct PendingSubmission: Equatable, Sendable {
        let submissionId: String
        let idempotencyKey: String
        let text: String
        /// What was uploaded for it. A retry names the same attachments: they are bound to this
        /// submission and to no other.
        var attachments: [SubmissionAttachmentRef] = []
    }

    enum CycleOutcome: Equatable, Sendable {
        case closed(CloseAction)
        /// The cycle could not start; try again after a backoff.
        case retry
        /// The cycle could not start and the server named a delay; try again after exactly that.
        case retryAfter(seconds: Int)
        /// Stop entirely.
        case stop
    }

    /// What opening the conversation produced.
    ///
    /// A typed outcome rather than an optional: `openConversation` sets the connection state on
    /// its way out, so inferring "retryable" from that state afterwards reads whatever it just
    /// wrote and can only ever answer one way.
    private enum OpenOutcome {
        case opened(OpenConversationResponse)
        case retry
        case retryAfter(seconds: Int)
        case stop
    }

    // MARK: - Dependencies

    private let api: FleetAPIClient
    private let stream: ConversationStream
    private let tokens: AccessTokenHolder
    private let origin: URL

    /// The agent this thread is with. Fixed for the model's life: a conversation is with one
    /// agent, and another agent is another model.
    let agent: ChatAgent
    private let clientInstanceId: String
    private let clock: MonotonicClock
    private let sleep: (Double) async -> Void
    private let randomFraction: () -> Double
    private let newIdentifier: () -> String

    // MARK: - Observable state

    private(set) var machine = TurnStateMachine()
    private(set) var connectionState: ConnectionState = .idle
    private(set) var limits: SessionLimits
    private(set) var conversationId: String?
    private(set) var sendFailure: SendFailure?

    /// `afterSeq` values this client has processed up to. Starts at the cold-start cursor.
    private(set) var lastAppliedSeq = CatchUpCursor.coldStart

    // MARK: - Stopping

    private(set) var stopFailure: StopFailure?

    /// How many acknowledgements had been seen when a stop was asked for. `nil` when none is
    /// outstanding.
    private var stopAckBaseline: Int?

    /// A stop was asked for and the turn has not ended yet. Over when the turn ends or the
    /// agent acknowledges, whichever comes first — both arrive as events, never as the answer to
    /// the request.
    var isStopping: Bool {
        guard let baseline = stopAckBaseline else { return false }
        return machine.hasRunningTurn && machine.controlAckCount == baseline
    }

    /// Whether there is a running turn to stop and no stop already on its way.
    var canStop: Bool {
        conversationId != nil && machine.hasRunningTurn && !isStopping
    }

    // MARK: - Images

    /// The most a message may carry. The server refuses a fifth.
    nonisolated static let maxImagesPerMessage = 4

    /// Images picked for the message being written.
    private(set) var draftImages: [OutgoingImage] = []
    private(set) var attachmentFailure: AttachmentFailure?

    /// The images of the message being sent are on their way up.
    private(set) var isUploading = false

    /// Learned from a refusal: this server takes no images. The picker is withdrawn and the
    /// composer says why, rather than offering something that cannot work.
    private(set) var attachmentsUnsupported = false

    /// The bytes of the images in this thread.
    let images: AttachmentImages

    var canAddImage: Bool {
        !attachmentsUnsupported && !isUploading && draftImages.count < Self.maxImagesPerMessage
    }

    // MARK: - Observable history, for assertions and for logging

    /// One entry per stream attach, in order. Every one is a live-tail floor.
    private(set) var attachFloors: [Int] = []
    /// One entry per catch-up request, in order.
    private(set) var catchUpCursors: [Int] = []
    /// One entry per catch-up round (a round is one full paging run).
    private(set) var catchUpRounds = 0
    /// The close action the last connection produced.
    private(set) var lastCloseAction: CloseAction?
    /// Faults this client caused, surfaced rather than retried identically.
    private(set) var clientDefects: [String] = []
    /// How many times a cursor reset to the recovery floor. Logged, never silent.
    private(set) var invalidCursorRecoveries = 0

    /// How many times the live buffer overflowed while catching up.
    ///
    /// Observable rather than private because an overflow is not a silent event: each one owes a
    /// catch-up round, and "it happened and was recovered" has to be distinguishable from "it
    /// never happened".
    private(set) var liveBufferOverflows = 0

    // MARK: - Private state

    private var buffer: BoundedLiveBuffer
    private var policy = ReconnectPolicy()
    private var pending: [String: PendingSubmission] = [:]
    private var retainedFloorSeq = 0
    private var isApplyingLive = false
    private var didSpendFreeReauthentication = false
    private var lastCursorWriteAt: Double?
    private var writtenDeliveredSeq = 0
    private let prepareImage: (Data) -> Data?

    /// Attachment identifiers by picked image, so a send that is tried again does not upload
    /// the same bytes twice.
    private var uploadedAttachmentIds: [String: String] = [:]

    init(
        api: FleetAPIClient,
        stream: ConversationStream,
        tokens: AccessTokenHolder,
        origin: URL,
        agent: ChatAgent,
        clientInstanceId: String,
        limits: SessionLimits = .documentedDefaults,
        clock: MonotonicClock = SystemMonotonicClock(),
        newIdentifier: @escaping () -> String = ClientIdentifier.random,
        randomFraction: @escaping () -> Double = { Double.random(in: 0...1) },
        prepareImage: @escaping (Data) -> Data? = { ImagePreparation.jpeg(from: $0) },
        sleep: @escaping (Double) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
    ) {
        self.api = api
        self.stream = stream
        self.tokens = tokens
        self.origin = origin
        self.agent = agent
        self.clientInstanceId = clientInstanceId
        self.limits = limits
        self.clock = clock
        self.newIdentifier = newIdentifier
        self.randomFraction = randomFraction
        self.sleep = sleep
        self.prepareImage = prepareImage
        self.buffer = BoundedLiveBuffer(capacity: limits.outboundBufferEvents)
        self.images = AttachmentImages { attachmentId in
            try await tokens.authorized { token in
                try await api.attachmentContent(
                    origin: origin,
                    accessToken: token,
                    attachmentId: attachmentId
                )
            }
        }
    }

    // MARK: - Composer

    /// Whether the composer will send this text.
    ///
    /// Measured in **UTF-8 bytes, not characters**: the server's limit is a byte limit, and a
    /// message of emoji reaches it at a quarter of the character count.
    func isWithinInboundLimit(_ text: String) -> Bool {
        text.utf8.count <= limits.inboundTextBytes
    }

    /// Adds a picked image to the message being written.
    ///
    /// Converted here, before anything is sent: the server takes no HEIC, which is what the
    /// camera writes, and a photo straight from the library is larger than it needs to be.
    @discardableResult
    func addImage(_ data: Data) -> Bool {
        attachmentFailure = nil
        guard draftImages.count < Self.maxImagesPerMessage else {
            attachmentFailure = .tooMany
            return false
        }
        guard let jpeg = prepareImage(data) else {
            attachmentFailure = .unreadable
            return false
        }
        draftImages.append(OutgoingImage(id: newIdentifier(), jpeg: jpeg))
        return true
    }

    func removeImage(id: String) {
        draftImages.removeAll { $0.id == id }
        uploadedAttachmentIds[id] = nil
        attachmentFailure = nil
    }

    /// Sends a new message, with whatever images were picked for it.
    ///
    /// The images go up first, each to a slot reserved for it, and the message names them. An
    /// upload that fails sends nothing: the words and the images stay in the composer, and
    /// `nil` comes back with `attachmentFailure` saying why.
    @discardableResult
    func send(_ text: String) async -> PendingSubmission? {
        sendFailure = nil
        attachmentFailure = nil

        guard isWithinInboundLimit(text) else {
            // Blocked locally, and the `413` path below still exists: the server's limit is the
            // authority and can change.
            sendFailure = .tooLarge
            return nil
        }

        var references: [SubmissionAttachmentRef] = []
        var descriptors: [AttachmentDescriptor] = []
        if !draftImages.isEmpty {
            guard let conversationId else {
                attachmentFailure = .notSent
                return nil
            }
            isUploading = true
            defer { isUploading = false }

            for image in draftImages {
                do {
                    let attachmentId = try await upload(image, to: conversationId)
                    references.append(SubmissionAttachmentRef(attachmentId: attachmentId))
                    descriptors.append(
                        AttachmentDescriptor(
                            attachmentId: attachmentId,
                            contentType: Self.imageContentType,
                            byteSize: image.jpeg.count
                        )
                    )
                } catch {
                    let failure = Self.attachmentFailure(for: error)
                    if failure == .unsupportedServer {
                        attachmentsUnsupported = true
                        draftImages = []
                        uploadedAttachmentIds = [:]
                    }
                    attachmentFailure = failure
                    return nil
                }
            }
            draftImages = []
            uploadedAttachmentIds = [:]
        }

        let submission = PendingSubmission(
            submissionId: newIdentifier(),
            idempotencyKey: newIdentifier(),
            text: text,
            attachments: references
        )
        pending[submission.submissionId] = submission
        machine.registerLocalSubmission(
            id: submission.submissionId,
            text: text,
            attachments: descriptors
        )
        await post(submission)
        return submission
    }

    private nonisolated static let imageContentType = "image/jpeg"

    /// Reserves a slot, uploads the bytes into it, and keeps them for the row that shows them.
    private func upload(_ image: OutgoingImage, to conversationId: String) async throws -> String {
        if let uploaded = uploadedAttachmentIds[image.id] {
            return uploaded
        }
        let body = ReserveAttachmentBody(
            kind: "image",
            contentType: Self.imageContentType,
            byteSize: image.jpeg.count,
            sha256: ImagePreparation.sha256Hex(image.jpeg),
            fileName: "image.jpg"
        )
        let reservation = try await tokens.authorized { token in
            try await api.reserveAttachment(
                origin: origin,
                accessToken: token,
                conversationId: conversationId,
                body: body
            )
        }
        // The upload route takes the reservation's token and no sign-in. The token is used here,
        // once, and kept nowhere.
        _ = try await api.uploadAttachment(
            origin: origin,
            uploadToken: reservation.uploadToken,
            attachmentId: reservation.attachmentId,
            contentType: Self.imageContentType,
            data: image.jpeg
        )
        uploadedAttachmentIds[image.id] = reservation.attachmentId
        images.store(image.jpeg, for: reservation.attachmentId)
        return reservation.attachmentId
    }

    /// A route that is not there answers with a bare `404` or `405`, which is how a server
    /// without attachments says so: its attachment routes are not mapped at all. A `404` the
    /// server *named* is about the conversation or the attachment, and is a refusal.
    private static func attachmentFailure(for error: Error) -> AttachmentFailure {
        switch error as? FleetAPIError {
        case .unexpectedStatus(let status)? where status == 404 || status == 405:
            return .unsupportedServer
        case .refused(.unsupportedAttachments, _, _)?:
            return .unsupportedServer
        case .refused?, .unexpectedStatus?, .protocolMismatch?, .decoding?, .unauthorized?:
            return .refused
        case .rateLimited?, .transport?, nil:
            return .notSent
        }
    }

    // MARK: - Stopping the running turn

    /// Asks the agent to stop the turn that is running in this thread.
    ///
    /// The answer only says the request was taken. What it did arrives as events: the turn's own
    /// cancelled terminal, or an acknowledgement that nothing was running. So nothing here marks
    /// anything as stopped.
    func stop() async {
        guard let conversationId, canStop else { return }
        stopFailure = nil
        stopAckBaseline = machine.controlAckCount

        do {
            _ = try await tokens.authorized { token in
                try await api.cancel(
                    origin: origin,
                    accessToken: token,
                    conversationId: conversationId,
                    body: CancelBody(scope: .current)
                )
            }
        } catch FleetAPIError.refused(.agentUnavailable, _, _) {
            stopAckBaseline = nil
            stopFailure = .agentUnavailable
        } catch {
            stopAckBaseline = nil
            stopFailure = .notSent
        }
    }

    /// Retries a send that did not land.
    ///
    /// **Reuses the same `submissionId` and `idempotencyKey`. Always.** A non-2xx response never
    /// means "did not happen"; it means "not known to have happened", and minting a fresh id on
    /// retry is how one message becomes two turns.
    func retrySend(submissionId: String) async {
        guard let submission = pending[machine.localSubmissionId(for: submissionId)] else {
            return
        }
        await post(submission)
    }

    /// The explicit "Send again" on a `turn.outcome_unknown`.
    ///
    /// The single exception to the reuse rule, and it exists only behind this tap: the person is
    /// deliberately submitting a second time, so this is a **new** submission with new
    /// identifiers. There is no automatic retry anywhere — the server never auto-reruns and
    /// neither does the client.
    ///
    /// Only for a message this device sent. A row restored from history, with no send of this
    /// device's behind it, offers nothing to send: reading history never submits.
    @discardableResult
    func sendAgain(after submissionId: String) async -> PendingSubmission? {
        guard let previous = pending[machine.localSubmissionId(for: submissionId)] else {
            return nil
        }
        // An attachment is bound to the submission it went with, so a second submission needs
        // its own. The bytes are still here from the first upload; they go up again.
        if draftImages.isEmpty {
            draftImages = previous.attachments.compactMap { reference in
                images.data(for: reference.attachmentId).map {
                    OutgoingImage(id: newIdentifier(), jpeg: $0)
                }
            }
        }
        return await send(previous.text)
    }

    private func post(_ submission: PendingSubmission) async {
        guard let conversationId else {
            sendFailure = .notKnownToHaveHappened
            return
        }

        let body = SubmissionBody(
            type: .create,
            submissionId: submission.submissionId,
            idempotencyKey: submission.idempotencyKey,
            text: submission.text,
            attachments: submission.attachments.isEmpty ? nil : submission.attachments
        )

        do {
            let receipt = try await tokens.authorized { token in
                try await api.submit(
                    origin: origin,
                    accessToken: token,
                    conversationId: conversationId,
                    body: body
                )
            }
            sendFailure = nil
            // The receipt is what joins this device's echo to the row the server wrote: its
            // `acceptedSeq` is the seq of that submission's `submission.text`. A send that ended
            // without one stays unconfirmed until a retry's receipt resolves it.
            machine.reconcileReceipt(
                localSubmissionId: submission.submissionId,
                acceptedSeq: receipt.acceptedSeq
            )
        } catch FleetAPIError.refused(.payloadTooLarge, _, _) {
            sendFailure = .tooLarge
        } catch FleetAPIError.refused(.idempotencyConflict, _, _) {
            clientDefects.append("submission.idempotencyKey")
            sendFailure = .idempotencyConflict
        } catch FleetAPIError.refused(.agentUnavailable, _, _) {
            sendFailure = .agentUnavailable
        } catch {
            sendFailure = .notKnownToHaveHappened
        }
    }

    // MARK: - Cursor

    /// Writes the delivered/read cursor, coalesced.
    ///
    /// Best effort in every direction: a failure never blocks rendering or sending, and never
    /// rolls back applied local state. Cursor advance is HTTPS only — the socket is
    /// receive-mostly.
    func advanceCursor(force: Bool = false) async {
        guard let conversationId, lastAppliedSeq > writtenDeliveredSeq else { return }

        let now = clock.uptimeSeconds
        if !force, let last = lastCursorWriteAt, now - last < Self.cursorCoalescingSeconds {
            return
        }
        lastCursorWriteAt = now

        let delivered = lastAppliedSeq
        // `readSeq` never exceeds `deliveredSeq`: the server refuses that with `invalid_cursor`
        // and writes nothing.
        let body = CursorBody(
            clientInstanceId: clientInstanceId,
            deliveredSeq: delivered,
            readSeq: delivered
        )

        do {
            _ = try await tokens.authorized { token in
                try await api.advanceCursor(
                    origin: origin,
                    accessToken: token,
                    conversationId: conversationId,
                    body: body
                )
            }
            writtenDeliveredSeq = delivered
        } catch FleetAPIError.refused(.invalidCursor, _, _) {
            // Here this is a *client* defect — a malformed body, or a `readSeq` above
            // `deliveredSeq`. Surfaced as such, not retried identically until it succeeds.
            clientDefects.append("cursor.body")
        } catch {
            // Retried on the next coalescing window.
        }
    }

    // MARK: - Connection

    /// Runs attach cycles until the connection is disarmed or terminal.
    func run() async {
        while !Task.isCancelled {
            switch await runOnce() {
            case .stop:
                return

            case .retry:
                guard let delay = policy.nextDelay(randomFraction: randomFraction()) else {
                    return
                }
                connectionState = .waiting(seconds: Int(delay.rounded()))
                await sleep(delay)

            case .retryAfter(let seconds):
                connectionState = .rateLimited(seconds: seconds)
                await sleep(Double(seconds))

            case .closed(let action):
                switch action {
                case .disarm:
                    // Scoped to this connection: it performs zero further attempts, ever, and a
                    // person has to resume it.
                    policy.disarm()
                    connectionState = .superseded
                    return

                case .terminal:
                    connectionState = .notPermitted
                    return

                case .reauthenticateAndReconnect:
                    tokens.invalidateToken()
                    if !didSpendFreeReauthentication {
                        // The first token expiry mid-stream is ordinary and does not count
                        // against backoff.
                        didSpendFreeReauthentication = true
                        continue
                    }
                    guard let delay = policy.nextDelay(randomFraction: randomFraction()) else {
                        return
                    }
                    connectionState = .waiting(seconds: Int(delay.rounded()))
                    await sleep(delay)

                case .reconnectAfter(let seconds):
                    connectionState = .rateLimited(seconds: seconds)
                    await sleep(Double(seconds))

                case .reconnectWithBackoff, .reconnectAndCatchUp, .reattachFromFreshOpen:
                    guard let delay = policy.nextDelay(randomFraction: randomFraction()) else {
                        return
                    }
                    connectionState = .waiting(seconds: Int(delay.rounded()))
                    await sleep(delay)
                }
            }
        }
    }

    /// Re-arms after a `4409` and connects again, as a fresh connection.
    func resumeManually() async {
        policy.resumeManually()
        await run()
    }

    /// One attach cycle: open, attach, wait for `hello`, catch up, drain, then apply live frames
    /// until the connection ends.
    @discardableResult
    func runOnce() async -> CycleOutcome {
        connectionState = .connecting

        let open: OpenConversationResponse
        switch await openConversation() {
        case .opened(let response):
            open = response
        case .retry:
            return .retry
        case .retryAfter(let seconds):
            return .retryAfter(seconds: seconds)
        case .stop:
            return .stop
        }

        conversationId = open.conversationId
        retainedFloorSeq = open.retainedFloorSeq

        // The floor is derived here, from this response, and nowhere else. Every attach — cold
        // start, resume, and recovery — uses the same value from the same source.
        let floor = StreamAttachFloor.liveTailFloor(nextSeq: open.nextSeq)
        attachFloors.append(floor)

        let token: String
        do {
            token = try await tokens.accessToken()
        } catch AccessTokenHolder.Failure.deviceRevoked {
            connectionState = .revoked
            return .stop
        } catch {
            connectionState = .offline
            return .retry
        }

        buffer = BoundedLiveBuffer(capacity: limits.outboundBufferEvents)
        isApplyingLive = false

        let frames = stream.frames(
            origin: origin,
            accessToken: token,
            conversationId: open.conversationId,
            clientInstanceId: clientInstanceId,
            afterSeq: floor
        )

        var framesSinceHello = 0
        var connectedAt: Double?
        var outcome: CycleOutcome = .retry
        var catchUp: Task<Void, Never>?

        for await item in frames {
            switch item {
            case .hello:
                connectedAt = clock.uptimeSeconds
                connectionState = .live
                // Started as a sibling task rather than awaited inline: the frame loop must keep
                // draining into the bounded buffer while catch-up runs, or the frames simply
                // queue somewhere else and the bound means nothing.
                catchUp = Task { await self.catchUpAndGoLive() }

            case .event(let event):
                framesSinceHello += 1
                if isApplyingLive {
                    applyLive(event)
                } else {
                    buffer.append(event)
                    liveBufferOverflows = buffer.overflowCount
                }

            case .undecodableFrame:
                // Dropped, and a catch-up owed. Never a teardown.
                buffer.markNeedsCatchUp()

            case .closed(let code, let reason):
                let action = CloseCode.action(
                    for: code,
                    reason: reason,
                    framesAppliedSinceHello: framesSinceHello
                )
                lastCloseAction = action
                outcome = .closed(action)

            case .failed:
                lastCloseAction = nil
                outcome = .retry
            }
        }

        await catchUp?.value

        policy.recordConnectionEnded(
            connectedForSeconds: connectedAt.map { clock.uptimeSeconds - $0 } ?? 0
        )
        await advanceCursor(force: true)
        return outcome
    }

    private func openConversation() async -> OpenOutcome {
        do {
            let response = try await tokens.authorized { token in
                try await api.openConversation(
                    origin: origin,
                    accessToken: token,
                    externalRef: Self.externalRef,
                    agent: agent.agentName,
                    clientInstanceId: clientInstanceId
                )
            }
            return .opened(response)

        } catch AccessTokenHolder.Failure.deviceRevoked {
            connectionState = .revoked
            return .stop

        } catch FleetAPIError.refused(.agentUnavailable, _, _) {
            // Said as itself rather than as "unavailable": the fix is a switch in the agent's
            // settings, and the person should be told which one.
            connectionState = .agentUnavailable
            return .stop

        } catch FleetAPIError.rateLimited(let seconds) {
            // The server named a delay. Honouring it is not the same as giving up: the thread is
            // still there, and the reconnect loop stays alive.
            connectionState = .rateLimited(seconds: seconds)
            return .retryAfter(seconds: seconds)

        } catch let error as FleetAPIError {
            switch error.treatment {
            case .terminal, .clientDefect:
                // Never fabricate a conversation id, and never loop on a refusal that asking
                // again cannot change.
                connectionState = .unavailable
                return .stop
            default:
                // A transport failure, a `503`, or a `500` says nothing durable about the thread.
                // Ending the reconnect loop here would leave the app permanently disconnected
                // after one bad moment, with no path back but relaunching.
                connectionState = .offline
                return .retry
            }

        } catch {
            connectionState = .offline
            return .retry
        }
    }

    // MARK: - Catch-up

    private func catchUpAndGoLive() async {
        var rounds = 0
        repeat {
            await catchUpPages()
            rounds += 1
        } while buffer.consumeOverflow() && rounds < Self.maxCatchUpRoundsPerAttach

        // Drain and flip in one synchronous step: no `await` between them, so a frame cannot
        // arrive after the drain and before live application begins.
        for event in buffer.drain() {
            applyLive(event)
        }
        isApplyingLive = true
        await advanceCursor()
    }

    /// One catch-up round: pages from the current cursor until `hasMore` is false.
    private func catchUpPages() async {
        guard let conversationId else { return }

        catchUpRounds += 1
        var cursor = lastAppliedSeq
        var didRecoverCursor = false

        for _ in 0..<Self.maxCatchUpPages {
            // Read the maximum from the session rather than hardcoding it, and never send a
            // value above it: the server answers an over-maximum limit with `unsupported_kind`
            // and, by design, does **not** clamp.
            let limit = max(1, min(limits.catchUpLimitDefault, limits.catchUpLimitMax))
            catchUpCursors.append(cursor)

            do {
                let page = try await tokens.authorized { token in
                    try await api.catchUp(
                        origin: origin,
                        accessToken: token,
                        conversationId: conversationId,
                        afterSeq: cursor,
                        limit: limit
                    )
                }
                apply(page)
                cursor = page.nextAfterSeq
                lastAppliedSeq = max(lastAppliedSeq, page.nextAfterSeq)
                guard page.hasMore else { return }

            } catch FleetAPIError.refused(.invalidCursor, _, _) {
                // The local cursor is ahead of the server: local corruption, or a restored
                // backup. Never clamped server-side, and never silently continued from. One
                // recovery per round — a second `invalid_cursor` against the recovery floor is a
                // server-side condition this client cannot fix by asking again.
                guard !didRecoverCursor else {
                    clientDefects.append("catchUp.cursor")
                    return
                }
                didRecoverCursor = true
                invalidCursorRecoveries += 1
                let recovery = CatchUpCursor.recoveryFloor(retainedFloorSeq: retainedFloorSeq)
                lastAppliedSeq = recovery
                cursor = recovery

            } catch FleetAPIError.refused(.unsupportedKind, _, _) {
                clientDefects.append("catchUp.limit")
                return

            } catch AccessTokenHolder.Failure.deviceRevoked {
                connectionState = .revoked
                return

            } catch {
                return
            }
        }
    }

    private func apply(_ page: CatchUpResponse) {
        if page.gap != nil {
            // Comes first in the response and is rendered first: history expired beneath the
            // cursor, and the separator is how the person finds out.
            machine.appendHistoryGap(id: "gap:" + String(page.nextAfterSeq))
        }
        for event in page.events {
            machine.apply(event)
        }
    }

    private func applyLive(_ event: ConversationEvent) {
        guard machine.apply(event) else { return }
        if let seq = event.seq {
            lastAppliedSeq = max(lastAppliedSeq, seq)
        }
    }
}
