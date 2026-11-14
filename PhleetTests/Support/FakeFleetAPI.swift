import Foundation
@testable import Phleet

/// A scripted HTTPS double.
///
/// Records every call in order, so request *ordering* — the thing the attach sequence is built
/// around — is assertable without a network. Every test in this suite is hermetic: nothing here
/// opens a socket, and the suite passes with the runner offline.
final class FakeFleetAPI: FleetAPIClient {

    enum Call: Equatable {
        case mintToken(deviceId: String, deviceSecret: String)
        case session
        case openConversation(externalRef: String, agent: String, clientInstanceId: String)
        case catchUp(conversationId: String, afterSeq: Int, limit: Int)
        case submit(
            conversationId: String,
            submissionId: String,
            idempotencyKey: String,
            text: String
        )
        case cursor(conversationId: String, deliveredSeq: Int, readSeq: Int?)
        case conversations
        case cancel(conversationId: String, scope: CancelBody.Scope)
        case reserveAttachment(conversationId: String, byteSize: Int, sha256: String)
        case uploadAttachment(attachmentId: String, uploadToken: String, byteCount: Int)
        case attachmentContent(attachmentId: String)
    }

    private(set) var calls: [Call] = []
    private(set) var accessTokensPresented: [String] = []

    /// Guards everything a route method touches.
    ///
    /// These methods are `nonisolated async`, so each call runs on whatever thread the
    /// concurrency pool hands it — and more than one caller can be in here at once. That is not
    /// hypothetical: `DynamicTypeRenderingTests` renders the real thread view several times, each
    /// render starts the view's connection loop, and every loop calls this one double. Two
    /// unguarded `Array.append`s then corrupt the heap, and the test process dies with a
    /// segmentation fault some tests later, blamed on whichever test happened to be running.
    private let lock = NSLock()

    /// Runs when a catch-up request is made, before its result is produced. Lets a test act in
    /// the middle of the attach sequence.
    var onCatchUp: ((Int) -> Void)?

    /// Holds a catch-up open until it returns true.
    ///
    /// A catch-up that returns without suspending completes before the frame loop reads its next
    /// frame, so live frames are applied directly and the buffer is never exercised at all. A
    /// test that needs frames to *queue* during catch-up gates it on an observable condition
    /// rather than on a guessed number of yields, which is the difference between a deterministic
    /// test and one that passes depending on scheduling.
    var catchUpGate: (() -> Bool)?

    /// A hard bound, so a gate that never opens fails the test instead of hanging the suite.
    static let maxGateYields = 50_000

