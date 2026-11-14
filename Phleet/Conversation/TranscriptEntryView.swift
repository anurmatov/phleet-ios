import SwiftUI
import UIKit

/// One submission and its answer: an accessibility **container** holding addressable parts.
///
/// It was one merged element until #9. `.accessibilityElement(children: .ignore)` collapses the
/// subtree into a single opaque element, and a body that is not its own element cannot be
/// long-pressed — not by a person using VoiceOver, and not by a UI test, which is why #7's
/// `.textSelection(.enabled)` shipped with nothing able to observe that it did nothing. The
/// container is now `.contain`, so each body keeps its own element and its own selection.
///
/// What that costs: VoiceOver reads the entry as speaker-and-text, then state, rather than one
/// sentence. What it buys is the ability to reach a single body — which is the whole point of
/// selection, and the same thing a sighted person gets from a long press.
///
/// There is deliberately **no** `.contextMenu` on the bodies: it claims the long press that
/// selection needs. Copy-the-whole-block stays reachable two ways — Select All in the system
/// menu the selection itself raises, and a named accessibility action for VoiceOver.
///
/// The `outcome_unknown` panel is a sibling rather than a child: it carries an action.
struct TranscriptEntryView: View {

    let record: SubmissionRecord
    let activity: TurnActivity?
    /// Where the bytes of this thread's images are read from. `nil` where there is nowhere, and
    /// an image is then named rather than drawn.
    var images: AttachmentImages?
    let sendAgain: () -> Void

