import Foundation

/// What one submission is doing.
///
/// Each submission's state is a function of *which* kinds have arrived for it, never of the
/// order they arrived in. `turn.started` legitimately arrives before `submission.accepted` and
/// takes the lower `seq`, so a machine that waits for `accepted` before rendering a running turn
/// hangs on the ordinary path.
enum SubmissionState: Equatable, Sendable {

    /// Sent, nothing back yet.
    case sending

    /// `queued`: durably accepted, and the agent is busy with something else entirely. Rendered
    /// as **waiting**, never as typing — one provider process serves every channel, and "typing"
    /// would assert it is working on *this* message.
    case waiting

    /// Owns a running turn. The only state that owns a progress indicator.
    case working

    /// `injected`: folded into a turn that was already running. Sent, and being answered with
    /// the current turn. It has no turn of its own to indicate, and no event exists that could
    /// ever stop a spinner given to it.
    case attached(hostSubmissionId: String?)

    /// `queue_full` or `dropped`: durably accepted and terminally resolved without running.
    /// Never a send failure, and never automatically resent.
    case notRun(Disposition)

    case completed(TurnFinalPayload)
    case failed(TurnErrorPayload)
    case canceled(TurnCanceledPayload)

    /// Genuinely unknown: the work may have run in full, in part, or not at all. Its own third
    /// state — not the success treatment, not the error treatment, and never a spinner.
    case outcomeUnknown(OutcomeUnknownReason)

    var isTerminal: Bool {
        switch self {
        case .notRun, .completed, .failed, .canceled, .outcomeUnknown: return true
        case .sending, .waiting, .working, .attached: return false
        }
    }

    /// Only a submission that owns a running turn owns an indicator.
    var ownsProgressIndicator: Bool { self == .working }

    /// Working or attached with no terminal in sight — what the no-hang invariant forbids once a
    /// sequence has ended with a terminal.
    var isUnresolved: Bool {
        switch self {
        case .working, .attached: return true
        default: return false
        }
    }
}

/// The agent's answer, as one bubble.
struct AgentReply: Equatable, Sendable, Identifiable {
    /// The `eventId` that produced it.
    let id: String
    let text: String
    let completion: Completion
    let isPartial: Bool
    let truncated: Bool
    /// Recovered from an earlier turn. It arrives with no visible question attached and reads as
    /// a duplicate unless it is labelled.
    let isRecovered: Bool
}

/// One submission and everything rendered with it.
struct SubmissionRecord: Equatable, Sendable, Identifiable {
    let id: String

    /// The text this device sent, when this device sent it. A submission replayed from history
    /// has none: catch-up carries the agent's side of a turn, not the words that started it, and
    /// this slice keeps no local transcript.
    var text: String?

    var state: SubmissionState = .sending

    /// Part of a group one turn answered together. Carried by every member of the group, so the
    /// interface never shows two replies where one turn produced one answer.
    var isAnsweredTogether = false

    /// The agent's reply, on the one member of a merged group that owns it.
    var reply: AgentReply?
}

/// A line that is not a message: a notice, a rejection, or the history-unavailable separator.
struct SystemLine: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case notice
        case rejected
        /// History expired beneath the cursor. Never dropped silently — silent loss is the one
        /// failure the person cannot detect.
        case replayGap
    }

    let id: String
    let kind: Kind
    let text: String
}

/// What the transcript shows, in the order it arrived.
enum TranscriptEntry: Equatable, Sendable, Identifiable {
    /// Refers to a `SubmissionRecord` by id so the entry list stays stable as the record changes.
    case submission(String)
    case systemLine(SystemLine)
    case recoveredAnswer(AgentReply)

    var id: String {
        switch self {
        case .submission(let submissionId): return "submission:" + submissionId
        case .systemLine(let line): return "system:" + line.id
        case .recoveredAnswer(let reply): return "recovered:" + reply.id
        }
    }
}

/// What a running turn is doing right now. One indicator, never a list.
struct TurnActivity: Equatable, Sendable {
    let submissionId: String?
    let activity: ProgressActivity
    /// A tool *started*. Nothing on any provider says a tool finished, so a checklist would
    /// render ticks no event can produce.
    let toolName: String?
}

/// A terminal worth announcing to assistive technology.
///
/// `turn.outcome_unknown` must announce: a spinner that quietly stops is unreadable to
/// VoiceOver, and re-running work that already ran is exactly the misread it causes.
struct TerminalAnnouncement: Equatable, Sendable, Identifiable {
    let id: String
    let submissionId: String?
    let kind: EventKind
}

/// The transcript, as a value.
///
/// Deliberately a plain struct with no networking in it: every rendering rule in the issue is
/// then assertable by feeding it events, which is what makes the fixture replay in
/// `MergedTurnClosureTests` possible at all.
struct TurnStateMachine: Equatable, Sendable {

