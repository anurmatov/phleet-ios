import Foundation

/// A scripted backend selected by a launch argument, so the UI smoke test can drive
/// enroll → agent → thread → send → terminal without a network.
///
/// Compiled into the app unconditionally and selected at runtime. It is deliberately **not**
/// behind a second `#if DEBUG`: the codebase has exactly one build-gate branch, `make lint`
/// fails on a second, and a UI test runs against the app as built.
///
/// Everything it answers with is obviously synthetic.
struct LaunchDouble {

    let credentialStore: CredentialStore
    let api: FleetAPIClient
    let stream: ConversationStream

    static func make(from arguments: [String]) -> LaunchDouble? {
        guard arguments.contains(LaunchArguments.scriptedBackend) else { return nil }

        let backend = ScriptedBackend(
            tallTranscript: arguments.contains(LaunchArguments.tallTranscript)
        )
        return LaunchDouble(
            credentialStore: InMemoryCredentialStore(),
            api: backend,
            stream: backend
        )
    }
}

/// The scripted backend. One turn, one answer — on an optionally pre-populated thread.
final class ScriptedBackend: FleetAPIClient, ConversationStream {

    private let conversationId = "scripted-conversation"
    private var continuation: AsyncStream<ConversationStreamEvent>.Continuation?
    private var seq = 40
    private var seededCatchUp = false

    /// Answer catch-up with a back-and-forth long enough to overflow any viewport.
    ///
    /// Seeded through **catch-up** rather than as one long live reply, because open-at-newest
    /// can only be observed on a thread that is already tall when it opens. A tall reply that
    /// only arrives after the first send proves nothing about the scroll position on arrival.
    private let tallTranscript: Bool

    init(tallTranscript: Bool = false) {
        self.tallTranscript = tallTranscript
    }

    /// `openConversation` reports `nextSeq: 41`, and history before `retainedFloorSeq: 12` is
    /// pruned, so seq 12...40 is exactly the readable range: seeding it leaves no gap at either
    /// end. Each reply names its position so a test can assert *which* one is on screen —
    /// "something is visible" would pass at the top of the thread as readily as the bottom.
    private static let seededReplies: [(seq: Int, text: String)] = {
        let range = 12...40
        return range.map { seq in
            let index = seq - range.lowerBound + 1
            return (
                seq,
                "Seeded reply \(index) of \(range.count). Long enough to wrap onto a second "
                    + "line so that a handful of these overflow the viewport."
            )
        }
    }()

    // MARK: - FleetAPIClient

    func registerDevice(
        origin: URL,
        enrollmentCode: String
    ) async throws -> RegisterDeviceResponse {
        RegisterDeviceResponse(
            deviceId: "scripted-device",
            deviceSecret: "scripted-secret",
            protocolVersion: ProtocolVersion.current
        )
    }

    func mintToken(
        origin: URL,
        deviceId: String,
        deviceSecret: String
    ) async throws -> MintTokenResponse {
        MintTokenResponse(
            accessToken: "scripted-token",
            expiresInSeconds: 900,
            protocolVersion: ProtocolVersion.current
        )
    }

    func session(origin: URL, accessToken: String) async throws -> SessionResponse {
        SessionResponse(
            principalId: "scripted-principal",
            agentLabel: "Scripted agent",
            limits: .documentedDefaults,
            protocolVersion: ProtocolVersion.current
        )
    }

    func openConversation(
        origin: URL,
        accessToken: String,
        externalRef: String,
        clientInstanceId: String
    ) async throws -> OpenConversationResponse {
        OpenConversationResponse(
            conversationId: conversationId,
            nextSeq: 41,
            retainedFloorSeq: 12,
            protocolVersion: ProtocolVersion.current
        )
    }

    func catchUp(
        origin: URL,
        accessToken: String,
        conversationId: String,
        afterSeq: Int,
        limit: Int
    ) async throws -> CatchUpResponse {
        guard tallTranscript, !seededCatchUp else {
            return CatchUpResponse(
                events: [],
                nextAfterSeq: afterSeq,
                hasMore: false,
                protocolVersion: ProtocolVersion.current
            )
        }
        seededCatchUp = true

        let events = Self.seededReplies.map { seeded in
            ConversationEvent(
                eventId: "seeded-final-\(seeded.seq)",
                seq: seeded.seq,
                kind: .turnFinal,
                identity: EventIdentity(
                    conversationId: conversationId,
                    submissionId: "seeded-submission-\(seeded.seq)"
                ),
                payload: .turnFinal(
                    TurnFinalPayload(
                        text: seeded.text,
                        completion: .completed,
                        isPartial: false,
                        truncated: false,
                        mergedSubmissionIds: ["seeded-submission-\(seeded.seq)"]
                    )
                )
            )
        }

        return CatchUpResponse(
            events: events,
            nextAfterSeq: Self.seededReplies.last?.seq ?? afterSeq,
            hasMore: false,
            protocolVersion: ProtocolVersion.current
        )
    }

    func submit(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: SubmissionBody
    ) async throws -> SubmissionAcceptedResponse {
        let accepted = nextSeq()
        emitTurn(for: body.submissionId, acceptedSeq: accepted)
        return SubmissionAcceptedResponse(
            submissionId: body.submissionId,
            acceptedSeq: accepted,
            protocolVersion: ProtocolVersion.current
        )
    }

    func advanceCursor(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: CursorBody
    ) async throws -> CursorAcceptedResponse {
        CursorAcceptedResponse(protocolVersion: ProtocolVersion.current)
    }

    // MARK: - ConversationStream

    func frames(
        origin: URL,
        accessToken: String,
        conversationId: String,
        clientInstanceId: String,
        afterSeq: Int
    ) -> AsyncStream<ConversationStreamEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(
                .hello(
                    HelloFrame(
                        conversationId: conversationId,
                        nextSeq: 41,
                        retainedFloorSeq: 12,
                        limits: .documentedDefaults,
                        protocolVersion: ProtocolVersion.current
                    )
                )
            )
        }
    }

    // MARK: - Script

    private func nextSeq() -> Int {
        seq += 1
        return seq
    }

    private func emitTurn(for submissionId: String, acceptedSeq: Int) {
        let identity = EventIdentity(
            conversationId: conversationId,
            submissionId: submissionId
        )

        continuation?.yield(
            .event(
                ConversationEvent(
                    eventId: "scripted-accepted-" + submissionId,
                    seq: acceptedSeq,
                    kind: .submissionAccepted,
                    identity: identity,
                    payload: .submissionAccepted(SubmissionAcceptedPayload(disposition: .ran))
                )
            )
        )
        continuation?.yield(
            .event(
                ConversationEvent(
                    eventId: "scripted-started-" + submissionId,
                    seq: nextSeq(),
                    kind: .turnStarted,
                    identity: identity,
                    payload: .turnStarted(TurnStartedPayload())
                )
            )
        )
        continuation?.yield(
            .event(
                ConversationEvent(
                    eventId: "scripted-final-" + submissionId,
                    seq: nextSeq(),
                    kind: .turnFinal,
                    identity: identity,
                    payload: .turnFinal(
                        TurnFinalPayload(
                            text: "Scripted reply.",
                            completion: .completed,
                            isPartial: false,
                            truncated: false,
                            mergedSubmissionIds: [submissionId]
                        )
                    )
                )
            )
        )
    }
}