    /// The earlier message this one answers, when it answers one.
    var quoted: QuotedMessage?
    /// What the agent is called, for naming whose message a reply answers.
    var agentName: String = ""
    /// When the running turn started and the tools it has started so far. Shown beside the
    /// indicator of the row that owns it.
    var turnStartedAt: Date?
    var trail: [String] = []
    /// Starts a reply to one of this row's messages. `nil` where replying is not offered.
    var onReply: ((QuotedMessage) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content

            if case .outcomeUnknown(let reason) = record.state {
                OutcomeUnknownView(reason: reason, sendAgain: sendAgain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifier.conversationEntry.identifier)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quoted {
                QuotedMessageView(quoted: quoted, agentName: agentName)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            humanBody

            stateRow

            ForEach(record.interim) { said in
                interimView(said)
            }

            if record.state.ownsProgressIndicator {
                ProgressIndicatorView(
                    activity: activity,
                    reduceMotion: reduceMotion,
                    startedAt: turnStartedAt,
                    trail: trail
                )
            }

            if let reply = record.reply {
                replyView(reply)
            }
        }
    }

    /// The person's own words, or a plain statement of why they are not here.
    ///
    /// A reply with no question above it reads as the agent talking to itself, so a missing
    /// message is said rather than left blank — without guessing at it, without claiming it was
    /// deleted, and without offering to send anything. A message sent with no text is a
    /// different fact from one whose text is unavailable, and is said differently.
    @ViewBuilder
    private var humanBody: some View {
        if !record.attachments.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(record.attachments) { attachment in
                    SentAttachmentView(attachment: attachment, images: images)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }

        if let text = record.text, text.isEmpty, !record.attachments.isEmpty {
            // Images sent with no words: the images are the message, and "Empty message" under
            // them would be wrong.
            EmptyView()
        } else if let text = record.text, !text.isEmpty {
            selectableBody(
                text,
                speaker: "conversation.speaker.you",
                identifier: .conversationMessageBody,
                copyActionKey: "conversation.copy.message"
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else if record.text == nil {
            statedBody(
                "conversation.message.unavailable",
                identifier: .conversationMessageUnavailable
            )
        } else {
            statedBody("conversation.message.empty", identifier: .conversationMessageEmpty)
        }
    }

    /// This app's own copy in the body's place: not selectable and not copyable, because it is
    /// not something anyone wrote.
    private func statedBody(
        _ key: String.LocalizationValue,
        identifier: AccessibilityIdentifier
    ) -> some View {
        let said = String(localized: key)
        return Text(verbatim: said)
            .font(.body.italic())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier(identifier.identifier)
            .accessibilityLabel(String(localized: "conversation.speaker.you") + ". " + said)
    }

    /// State and the answered-together marker as one spoken element: neither is worth stopping
    /// on separately, and both are chrome rather than content.
    private var stateRow: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if let onReply, let eventId = record.textEventId {
                    replyButton {
                        onReply(
                            QuotedMessage(
                                eventId: eventId,
                                author: .you,
                                text: QuotedMessage.excerpt(record.text ?? "")
                            )
                        )
                    }
                }
                Image(systemName: stateSymbol)
                    .imageScale(.small)
                Text(stateKey)
                    .font(.caption)
                if let sentAt = record.sentAt {
                    Text(sentAt, style: .time)
                        .font(.caption)
                        .monospacedDigit()
                }
            }

            if record.isAnsweredTogether {
                Text("conversation.state.answeredTogether")
                    .font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stateSpokenLabel)
    }

    /// A selectable message body.
    ///
    /// The identifier is what makes a long press reachable — to a UI test, and to anyone
    /// navigating by element. The copy action is the VoiceOver equivalent of Select All followed
    /// by Copy, which is the path a long press opens for everyone else.
    private func selectableBody(
        _ text: String,
        speaker: String.LocalizationValue,
        identifier: AccessibilityIdentifier,
        copyActionKey: LocalizedStringKey
    ) -> some View {
        Text(verbatim: text)
            .font(.body)
            .textSelection(.enabled)
            .accessibilityIdentifier(identifier.identifier)
            .accessibilityLabel(String(localized: speaker) + ". " + text)
            .accessibilityAction(named: Text(copyActionKey)) { putOnPasteboard(text) }
    }

    /// An agent's reply, rendered as Markdown (`ReplyMarkdown`): text, lists, code and tables,
    /// never HTML. The person's own messages stay plain text, exactly as typed.
    ///
    /// What is spoken and what the copy action takes is the rendered text, without the Markdown
    /// punctuation — the same characters a long press and Select All would copy.
    private func replyBody(_ text: String) -> some View {
        MarkdownBlocksView(
            text: text,
            identifier: .conversationReplyBody,
            spokenPrefix: String(localized: "conversation.speaker.agent"),
            copyActionKey: "conversation.copy.reply"
        )
    }

    private func replyView(_ reply: AgentReply) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if reply.isRecovered {
                Text("conversation.recovered")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if reply.text.isEmpty {
                // `completion: "idle"` legitimately carries empty text. An empty bubble would
                // read as a rendering fault.
                Text("conversation.reply.empty")
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
            } else {
                replyBody(reply.text)
            }
            if reply.completion != .completed || reply.isPartial || reply.truncated {
                Text(qualifierKey(for: reply))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            messageFooter(at: reply.at, eventId: reply.id, text: reply.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifier.conversationAgentReply.identifier)
    }

    /// Something the agent wrote mid-turn, before going on to a tool. Set apart from an answer by
    /// a rule down its leading edge and a quieter colour: it is part of the thread, not the reply.
    private func interimView(_ said: InterimMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownBlocksView(
                text: said.text,
                identifier: .conversationInterim,
                spokenPrefix: String(localized: "conversation.speaker.agent"),
                copyActionKey: "conversation.copy.reply"
            )
            .foregroundStyle(.secondary)
            if said.truncated {
                Text("conversation.interim.truncated")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            messageFooter(at: said.at, eventId: said.id, text: said.text)
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.quaternary)
                .frame(width: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Under something the agent wrote: when, and a way to answer it.
    @ViewBuilder
    private func messageFooter(at: Date?, eventId: String, text: String) -> some View {
        if at != nil || (onReply != nil && !text.isEmpty) {
            HStack(spacing: 10) {
                if let at {
                    Text(at, style: .time)
                        .font(.caption2)
                        .monospacedDigit()
                }
                if let onReply, !text.isEmpty {
                    replyButton {
                        onReply(
                            QuotedMessage(
                                eventId: eventId,
                                author: .agent,
                                text: QuotedMessage.excerpt(text)
                            )
                        )
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    /// A small button, so it does not take the long press a message's text needs for selection.
    private func replyButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrowshape.turn.up.left")
                .imageScale(.small)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityIdentifier.conversationReply.identifier)
        .accessibilityLabel(AccessibilityIdentifier.conversationReply.localizedLabel)
    }

    // MARK: - Pasteboard

    private func putOnPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    // MARK: - Copy

    private func qualifierKey(for reply: AgentReply) -> LocalizedStringKey {
        if reply.truncated { return "conversation.reply.truncated" }
        if reply.isPartial { return "conversation.reply.partial" }
        if reply.completion == .idle { return "conversation.reply.idle" }
        return "conversation.reply.incomplete"
    }

    private var stateKey: LocalizedStringKey {
        switch record.state {
        case .sending: return "conversation.state.sending"
        case .waiting: return "conversation.state.waiting"
        case .working: return "conversation.state.working"
        case .attached: return "conversation.state.attached"
        case .notRun: return "conversation.state.notRun"
        case .completed: return "conversation.state.completed"
        case .failed: return "conversation.state.failed"
        case .canceled(let payload):
            return payload.reason.wasInitiatedHere
                ? "conversation.state.canceled"
                : "conversation.state.canceledElsewhere"
        case .outcomeUnknown: return "conversation.state.outcomeUnknown"
        }
    }

    /// Success, failure and `outcome_unknown` are distinguishable without hue: the three-way
    /// distinction is the safety-critical one.
    private var stateSymbol: String {
        switch record.state {
        case .sending: return "arrow.up.circle"
        case .waiting: return "clock"
        case .working: return "ellipsis.circle"
        case .attached: return "arrow.turn.up.right"
        case .notRun: return "tray.slash"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .canceled: return "xmark.circle"
        case .outcomeUnknown: return "questionmark.circle"
        }
    }

    /// The chrome element's spoken text. The bodies carry their own speaker and content now, so
    /// this is state and the answered-together marker and nothing else.
    private var stateSpokenLabel: String {
        var parts = [String(localized: stateLabelResource)]

        if record.isAnsweredTogether {
            parts.append(String(localized: "conversation.state.answeredTogether"))
        }
        return parts.joined(separator: ". ")
    }

    private var stateLabelResource: String.LocalizationValue {
        switch record.state {
        case .sending: return "conversation.state.sending"
        case .waiting: return "conversation.state.waiting"
        case .working: return "conversation.state.working"
        case .attached: return "conversation.state.attached"
        case .notRun: return "conversation.state.notRun"
        case .completed: return "conversation.state.completed"
        case .failed: return "conversation.state.failed"
        case .canceled(let payload):
            return payload.reason.wasInitiatedHere
                ? "conversation.state.canceled"
                : "conversation.state.canceledElsewhere"
        case .outcomeUnknown: return "conversation.state.outcomeUnknown"
        }
    }
}

/// A single indeterminate indicator, and nothing more.
///
/// There is no incremental assistant-text event in v1, so there is nothing to feed a
/// token-by-token effect. Tool completion is not client-visible on any provider either:
/// `toolName` says a tool started, and nothing ever says it finished, so a checklist would render
/// ticks no event can produce.
///
/// `reduceMotion` is a parameter rather than an `@Environment` read because
/// `accessibilityReduceMotion` is a read-only environment value: a test cannot write it, and a
/// behaviour that cannot be exercised is a behaviour nobody checks. `TranscriptEntryView` reads
/// the environment once and passes it in.
struct ProgressIndicatorView: View {

    let activity: TurnActivity?
    let reduceMotion: Bool
    /// When the turn started, for how long it has been running. `nil` when no event said.
    var startedAt: Date?
    /// The tools the turn has started so far, oldest first. Starts only: nothing ever says a tool
    /// finished, so this is a trail and never a checklist.
    var trail: [String] = []

    /// How many steps of the trail are shown: the latest ones.
    static let shownSteps = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if reduceMotion {
                    // Static and still labelled. The animation was never what carried the meaning.
                    Image(systemName: "hourglass")
                        .imageScale(.small)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(progressKey)
                    .font(.caption)
                if let toolName = activity?.toolName, !toolName.isEmpty {
                    Text(verbatim: toolName)
                        .font(.caption.monospaced())
                }
                if let startedAt {
                    // The system's own running clock: it counts without this view redrawing.
                    // For eyes only: read aloud every second it would drown everything else.
                    Text(startedAt, style: .timer)
                        .font(.caption)
                        .monospacedDigit()
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityIdentifier.conversationProgress.identifier)
            .accessibilityLabel(AccessibilityIdentifier.conversationProgress.localizedLabel)

            let steps = Self.steps(for: trail)
            if steps.count > 1 {
                Text(verbatim: steps.joined(separator: " · "))
                    .font(.caption2.monospaced())
                    .lineLimit(2)
                    .accessibilityIdentifier(AccessibilityIdentifier.conversationTrail.identifier)
                    .accessibilityLabel(
                        AccessibilityIdentifier.conversationTrail.localizedLabel
                            + ". " + steps.joined(separator: ", ")
                    )
            }
        }
        .foregroundStyle(.secondary)
    }

    /// The latest steps of the trail, runs of one tool folded: `Read ×3`, `Bash`. An ellipsis
    /// first when there were more than are shown.
    static func steps(for trail: [String]) -> [String] {
        let folded = TurnStateMachine.folded(trail)
        var steps = folded.suffix(shownSteps).map { step in
            step.count > 1 ? "\(step.tool) ×\(step.count)" : step.tool
        }
        if folded.count > shownSteps {
            steps.insert("…", at: 0)
        }
        return steps
    }

    private var progressKey: LocalizedStringKey {
        activity?.activity == .tool
            ? "conversation.progress.tool"
            : "conversation.progress.working"
    }
}

/// One image the person sent, drawn from its bytes once they have been read.
///
/// The bytes come from the server with the phone's own sign-in, or from the upload when this
/// phone sent it. Until they arrive, and when they cannot be had — the server keeps an image for
/// a while, not for ever — the row says so in words where the picture would be.
struct SentAttachmentView: View {

    let attachment: AttachmentDescriptor
    let images: AttachmentImages?

    @State private var picture: UIImage?
    @ScaledMetric(relativeTo: .body) private var maxSide: CGFloat = 220
    @Environment(\.displayScale) private var displayScale

    private var state: AttachmentImages.State? {
        images?.state(for: attachment.attachmentId)
    }

    var body: some View {
        Group {
            if let picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxSide, maxHeight: maxSide)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Label {
                    if !attachment.isImage, let name = attachment.fileName, !name.isEmpty {
                        // A file is named, never drawn: the name is what was sent.
                        Text(verbatim: name)
                            .font(.footnote)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(placeholderKey)
                            .font(.footnote)
                    }
                } icon: {
                    Image(systemName: attachment.isImage ? "photo" : "doc")
                }
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(AccessibilityIdentifier.conversationSentImage.identifier)
        .accessibilityLabel(
            String(localized: "conversation.speaker.you") + ". "
                + AccessibilityIdentifier.conversationSentImage.localizedLabel
        )
        .task(id: attachment.attachmentId) {
            guard attachment.isImage, let images else { return }
            await images.load(attachment.attachmentId)
            decode()
        }
        .onChange(of: state) { _, _ in
            decode()
        }
    }

    private var placeholderKey: LocalizedStringKey {
        guard attachment.isImage else { return "conversation.attachment.file" }
        switch state {
        case .failed?: return "conversation.attachment.unavailable"
        case .loading?, .loaded?, nil: return "conversation.attachment.image"
        }
    }

    /// Decoded once, to the size it is shown at, rather than on every pass over the row.
    private func decode() {
        guard picture == nil, let data = images?.data(for: attachment.attachmentId),
              let full = UIImage(data: data)
        else { return }
        let side = maxSide * max(displayScale, 1)
        picture = full.preparingThumbnail(of: Self.fitting(full.size, within: side)) ?? full
    }

    static func fitting(_ size: CGSize, within side: CGFloat) -> CGSize {
        let longSide = max(size.width, size.height)
        guard longSide > side, longSide > 0 else { return size }
        let ratio = side / longSide
        return CGSize(width: size.width * ratio, height: size.height * ratio)
    }
}

/// What a message answers, above it: who wrote the earlier message and how it starts.
///
/// A message that is no longer among those this phone holds is still said to be a reply, with
/// nothing quoted: the thread keeps messages for a while, not for ever.
struct QuotedMessageView: View {

    let quoted: QuotedMessage
    var agentName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: author)
                .font(.caption2.weight(.semibold))
            if quoted.text.isEmpty {
                Text("conversation.quote.gone")
                    .font(.caption.italic())
            } else {
                Text(verbatim: quoted.text)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.tertiary)
                .frame(width: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(AccessibilityIdentifier.conversationQuote.identifier)
        .accessibilityLabel(
            AccessibilityIdentifier.conversationQuote.localizedLabel + ". " + author
                + (quoted.text.isEmpty ? "" : ". " + quoted.text)
        )
    }

    private var author: String {
        switch quoted.author {
        case .you: return String(localized: "conversation.speaker.you")
        case .agent: return agentName.isEmpty ? String(localized: "conversation.speaker.agent") : agentName
        }
    }
}
