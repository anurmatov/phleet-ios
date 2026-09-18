import Foundation
@testable import Phleet

/// A scripted stream double: `hello`, some events, a close code.
///
/// Every close-code behaviour is assertable through this with no socket anywhere, which is the
/// whole reason `ConversationStream` is a seam rather than a concrete type.
///
/// A script **must** end with `.closed` or `.failed`. The model iterates the sequence until it
/// ends, so a script without a terminator would never return.
final class FakeConversationStream: ConversationStream {

    struct Attach: Equatable {
        let conversationId: String
        let clientInstanceId: String
        let afterSeq: Int
    }

    private(set) var attaches: [Attach] = []
    private(set) var accessTokensPresented: [String] = []

    /// One script per attach, consumed in order. The last one repeats.
    var scripts: [[ConversationStreamEvent]]

    /// Runs as an attach begins, with the floor it was given.
    var onAttach: ((Int) -> Void)?

    /// The live connection, so a test can deliver frames at a moment of its choosing rather than
    /// only from the script. Used to put frames on the wire *while* a catch-up is in flight,
    /// which is the only time the client's buffer is exercised at all.
    private var current: AsyncStream<ConversationStreamEvent>.Continuation?

    /// When false, the connection stays open after its script runs out and the test closes it
    /// with `push(_:finishing:)`.
    var finishesAfterScript = true

    func push(_ events: [ConversationStreamEvent], finishing: Bool = false) {
        for event in events {
            current?.yield(event)
        }
        if finishing {
            current?.finish()
        }
    }

    init(scripts: [[ConversationStreamEvent]] = [[.hello(FakeConversationStream.hello()), .closed(code: 4500, reason: nil)]]) {
        self.scripts = scripts
    }

    var attachFloors: [Int] { attaches.map(\.afterSeq) }

    func frames(
        origin: URL,
        accessToken: String,
        conversationId: String,
        clientInstanceId: String,
        afterSeq: Int
    ) -> AsyncStream<ConversationStreamEvent> {
        attaches.append(
            Attach(
                conversationId: conversationId,
                clientInstanceId: clientInstanceId,
                afterSeq: afterSeq
            )
        )
        accessTokensPresented.append(accessToken)
        onAttach?(afterSeq)

        let script: [ConversationStreamEvent]
        if scripts.count > 1 {
            script = scripts.removeFirst()
        } else {
            script = scripts.first ?? []
        }

        return AsyncStream { continuation in
            // Delivered one frame at a time with a suspension between them, rather than dumped
            // in synchronously. A stream that never suspends lets the frame loop drain the whole
            // script before anything else runs, which is not how a socket behaves and would hide
            // every interleaving the attach sequence depends on.
            self.current = continuation
            Task { @MainActor in
                for item in script {
                    await Task.yield()
                    continuation.yield(item)
                }
                if self.finishesAfterScript {
                    continuation.finish()
                }
            }
        }
    }

    static func hello(nextSeq: Int = 41, retainedFloorSeq: Int = 12) -> HelloFrame {
        HelloFrame(
            conversationId: "conversation-1",
            nextSeq: nextSeq,
            retainedFloorSeq: retainedFloorSeq,
            limits: .documentedDefaults,
            protocolVersion: ProtocolVersion.current
        )
    }
}

// MARK: - Event builders shared by the conversation tests

enum TestEvent {

    static func identity(
        submissionId: String? = nil,
        turnId: String? = nil
    ) -> EventIdentity {
        EventIdentity(
            principalId: "principal-1",
            channel: "first-party",
            conversationId: "conversation-1",
            submissionId: submissionId,
            turnId: turnId,
            attempt: 1
        )
    }

    static func accepted(
        _ submissionId: String,
        _ disposition: Disposition,
        seq: Int,
        eventId: String? = nil
    ) -> ConversationEvent {
        ConversationEvent(
            eventId: eventId ?? "accepted-\(submissionId)-\(seq)",
            seq: seq,
            kind: .submissionAccepted,
            identity: identity(submissionId: submissionId),
            payload: .submissionAccepted(SubmissionAcceptedPayload(disposition: disposition))
        )
    }

    static func started(_ submissionId: String, seq: Int) -> ConversationEvent {
        ConversationEvent(
            eventId: "started-\(submissionId)-\(seq)",
            seq: seq,
            kind: .turnStarted,
            identity: identity(submissionId: submissionId),
            payload: .turnStarted(TurnStartedPayload())
        )
    }

    static func progress(
        _ submissionId: String,
        seq: Int,
        activity: ProgressActivity = .typing,
        toolName: String? = nil
    ) -> ConversationEvent {
        ConversationEvent(
            eventId: "progress-\(submissionId)-\(seq)",
            seq: seq,
            kind: .turnProgress,
            identity: identity(submissionId: submissionId),
            payload: .turnProgress(
                TurnProgressPayload(activity: activity, toolName: toolName)
            )
        )
    }

    static func final(
        _ submissionId: String,
        seq: Int,
        text: String = "Answer.",
        completion: Completion = .completed,
        merged: [String] = [],
        eventId: String? = nil
    ) -> ConversationEvent {
        ConversationEvent(
            eventId: eventId ?? "final-\(submissionId)-\(seq)",
            seq: seq,
            kind: .turnFinal,
            identity: identity(submissionId: submissionId),
            payload: .turnFinal(
                TurnFinalPayload(
                    text: text,
                    completion: completion,
                    isPartial: false,
                    truncated: false,
                    mergedSubmissionIds: merged
                )
            )
        )
    }

    static func error(
        _ submissionId: String,
        seq: Int,
        code: String = "internal",
        message: String = "failed"
    ) -> ConversationEvent {
        ConversationEvent(
            eventId: "error-\(submissionId)-\(seq)",
            seq: seq,
            kind: .turnError,
            identity: identity(submissionId: submissionId),
            payload: .turnError(TurnErrorPayload(code: code, message: message))
        )
    }

    static func canceled(
        _ submissionId: String,
        seq: Int,
        reason: CancelReason = .user,
        merged: [String] = []
    ) -> ConversationEvent {
        ConversationEvent(
            eventId: "canceled-\(submissionId)-\(seq)",
            seq: seq,
            kind: .turnCanceled,
            identity: identity(submissionId: submissionId),
            payload: .turnCanceled(
                TurnCanceledPayload(reason: reason, mergedSubmissionIds: merged)
            )
        )
    }

    static func outcomeUnknown(
        _ submissionId: String,
        seq: Int,
        reason: OutcomeUnknownReason = .attemptAbandoned
    ) -> ConversationEvent {
        ConversationEvent(
            eventId: "unknown-\(submissionId)-\(seq)",
            seq: seq,
            kind: .turnOutcomeUnknown,
            identity: identity(submissionId: submissionId),
            payload: .turnOutcomeUnknown(TurnOutcomeUnknownPayload(reason: reason))
        )
    }

    static func controlAck(
        _ submissionId: String?,
        seq: Int,
        hadRunningTask: Bool
    ) -> ConversationEvent {
        ConversationEvent(
            eventId: "ack-\(seq)",
            seq: seq,
            kind: .controlAck,
            identity: identity(submissionId: submissionId),
            payload: .controlAck(
                ControlAckPayload(
                    target: "turn",
                    accepted: true,
                    hadRunningTask: hadRunningTask
                )
            )
        )
    }

    static func unknownKind(seq: Int, raw: String = "turn.something_new") -> ConversationEvent {
        ConversationEvent(
            eventId: "unknown-kind-\(seq)",
            seq: seq,
            kind: EventKind(rawValue: raw),
            identity: identity(),
            payload: .none
        )
    }
}
