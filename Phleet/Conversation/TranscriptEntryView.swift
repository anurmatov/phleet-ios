import SwiftUI

/// One submission and its answer, as **one** accessibility element.
///
/// VoiceOver reads a single coherent sentence — speaker, state, text — rather than three
/// fragments, following the `.accessibilityElement(children: .ignore)` pattern the rest of the
/// app uses. The `outcome_unknown` panel is deliberately a sibling rather than a child: it
/// carries an action, and an action inside an ignored element is unreachable.
struct TranscriptEntryView: View {

    let record: SubmissionRecord
    let activity: TurnActivity?
    let sendAgain: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(AccessibilityIdentifier.conversationEntry.identifier)
                .accessibilityLabel(spokenLabel)

            if case .outcomeUnknown(let reason) = record.state {
                OutcomeUnknownView(reason: reason, sendAgain: sendAgain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text = record.text, !text.isEmpty {
                Text(verbatim: text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Image(systemName: stateSymbol)
                    .imageScale(.small)
                Text(stateKey)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)

            if record.isAnsweredTogether {
                Text("conversation.state.answeredTogether")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if record.state.ownsProgressIndicator {
                ProgressIndicatorView(activity: activity, reduceMotion: reduceMotion)
            }

            if let reply = record.reply {
                replyView(reply)
            }
        }
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
                Text(verbatim: reply.text)
                    .font(.body)
            }
            if reply.completion != .completed || reply.isPartial || reply.truncated {
                Text(qualifierKey(for: reply))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(AccessibilityIdentifier.conversationAgentReply.identifier)
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

    private var spokenLabel: String {
        var parts: [String] = [String(localized: "conversation.speaker.you")]

        if let text = record.text, !text.isEmpty {
            parts.append(text)
        }
        parts.append(String(localized: stateLabelResource))

        if record.isAnsweredTogether {
            parts.append(String(localized: "conversation.state.answeredTogether"))
        }
        if let reply = record.reply {
            parts.append(String(localized: "conversation.speaker.agent"))
            parts.append(
                reply.text.isEmpty ? String(localized: "conversation.reply.empty") : reply.text
            )
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
