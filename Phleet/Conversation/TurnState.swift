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
    /// When the server wrote it, when its event said.
    var at: Date?
}

/// Something the agent wrote mid-turn, before going on to a tool: part of what it said, shown in
/// the order it arrived, and never its answer.
struct InterimMessage: Equatable, Sendable, Identifiable {
    /// The `eventId` that carried it.
    let id: String
    let text: String
    let truncated: Bool
    var at: Date?
}

/// What a reply points at, as it is shown: who wrote the earlier message and how it starts.
struct QuotedMessage: Equatable, Sendable {
    enum Author: Equatable, Sendable {
        case you
        case agent
    }

    /// The `eventId` of the message. This is what a reply names to the server.
    let eventId: String
    let author: Author
    /// The message in one line, cut short. Empty when the message is no longer among those this
    /// device holds: the reply is still shown as one, with nothing to quote.
    let text: String

    /// How much of a message a quotation shows.
    static let maxLength = 140

    /// A message in one line, cut to `maxLength` with an ellipsis.
    static func excerpt(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// One submission and everything rendered with it.
struct SubmissionRecord: Equatable, Sendable, Identifiable {
    let id: String

    /// The person's words: what this device just sent, or the `submission.text` the server
    /// stored when it accepted the submission, which is how history read on another device or
    /// after a relaunch shows them.
    ///
    /// `nil` when no such event exists — a conversation from before the server kept one, or a
    /// message older than it retains. That is shown as unavailable, never as an empty message:
    /// `""` is a message sent with no text, and the two stay distinct.
    var text: String?

    /// What was sent with the words: images, described by the server or, for a message this
    /// device has just sent, by the upload that preceded it.
    var attachments: [AttachmentDescriptor] = []

    var state: SubmissionState = .sending

    /// Part of a group one turn answered together. Carried by every member of the group, so the
    /// interface never shows two replies where one turn produced one answer.
    var isAnsweredTogether = false

    /// The agent's reply, on the one member of a merged group that owns it.
    var reply: AgentReply?

    /// When the server stored the person's message, when its event said. `nil` for a message this
    /// device has just sent and for one whose `submission.text` was never seen.
    var sentAt: Date?

    /// The `eventId` of the `submission.text` that carries the words: what a reply to this
    /// message names. `nil` until that event has been seen.
    var textEventId: String?

    /// The `eventId` of the earlier message this one answers, when it answers one.
    var replyToEventId: String?

    /// What the agent wrote mid-turn while answering this, in the order it arrived.
    var interim: [InterimMessage] = []
}

/// A line that is not a message: a notice, a rejection, or the history-unavailable separator.
struct SystemLine: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case notice
        case rejected
        /// History expired beneath the cursor. Never dropped silently — silent loss is the one
        /// failure the person cannot detect.
        case replayGap
        /// A stop was asked for and nothing was running. The acknowledgement is the whole story:
        /// no terminal follows it, so without this line a stop would simply vanish.
        case nothingToStop
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

    /// When the running turn started, when the event that started it said. Cleared by its end.
    private(set) var turnStartedAt: Date?

    /// The tools the running turn has started, oldest first, as far as this device saw them.
    /// Progress events are not kept by the server for long, so a thread opened late in a turn
    /// shows a shorter trail. A list of starts, never a checklist: nothing says a tool finished.
    private(set) var trail: [String] = []

    /// How many tool names the trail keeps: a long turn shows its latest, not all of them.
    static let maxTrail = 60

    /// The last cancel acknowledgement seen. When `hadRunningTask` is `false`, it is the whole
    /// story and no terminal follows.
    private(set) var lastControlAck: ControlAckPayload?

    /// How many acknowledgements have been applied. A stop asked for from here is over when this
    /// moves on or the running turn ends, whichever comes first.
    private(set) var controlAckCount = 0

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

    /// Messages this device sent that no event has named yet: optimistic echoes under the
    /// identifier this device chose.
    ///
    /// The server records a submission under an identifier of its own, so the durable row for
    /// one of these arrives under a *different* id. Only an id still in this set is ever retired
    /// in favour of that row; one an event has named is itself durable and stays.
    private var localEchoIds: Set<String> = []

    /// A receipt's `acceptedSeq`, held until the `submission.text` at that seq arrives.
    private var localIdByAcceptedSeq: [Int: String] = [:]

    /// Every `submission.text` seen, by seq, for a receipt that arrives after its event.
    private var durableIdBySeq: [Int: String] = [:]

    /// The identifier this device chose, for a durable row its receipt linked it to. Kept so an
    /// explicit "Send again" on that row still finds the message it sent.
    private var localIdByDurableId: [String: String] = [:]

    init() {}

    var ignoredEventCount: Int { ignoredEventKinds.count }

    /// Submissions still working or attached with no terminal.
    var unresolvedSubmissionIds: [String] {
        submissionOrder.filter { records[$0]?.state.isUnresolved == true }
    }

    /// Whether a turn of this conversation is running: a submission that owns one, or one folded
    /// into it. What a stop would stop.
    var hasRunningTurn: Bool {
        records.values.contains { $0.state.isUnresolved }
    }

    func record(_ submissionId: String) -> SubmissionRecord? { records[submissionId] }

    var orderedRecords: [SubmissionRecord] { submissionOrder.compactMap { records[$0] } }

    /// Records a message this device just sent, before any event about it arrives.
    mutating func registerLocalSubmission(
        id: String,
        text: String,
        attachments: [AttachmentDescriptor] = [],
        replyToEventId: String? = nil
    ) {
        if records[id] == nil {
            localEchoIds.insert(id)
        }
        ensureRecord(id)
        records[id]?.text = text
        records[id]?.attachments = attachments
        records[id]?.replyToEventId = replyToEventId
    }

    /// The message a row answers, found among those this device holds. `nil` when it answers
    /// nothing. A message that has aged out of the thread, or was never loaded, is reported with
    /// empty text: the row is still a reply, with nothing to quote.
    func quoted(for record: SubmissionRecord) -> QuotedMessage? {
        guard let target = record.replyToEventId else { return nil }
        return message(eventId: target) ?? QuotedMessage(eventId: target, author: .agent, text: "")
    }

    /// One message of the thread, by the `eventId` that carried it.
    func message(eventId: String) -> QuotedMessage? {
        for id in submissionOrder {
            guard let record = records[id] else { continue }
            if record.textEventId == eventId {
                return QuotedMessage(
                    eventId: eventId,
                    author: .you,
                    text: QuotedMessage.excerpt(record.text ?? "")
                )
            }
            if let reply = record.reply, reply.id == eventId {
                return QuotedMessage(
                    eventId: eventId,
                    author: .agent,
                    text: QuotedMessage.excerpt(reply.text)
                )
            }
            if let said = record.interim.first(where: { $0.id == eventId }) {
                return QuotedMessage(
                    eventId: eventId,
                    author: .agent,
                    text: QuotedMessage.excerpt(said.text)
                )
            }
        }
        for entry in entries {
            if case .recoveredAnswer(let reply) = entry, reply.id == eventId {
                return QuotedMessage(
                    eventId: eventId,
                    author: .agent,
                    text: QuotedMessage.excerpt(reply.text)
                )
            }
        }
        return nil
    }

    /// Applies a successful send's receipt to its echo.
    ///
    /// `acceptedSeq` is the seq of that submission's `submission.text`, and the two can arrive in
    /// either order, so whichever comes second links them: the echo is retired and the durable
    /// row, which every later event about the submission names, is the one shown. Correlation is
    /// by that seq alone — never by text, which two separate submissions may share, and never by
    /// time.
    ///
    /// A `202` carries no `acceptedSeq`: the submission was already durable, so the echo is
    /// retired and the transcript's own row stands. No seq is invented for it.
    mutating func reconcileReceipt(localSubmissionId localId: String, acceptedSeq: Int?) {
        guard let acceptedSeq else {
            retireLocalEcho(localId)
            return
        }
        if let durableId = durableIdBySeq[acceptedSeq] {
            link(localId: localId, durableId: durableId)
        } else {
            localIdByAcceptedSeq[acceptedSeq] = localId
        }
    }

    /// The identifier this device sent a submission under, given the one a row is shown under.
    /// The same id when the row is not one of this device's linked messages.
    func localSubmissionId(for submissionId: String) -> String {
        localIdByDurableId[submissionId] ?? submissionId
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

        // An id an event names is the server's, so it is no longer only a local echo.
        if let named = event.identity.submissionId {
            localEchoIds.remove(named)
        }
        for named in event.payload.mergedSubmissionIds {
            localEchoIds.remove(named)
        }

        switch event.payload {
        case .submissionText(let payload):
            applySubmissionText(payload, event: event)
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
            if payload.activity == .tool, let tool = payload.toolName, !tool.isEmpty {
                trail.append(tool)
                if trail.count > Self.maxTrail {
                    trail.removeFirst(trail.count - Self.maxTrail)
                }
            }
        case .turnMessage(let payload):
            applyTurnMessage(payload, event: event)
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
                        isRecovered: true,
                        at: event.emittedDate
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
            controlAckCount += 1
            if payload.hadRunningTask == false {
                entries.append(
                    .systemLine(SystemLine(id: event.eventId, kind: .nothingToStop, text: ""))
                )
            }
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

    /// Puts the person's words on the row the server keeps them under.
    ///
    /// Text and nothing else: no state, no activity, no announcement. A submission's state is a
    /// function of its turn's events, so text that arrives after a terminal changes nothing
    /// that terminal decided, and text alone renders as sent with nothing back yet. A payload
    /// without a string, or an event naming no submission, is counted and ignored — never an
    /// empty message, and never a reason to erase text already known.
    private mutating func applySubmissionText(
        _ payload: SubmissionTextPayload,
        event: ConversationEvent
    ) {
        guard let id = event.identity.submissionId, !id.isEmpty, let text = payload.text else {
            ignoredEventKinds.append(event.kind.rawValue)
            return
        }
        ensureRecord(id)
        records[id]?.text = text
        records[id]?.attachments = payload.attachments
        records[id]?.sentAt = event.emittedDate
        records[id]?.textEventId = event.eventId
        // What the server stored is what the message answers. A message this device sent keeps
        // the reference it sent with, which the server confirmed before storing either.
        if let replyTo = payload.replyToEventId {
            records[id]?.replyToEventId = replyTo
        }

        guard let seq = event.seq else { return }
        durableIdBySeq[seq] = id
        if let localId = localIdByAcceptedSeq.removeValue(forKey: seq) {
            link(localId: localId, durableId: id)
        }
    }

    /// One submission, two identifiers: this device's echo gives way to the durable row.
    private mutating func link(localId: String, durableId: String) {
        guard localId != durableId else { return }
        localIdByDurableId[durableId] = localId
        retireLocalEcho(localId)
    }

    /// Removes an echo nothing on the server has named. Its identifiers stay with the model, so
    /// an explicit retry or "Send again" still reuses or follows them.
    private mutating func retireLocalEcho(_ id: String) {
        guard localEchoIds.remove(id) != nil else { return }
        records[id] = nil
        submissionOrder.removeAll { $0 == id }
        entries.removeAll { $0 == .submission(id) }
    }

    private mutating func applyAccepted(
        _ payload: SubmissionAcceptedPayload,
        event: ConversationEvent
    ) {
        guard let id = event.identity.submissionId else {
            ignoredEventKinds.append(event.kind.rawValue)
            return
        }

        // A stop is a submission of its own. It carries no words, the agent closes it as
        // `dropped` once it has acted, and nothing else ever names it — so a `dropped` for a
        // submission nothing has been seen of is a stop's own receipt, not a message that was
        // not run. Drawing a row for it would put a button press into the transcript, as a
        // message whose text is unavailable. A message that really was dropped has its
        // `submission.text` at a lower seq, so its row is already here.
        if payload.disposition == .dropped, records[id] == nil {
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
        // A new turn has done nothing yet: a tool an earlier one started is not this one's.
        turnStartedAt = event.emittedDate
        trail = []
    }

    /// Puts what the agent wrote mid-turn on the row of the message it is answering.
    ///
    /// Not a terminal and not the answer: the row's state is untouched, and the turn is still
    /// running until its own terminal says otherwise. Text that is empty once trimmed is nothing
    /// to show. A turn this device never saw start has no row to put it on, and it is counted
    /// and ignored rather than given an invented one.
    private mutating func applyTurnMessage(_ payload: TurnMessagePayload, event: ConversationEvent) {
        guard let id = event.identity.submissionId ?? hostSubmissionId, records[id] != nil,
              !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ignoredEventKinds.append(event.kind.rawValue)
            return
        }
        records[id]?.interim.append(
            InterimMessage(
                id: event.eventId,
                text: payload.text,
                truncated: payload.truncated ?? false,
                at: event.emittedDate
            )
        )
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
                isRecovered: false,
                at: event.emittedDate
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
        turnStartedAt = nil
        trail = []
    }

    /// The trail with runs of one tool folded: `Read, Read, Bash` is `Read ×2`, `Bash`.
    static func folded(_ trail: [String]) -> [(tool: String, count: Int)] {
        var out: [(tool: String, count: Int)] = []
        for tool in trail {
            if let last = out.last, last.tool == tool {
                out[out.count - 1].count += 1
            } else {
                out.append((tool: tool, count: 1))
            }
        }
        return out
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
