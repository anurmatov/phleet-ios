import Foundation

// MARK: - Tolerant enumerations
//
// Every enumeration on this boundary is append-only, so each one decodes an unrecognised raw
// value into a case that carries the string rather than throwing. `CancelReason` has both an
// `unknown` value on the wire *and* a fallback, which is exactly why the fallback here is named
// `unrecognized` everywhere: collapsing the two would make "the server said unknown" and "this
// build has not heard of this" indistinguishable.

/// What the runtime did with a submission.
enum Disposition: Hashable, Sendable {
    /// This submission owns a turn of its own.
    case ran
    /// Folded into a turn that was already running. Never owns a turn, never owns a spinner.
    case injected
    /// Durably accepted; the agent is busy with something else.
    case queued
    /// Durably accepted and terminally refused — the queue was full.
    case queueFull
    /// Durably accepted and terminally dropped.
    case dropped
    case unrecognized(String)

    init(rawValue: String) {
        switch rawValue {
        case "ran": self = .ran
        case "injected": self = .injected
        case "queued": self = .queued
        case "queue_full": self = .queueFull
        case "dropped": self = .dropped
        default: self = .unrecognized(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .ran: return "ran"
        case .injected: return "injected"
        case .queued: return "queued"
        case .queueFull: return "queue_full"
        case .dropped: return "dropped"
        case .unrecognized(let raw): return raw
        }
    }

    /// Whether the submission is already finished by the disposition alone.
    ///
    /// `queue_full` and `dropped` arrive on a request that returned `201`. They are decisions,
    /// not failures: the submission is durably accepted and terminally resolved, and resending
    /// on one creates a second submission for work already decided.
    var isTerminal: Bool {
        switch self {
        case .queueFull, .dropped: return true
        default: return false
        }
    }
}

/// How a turn finished.
enum Completion: Hashable, Sendable {
    case completed
    /// The agent produced no answer. `text` is legitimately empty on this one.
    case idle
    case incomplete
    case unrecognized(String)

    init(rawValue: String) {
        switch rawValue {
        case "completed": self = .completed
        case "idle": self = .idle
        case "incomplete": self = .incomplete
        default: self = .unrecognized(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .completed: return "completed"
        case .idle: return "idle"
        case .incomplete: return "incomplete"
        case .unrecognized(let raw): return raw
        }
    }
}

/// Who ended a turn.
enum CancelReason: Hashable, Sendable {
    case user
    case operatorAction
    case bridge
    /// The server said `unknown` — a real, specified value.
    case unknown
    /// This build has never heard of the value the server sent.
    case unrecognized(String)

    init(rawValue: String) {
        switch rawValue {
        case "user": self = .user
        case "operator": self = .operatorAction
        case "bridge": self = .bridge
        case "unknown": self = .unknown
        default: self = .unrecognized(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .user: return "user"
        case .operatorAction: return "operator"
        case .bridge: return "bridge"
        case .unknown: return "unknown"
        case .unrecognized(let raw): return raw
        }
    }

    /// Whether this client asked for the cancellation.
    ///
    /// One agent is one provider process shared across channels, so a turn started here can be
    /// ended by an operator elsewhere. That is a property of a shared session, not a fault of
    /// this client, and the UI must absorb it without an error treatment.
    var wasInitiatedHere: Bool { self == .user }
}

/// Why a turn's outcome cannot be established.
enum OutcomeUnknownReason: Hashable, Sendable {
    case turnReaped
    case terminalEventOversize
    /// The reconciler abandoned an attempt whose lease expired.
    case attemptAbandoned
    case unrecognized(String)

    init(rawValue: String) {
        switch rawValue {
        case "turn_reaped": self = .turnReaped
        case "terminal_event_oversize": self = .terminalEventOversize
        case "attempt_abandoned": self = .attemptAbandoned
        default: self = .unrecognized(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .turnReaped: return "turn_reaped"
        case .terminalEventOversize: return "terminal_event_oversize"
        case .attemptAbandoned: return "attempt_abandoned"
        case .unrecognized(let raw): return raw
        }
    }
}

/// What a running turn is doing. There is no text in any of these.
enum ProgressActivity: Hashable, Sendable {
    /// The agent is producing an answer. **Not** an incremental-text event — see
    /// `TurnProgressPayload`.
    case typing
    case tool
    case unrecognized(String)

