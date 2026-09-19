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

        let backend = ScriptedBackend()
        return LaunchDouble(
            credentialStore: InMemoryCredentialStore(),
            api: backend,
            stream: backend
        )
    }
}

/// The scripted backend. One turn, one answer.
final class ScriptedBackend: FleetAPIClient, ConversationStream {

    private let conversationId = "scripted-conversation"
    private var continuation: AsyncStream<ConversationStreamEvent>.Continuation?
    private var seq = 40

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
        CatchUpResponse(
            events: [],
            nextAfterSeq: afterSeq,
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