    var mintResults: [Result<MintTokenResponse, Error>] = [
        .success(MintTokenResponse(
            accessToken: "token-1",
            expiresInSeconds: 900,
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var sessionResults: [Result<SessionResponse, Error>] = [
        .success(SessionResponse(
            principalId: "principal-1",
            limits: .documentedDefaults,
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var openResults: [Result<OpenConversationResponse, Error>] = [
        .success(OpenConversationResponse(
            conversationId: "conversation-1",
            nextSeq: 41,
            retainedFloorSeq: 12,
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var catchUpResults: [Result<CatchUpResponse, Error>] = [
        .success(CatchUpResponse(
            events: [],
            nextAfterSeq: 0,
            hasMore: false,
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var submitResults: [Result<SubmissionAcceptedResponse, Error>] = [
        .success(SubmissionAcceptedResponse(
            submissionId: "submission-1",
            acceptedSeq: 41,
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var cursorResults: [Result<CursorAcceptedResponse, Error>] = [
        .success(CursorAcceptedResponse(protocolVersion: ProtocolVersion.current))
    ]

    var conversationsResults: [Result<ConversationListResponse, Error>] = [
        .success(ConversationListResponse(
            conversations: [],
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var cancelResults: [Result<CancelAcceptedResponse, Error>] = [
        .success(CancelAcceptedResponse(protocolVersion: ProtocolVersion.current))
    ]
    var reserveResults: [Result<ReserveAttachmentResponse, Error>] = [
        .success(ReserveAttachmentResponse(
            attachmentId: "attachment-1",
            uploadToken: "upload-token-1",
            maxBytes: 8_388_608,
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var uploadResults: [Result<SealedAttachmentResponse, Error>] = [
        .success(SealedAttachmentResponse(
            attachmentId: "attachment-1",
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var contentResults: [Result<Data, Error>] = [.success(Data())]

    /// The attachments each submission named, in order, alongside `submissions`.
    private(set) var submittedAttachments: [[SubmissionAttachmentRef]] = []

    // MARK: - Convenience readers

    var catchUpCursors: [Int] {
        calls.compactMap {
            if case .catchUp(_, let afterSeq, _) = $0 { return afterSeq }
            return nil
        }
    }

    var catchUpLimits: [Int] {
        calls.compactMap {
            if case .catchUp(_, _, let limit) = $0 { return limit }
            return nil
        }
    }

    var submissions: [(submissionId: String, idempotencyKey: String, text: String)] {
        calls.compactMap {
            if case .submit(_, let submissionId, let key, let text) = $0 {
                return (submissionId, key, text)
            }
            return nil
        }
    }

    var mintCallCount: Int {
        calls.filter { if case .mintToken = $0 { return true } else { return false } }.count
    }

    // MARK: - The token mint

    /// What a token holder built over this double mints with. Not a chat route — the orchestrator
    /// mints — but recorded here in order with the chat calls, so a test can see where a mint
    /// fell in the sequence.
    func mintToken(
        origin: URL,
        deviceId: String,
        deviceSecret: String
    ) async throws -> MintTokenResponse {
        try lock.withLock {
            calls.append(.mintToken(deviceId: deviceId, deviceSecret: deviceSecret))
            return try Self.next(&mintResults)
        }
    }

    // MARK: - FleetAPIClient

    func session(origin: URL, accessToken: String) async throws -> SessionResponse {
        try lock.withLock {
            calls.append(.session)
            accessTokensPresented.append(accessToken)
            return try Self.next(&sessionResults)
        }
    }

    func openConversation(
        origin: URL,
        accessToken: String,
        externalRef: String,
        agent: String,
        clientInstanceId: String
    ) async throws -> OpenConversationResponse {
        try lock.withLock {
            calls.append(
                .openConversation(
                    externalRef: externalRef,
                    agent: agent,
                    clientInstanceId: clientInstanceId
                )
            )
            accessTokensPresented.append(accessToken)
            return try Self.next(&openResults)
        }
    }

    func catchUp(
        origin: URL,
        accessToken: String,
        conversationId: String,
        afterSeq: Int,
        limit: Int
    ) async throws -> CatchUpResponse {
        lock.withLock {
            calls.append(
                .catchUp(conversationId: conversationId, afterSeq: afterSeq, limit: limit)
            )
            accessTokensPresented.append(accessToken)
        }
        // Outside the lock: a test's hook may call back into this double, and the gate below
        // suspends.
        onCatchUp?(afterSeq)

        if let catchUpGate {
            var yields = 0
            while !catchUpGate(), yields < Self.maxGateYields {
                await Task.yield()
                yields += 1
            }
        }
        return try lock.withLock { try Self.next(&catchUpResults) }
    }

    func submit(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: SubmissionBody
    ) async throws -> SubmissionAcceptedResponse {
        try lock.withLock {
            calls.append(
                .submit(
                    conversationId: conversationId,
                    submissionId: body.submissionId,
                    idempotencyKey: body.idempotencyKey,
                    text: body.text
                )
            )
            submittedAttachments.append(body.attachments ?? [])
            accessTokensPresented.append(accessToken)
            return try Self.next(&submitResults)
        }
    }

    func conversations(origin: URL, accessToken: String) async throws -> ConversationListResponse {
        try lock.withLock {
            calls.append(.conversations)
            accessTokensPresented.append(accessToken)
            return try Self.next(&conversationsResults)
        }
    }

    func cancel(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: CancelBody
    ) async throws -> CancelAcceptedResponse {
        try lock.withLock {
            calls.append(.cancel(conversationId: conversationId, scope: body.scope))
            accessTokensPresented.append(accessToken)
            return try Self.next(&cancelResults)
        }
    }

    func reserveAttachment(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: ReserveAttachmentBody
    ) async throws -> ReserveAttachmentResponse {
        try lock.withLock {
            calls.append(
                .reserveAttachment(
                    conversationId: conversationId,
                    byteSize: body.byteSize,
                    sha256: body.sha256
                )
            )
            accessTokensPresented.append(accessToken)
            return try Self.next(&reserveResults)
        }
    }

    func uploadAttachment(
        origin: URL,
        uploadToken: String,
        attachmentId: String,
        contentType: String,
        data: Data
    ) async throws -> SealedAttachmentResponse {
        try lock.withLock {
            // Not recorded among the access tokens: this route is never given one.
            calls.append(
                .uploadAttachment(
                    attachmentId: attachmentId,
                    uploadToken: uploadToken,
                    byteCount: data.count
                )
            )
            return try Self.next(&uploadResults)
        }
    }

    func attachmentContent(
        origin: URL,
        accessToken: String,
        attachmentId: String
    ) async throws -> Data {
        try lock.withLock {
            calls.append(.attachmentContent(attachmentId: attachmentId))
            accessTokensPresented.append(accessToken)
            return try Self.next(&contentResults)
        }
    }

    func advanceCursor(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: CursorBody
    ) async throws -> CursorAcceptedResponse {
        try lock.withLock {
            calls.append(
                .cursor(
                    conversationId: conversationId,
                    deliveredSeq: body.deliveredSeq,
                    readSeq: body.readSeq
                )
            )
            accessTokensPresented.append(accessToken)
            return try Self.next(&cursorResults)
        }
    }

    /// Consumes the next scripted result, repeating the last one forever.
    private static func next<T>(_ queue: inout [Result<T, Error>]) throws -> T {
        guard let first = queue.first else {
            throw FleetAPIError.transport("no scripted result")
        }
        if queue.count > 1 {
            queue.removeFirst()
        }
        return try first.get()
    }
}

/// A monotonic clock a test drives by hand.
final class TestClock: MonotonicClock {
    var uptimeSeconds: Double = 0

    func advance(_ seconds: Double) {
        uptimeSeconds += seconds
    }
}
