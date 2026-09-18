import Foundation

/// The event kinds this build renders, plus a tolerant case for everything else.
///
/// Enum values on the wire are append-only: a future minor adds kinds this build has never
/// seen, and a client that throws on one stops rendering a conversation it could otherwise
/// still show. So decoding an unrecognised kind is an ordinary outcome — `.unknown` — and the
/// renderer ignores it and counts it.
enum EventKind: Hashable, Sendable {
    case submissionAccepted
    case turnStarted
    case turnProgress
    case turnNotice
    case turnRecoveredAnswer
    case turnFinal
    case turnError
    case turnCanceled
    case turnOutcomeUnknown
    case controlAck
    case protocolRejected
    case conversationReplayGap

    /// A kind this build does not know. Ignored without error, never rendered.
    case unknown(String)

    /// The twelve kinds this slice renders, in the order the issue's allowlist states them.
    static let rendered: [EventKind] = [
        .submissionAccepted,
        .turnStarted,
        .turnProgress,
        .turnNotice,
        .turnRecoveredAnswer,
        .turnFinal,
        .turnError,
        .turnCanceled,
        .turnOutcomeUnknown,
        .controlAck,
        .protocolRejected,
        .conversationReplayGap
    ]

    init(rawValue: String) {
        switch rawValue {
        case "submission.accepted": self = .submissionAccepted
        case "turn.started": self = .turnStarted
        case "turn.progress": self = .turnProgress
        case "turn.notice": self = .turnNotice
        case "turn.recovered_answer": self = .turnRecoveredAnswer
        case "turn.final": self = .turnFinal
        case "turn.error": self = .turnError
        case "turn.canceled": self = .turnCanceled
        case "turn.outcome_unknown": self = .turnOutcomeUnknown
        case "control.ack": self = .controlAck
        case "protocol.rejected": self = .protocolRejected
        case "conversation.replay_gap": self = .conversationReplayGap
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .submissionAccepted: return "submission.accepted"
        case .turnStarted: return "turn.started"
        case .turnProgress: return "turn.progress"
        case .turnNotice: return "turn.notice"
        case .turnRecoveredAnswer: return "turn.recovered_answer"
        case .turnFinal: return "turn.final"
        case .turnError: return "turn.error"
        case .turnCanceled: return "turn.canceled"
        case .turnOutcomeUnknown: return "turn.outcome_unknown"
        case .controlAck: return "control.ack"
        case .protocolRejected: return "protocol.rejected"
        case .conversationReplayGap: return "conversation.replay_gap"
        case .unknown(let raw): return raw
        }
    }

    /// Whether this build renders the kind. `false` is not an error — see the type's note.
    var isRendered: Bool {
        if case .unknown = self { return false }
        return true
    }

    /// Whether the kind ends a turn.
    ///
    /// `control.ack` is deliberately absent: a cancel arriving after a terminal answers with
    /// `hadRunningTask: false`, and treating that as a terminal would synthesise a second one.
    var isTerminal: Bool {
        switch self {
        case .turnFinal, .turnError, .turnCanceled, .turnOutcomeUnknown: return true
        default: return false
        }
    }
}

extension EventKind: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