    init(rawValue: String) {
        switch rawValue {
        case "typing": self = .typing
        case "tool": self = .tool
        default: self = .unrecognized(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .typing: return "typing"
        case .tool: return "tool"
        case .unrecognized(let raw): return raw
        }
    }
}

// MARK: - Payloads

struct SubmissionAcceptedPayload: Equatable, Sendable {
    let disposition: Disposition
}

/// Deliberately empty. `turn.started` says a turn began and nothing else.
struct TurnStartedPayload: Equatable, Sendable {}

/// An activity signal with **no text in it**.
///
/// v1 has no incremental assistant-text event, so there is nothing to feed a token-by-token
/// effect. Tool completion is not client-visible on any provider either: `toolName` says a tool
/// started and nothing ever says it finished, so a checklist would render ticks no event can
/// produce.
struct TurnProgressPayload: Equatable, Sendable {
    let activity: ProgressActivity
    let toolName: String?
}

struct TurnNoticePayload: Equatable, Sendable {
    let text: String
    let truncated: Bool?
}

struct TurnRecoveredAnswerPayload: Equatable, Sendable {
    let text: String
    let truncated: Bool?
}

struct TurnFinalPayload: Equatable, Sendable {
    let text: String
    let completion: Completion
    let isPartial: Bool?
    let truncated: Bool?
    /// Every submission this turn answered, including the host.
    ///
    /// A submission folded into a running turn never receives a terminal whose
    /// `identity.submissionId` is its own; this list is the only thing that closes it.
    let mergedSubmissionIds: [String]
}

struct TurnErrorPayload: Equatable, Sendable {
    let code: String
    let message: String
}

struct TurnCanceledPayload: Equatable, Sendable {
    let reason: CancelReason
    let mergedSubmissionIds: [String]
}

struct TurnOutcomeUnknownPayload: Equatable, Sendable {
    let reason: OutcomeUnknownReason
}

/// A cancel acknowledgement.
///
/// This slice ships no cancel UI, so an ack can only originate from somewhere else — another
/// channel, or an operator. When `hadRunningTask` is `false` there was nothing to stop, no
/// terminal follows, and the ack is the whole story.
struct ControlAckPayload: Equatable, Sendable {
    let target: String?
    let accepted: Bool?
    let hadRunningTask: Bool?
}

struct ProtocolRejectedPayload: Equatable, Sendable {
    let code: String
    let message: String?
}

/// History expired beneath the cursor. Rendering this is not optional: silent loss is the one
/// failure the person on the other end cannot detect.
struct ReplayGapPayload: Equatable, Sendable {
    let fromSeq: Int?
    let toSeq: Int?
    let retainedFloorSeq: Int?
}

// MARK: - The payload union

enum EventPayload: Equatable, Sendable {
    case submissionAccepted(SubmissionAcceptedPayload)
    case turnStarted(TurnStartedPayload)
    case turnProgress(TurnProgressPayload)
    case turnNotice(TurnNoticePayload)
    case turnRecoveredAnswer(TurnRecoveredAnswerPayload)
    case turnFinal(TurnFinalPayload)
    case turnError(TurnErrorPayload)
    case turnCanceled(TurnCanceledPayload)
    case turnOutcomeUnknown(TurnOutcomeUnknownPayload)
    case controlAck(ControlAckPayload)
    case protocolRejected(ProtocolRejectedPayload)
    case replayGap(ReplayGapPayload)
    /// Carried for an unrecognised kind, and for a recognised kind whose payload is absent.
    case none

    /// The submissions a terminal closes beyond the one it names, or an empty list.
    var mergedSubmissionIds: [String] {
        switch self {
        case .turnFinal(let payload): return payload.mergedSubmissionIds
        case .turnCanceled(let payload): return payload.mergedSubmissionIds
        default: return []
        }
    }
}
