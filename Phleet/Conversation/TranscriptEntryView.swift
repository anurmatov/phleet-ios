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
    let sendAgain: () -> Void

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
            if let text = record.text, !text.isEmpty {
                selectableBody(
                    text,
                    speaker: "conversation.speaker.you",
                    identifier: .conversationMessageBody,
                    copyActionKey: "conversation.copy.message"
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            stateRow

            if record.state.ownsProgressIndicator {
                ProgressIndicatorView(activity: activity, reduceMotion: reduceMotion)
            }

            if let reply = record.reply {
                replyView(reply)
            }
        }
    }

    /// State and the answered-together marker as one spoken element: neither is worth stopping
    /// on separately, and both are chrome rather than content.
    private var stateRow: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: stateSymbol)
                    .imageScale(.small)
                Text(stateKey)
                    .font(.caption)
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
            .accessibilityIdentifier(identifier.identifier)
            .accessibilityLabel(String(localized: speaker) + ". " + text)
            .accessibilityAction(named: Text(copyActionKey)) { putOnPasteboard(text) }
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
                selectableBody(
                    reply.text,
                    speaker: "conversation.speaker.agent",
                    identifier: .conversationReplyBody,
                    copyActionKey: "conversation.copy.reply"
                )
            }
            if reply.completion != .completed || reply.isPartial || reply.truncated {
                Text(qualifierKey(for: reply))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifier.conversationAgentReply.identifier)
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

    var body: some View {
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
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.conversationProgress.identifier)
        .accessibilityLabel(AccessibilityIdentifier.conversationProgress.localizedLabel)
    }

    private var progressKey: LocalizedStringKey {
        activity?.activity == .tool
            ? "conversation.progress.tool"
            : "conversation.progress.working"
    }
}