    private(set) var submissionOrder: [String] = []
    private(set) var records: [String: SubmissionRecord] = [:]
    private(set) var entries: [TranscriptEntry] = []
    private(set) var activity: TurnActivity?

    /// The last cancel acknowledgement seen. This slice ships no cancel UI, so one can only
    /// originate elsewhere — and when `hadRunningTask` is `false`, it is the whole story and no
    /// terminal follows.
    private(set) var lastControlAck: ControlAckPayload?

    /// Kinds this build does not render, counted rather than dropped invisibly.
    private(set) var ignoredEventKinds: [String] = []

    /// Merged ids naming submissions this client never saw. Ignored, never synthesised.
    private(set) var ignoredMergedIds: [String] = []

    private(set) var pendingAnnouncements: [TerminalAnnouncement] = []

    private var appliedEventIds: Set<String> = []
    private var hostSubmissionId: String?
    private var attachedByHost: [String: [String]] = [:]

    /// Submissions dispositioned `injected` before this client ever saw which turn was running.
    ///
    /// It happens on any cold start that catches up mid-turn, or when the accepted event for the
    /// host is pruned. They are still attached to *a* running turn — the runtime chose that, not
    /// the client — so the next terminal closes them. Leaving them out is the exact hang that
    /// closure rules exist to prevent, and attributing them to the only turn evidence available
    /// is the best reading there is.
    private var attachedWithUnknownHost: [String] = []

    init() {}

    var ignoredEventCount: Int { ignoredEventKinds.count }

    /// Submissions still working or attached with no terminal.
    var unresolvedSubmissionIds: [String] {
        submissionOrder.filter { records[$0]?.state.isUnresolved == true }
    }

    func record(_ submissionId: String) -> SubmissionRecord? { records[submissionId] }

    var orderedRecords: [SubmissionRecord] { submissionOrder.compactMap { records[$0] } }

    /// Records a message this device just sent, before any event about it arrives.
    mutating func registerLocalSubmission(id: String, text: String) {
        ensureRecord(id)
        records[id]?.text = text
    }

    /// Renders the `gap` field a catch-up response carried.
    ///
    /// The response-level `gap` is a different carrier from a `conversation.replay_gap` event and
    /// arrives first in the response; both mean the same thing to a reader and both must be
    /// shown. Dropping either is silent history loss, which is the one failure the person on the
    /// other end cannot detect.
    mutating func appendHistoryGap(id: String) {
        guard !appliedEventIds.contains(id) else { return }
        appliedEventIds.insert(id)
        entries.append(.systemLine(SystemLine(id: id, kind: .replayGap, text: "")))
    }

    mutating func consumeAnnouncements() -> [TerminalAnnouncement] {
        defer { pendingAnnouncements.removeAll() }
        return pendingAnnouncements
    }

    /// Applies one event.
    ///
    /// - Returns: `false` when the event was already applied. Dedupe is on `eventId`, not `seq`,
    ///   because `conversation.replay_gap` carries `seq: null`.
    @discardableResult
    mutating func apply(_ event: ConversationEvent) -> Bool {
        guard !appliedEventIds.contains(event.eventId) else { return false }
        appliedEventIds.insert(event.eventId)

        guard event.kind.isRendered else {
            ignoredEventKinds.append(event.kind.rawValue)
            return true
        }

        switch event.payload {
        case .submissionAccepted(let payload):
            applyAccepted(payload, event: event)
        case .turnStarted:
            applyTurnStarted(event: event)
        case .turnProgress(let payload):
            activity = TurnActivity(
                submissionId: event.identity.submissionId ?? hostSubmissionId,
                activity: payload.activity,
                toolName: payload.toolName
            )
        case .turnNotice(let payload):
            entries.append(
                .systemLine(SystemLine(id: event.eventId, kind: .notice, text: payload.text))
            )
        case .turnRecoveredAnswer(let payload):
            entries.append(
                .recoveredAnswer(
                    AgentReply(
                        id: event.eventId,
                        text: payload.text,
                        completion: .completed,
                        isPartial: false,
                        truncated: payload.truncated ?? false,
                        isRecovered: true
                    )
                )
            )
        case .turnFinal, .turnError, .turnCanceled, .turnOutcomeUnknown:
            applyTerminal(event: event)
        case .controlAck(let payload):
            // No terminal is synthesised here, in either direction. A cancel arriving after a
            // terminal answers `hadRunningTask: false`, and inventing a second terminal for it
            // is how a resolved turn reopens.
            lastControlAck = payload
        case .protocolRejected(let payload):
            entries.append(
                .systemLine(SystemLine(id: event.eventId, kind: .rejected, text: payload.code))
            )
        case .replayGap:
            entries.append(
                .systemLine(SystemLine(id: event.eventId, kind: .replayGap, text: ""))
            )
        case .none:
            ignoredEventKinds.append(event.kind.rawValue)
        }

        return true
    }

    // MARK: - Per-kind application

    private mutating func applyAccepted(
        _ payload: SubmissionAcceptedPayload,
        event: ConversationEvent
    ) {
        guard let id = event.identity.submissionId else {
            ignoredEventKinds.append(event.kind.rawValue)
            return
        }
        ensureRecord(id)

        // A `submission.accepted` arriving after a terminal must not reopen the turn.
        guard records[id]?.state.isTerminal == false else { return }

        switch payload.disposition {
        case .ran:
            records[id]?.state = .working
            hostSubmissionId = id
        case .injected:
            let host = hostSubmissionId
            records[id]?.state = .attached(hostSubmissionId: host)
            if let host {
                attachedByHost[host, default: []].append(id)
            } else {
                attachedWithUnknownHost.append(id)
            }
        case .queued:
            records[id]?.state = .waiting
        case .queueFull, .dropped:
            records[id]?.state = .notRun(payload.disposition)
        case .unrecognized:
            // Leave the state alone. A disposition this build has not heard of is not grounds to
            // invent a rendering for it, and the turn's terminal still closes the submission.
            break
        }
    }

    private mutating func applyTurnStarted(event: ConversationEvent) {
        guard let id = event.identity.submissionId else {
            ignoredEventKinds.append(event.kind.rawValue)
            return
        }
        ensureRecord(id)
        guard records[id]?.state.isTerminal == false else { return }

        records[id]?.state = .working
        hostSubmissionId = id
        if attachedByHost[id] == nil {
            attachedByHost[id] = []
        }
    }

    private mutating func applyTerminal(event: ConversationEvent) {
        let hostId = event.identity.submissionId ?? hostSubmissionId

        // An event whose `identity` names a submission is first-hand evidence that submission
        // exists, so the terminal registers it if this is the first thing seen about it. Catch-up
        // on a cold start routinely begins mid-turn — the earlier events were pruned — and
        // ignoring the terminal there would drop the agent's answer entirely.
        //
        // This is deliberately not true of `mergedSubmissionIds`, which are second-hand
        // references: an id listed there and never otherwise seen is ignored rather than
        // synthesised.
        if let hostId {
            ensureRecord(hostId)
        }

        // `turn.error` and `turn.outcome_unknown` carry no merged list, so attachment is the
        // only thing that closes a message folded into the turn they end.
        var attached = hostId.map { attachedByHost[$0] ?? [] } ?? []
        attached.append(contentsOf: attachedWithUnknownHost)
        if event.identity.submissionId == nil, let fallbackHost = hostSubmissionId {
            attached.append(fallbackHost)
        }

        let closure = MergedTurnClosure.closure(
            for: event,
            knownSubmissionIdsInSendOrder: submissionOrder,
            attachedSubmissionIds: attached
        )
        ignoredMergedIds.append(contentsOf: closure.unknownMergedIds)

        guard !closure.closedSubmissionIds.isEmpty else {
            ignoredEventKinds.append(event.kind.rawValue)
            return
        }

        let terminalState = SubmissionState(terminalOf: event)
        var newlyClosed: Set<String> = []

        for id in closure.closedSubmissionIds {
            // The first terminal wins and is the only one. Later terminals for the same
            // submission are ignored rather than overwriting a resolved state.
            guard records[id]?.state.isTerminal == false else { continue }
            records[id]?.state = terminalState
            records[id]?.isAnsweredTogether = closure.isMergedGroup
            newlyClosed.insert(id)
        }

        if case .turnFinal(let payload) = event.payload,
           let owner = closure.replyOwnerId,
           newlyClosed.contains(owner) {
            records[owner]?.reply = AgentReply(
                id: event.eventId,
                text: payload.text,
                completion: payload.completion,
                isPartial: payload.isPartial ?? false,
                truncated: payload.truncated ?? false,
                isRecovered: false
            )
        }

        if !newlyClosed.isEmpty {
            pendingAnnouncements.append(
                TerminalAnnouncement(
                    id: event.eventId,
                    submissionId: closure.replyOwnerId,
                    kind: event.kind
                )
            )
        }

        if let hostId {
            attachedByHost[hostId] = []
        }
        attachedWithUnknownHost.removeAll()
        if let current = hostSubmissionId, closure.closedSubmissionIds.contains(current) {
            hostSubmissionId = nil
        }
        activity = nil
    }

    private mutating func ensureRecord(_ id: String) {
        guard records[id] == nil else { return }
        records[id] = SubmissionRecord(id: id)
        submissionOrder.append(id)
        entries.append(.submission(id))
    }
}

extension SubmissionState {
    fileprivate init(terminalOf event: ConversationEvent) {
        switch event.payload {
        case .turnFinal(let payload): self = .completed(payload)
        case .turnError(let payload): self = .failed(payload)
        case .turnCanceled(let payload): self = .canceled(payload)
        case .turnOutcomeUnknown(let payload): self = .outcomeUnknown(payload.reason)
        default: self = .sending
        }
    }
}
