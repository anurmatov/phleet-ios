import SwiftUI

/// One gate, and the answer to give.
///
/// Holds the gate **as it was tapped**. That snapshot is what the decision is sent with — the
/// run and the gate reference on screen — so the orchestrator can refuse an answer to a question
/// that has since changed. The model is consulted only for whether the gate is still waiting.
///
/// Every decision takes two taps: choose, then send. An approval sent by a thumb that was
/// reaching for something else is not recoverable from here.
struct GateDecisionView: View {

    let model: ControlPlaneModel
    let gate: PendingGate

    @Environment(\.dismiss) private var dismiss

    @State private var comment = ""
    @State private var chosen: SignalButton?
    @State private var wasSent = false

    private var isSending: Bool {
        model.decisionState(for: gate) == .sending
    }

    private var isWaiting: Bool {
        model.isWaiting(gate)
    }

    private var trimmedComment: String {
        comment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            summarySection

            if let noticeKey {
                Section {
                    Label {
                        Text(noticeKey).font(.footnote)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityIdentifier.gateNotice.identifier)
                }
            }

            if model.canDecide && isWaiting {
                commentSection
                decisionSection
            }

            if case .failed(let failure)? = model.decisionState(for: gate) {
                Section {
                    GateFailureRow(failure: failure)
                }
            }
        }
        .navigationTitle(Text(verbatim: gate.heading))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Why no decision is offered, when none is.
    private var noticeKey: LocalizedStringKey? {
        if wasSent { return nil }
        if !isWaiting { return "gate.notice.notWaiting" }
        if !model.canDecide { return "gate.notice.readOnly" }
        return nil
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: RunSubject.text(for: gate.run))
                    .font(.headline)
                Text(verbatim: gate.run.workflowType)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityIdentifier.gateSummary.identifier)

            if let phase = gate.run.phase {
                LabeledContent {
                    Text(verbatim: phase)
                } label: {
                    Text("gate.phase")
                }
            }
            if let startTime = gate.run.startTime {
                LabeledContent {
                    Text(startTime, style: .relative)
                } label: {
                    Text("gate.runningFor")
                }
            }
        }
    }

    private var commentSection: some View {
        Section {
            TextField("gate.comment.prompt", text: $comment, axis: .vertical)
                .lineLimit(2...8)
                .disabled(isSending)
                .accessibilityIdentifier(AccessibilityIdentifier.gateComment.identifier)
                .accessibilityLabel(AccessibilityIdentifier.gateComment.localizedLabel)
        } header: {
            Text("gate.comment.title")
        } footer: {
            if gate.signal.buttons.contains(where: \.requiresComment) {
                Text("gate.comment.requiredHint")
            }
        }
    }

    @ViewBuilder
    private var decisionSection: some View {
        if let chosen {
            Section {
                Button {
                    send(chosen)
                } label: {
                    Text("gate.confirm.send")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending)
                .accessibilityIdentifier(AccessibilityIdentifier.gateConfirm.identifier)
                .accessibilityLabel(
                    AccessibilityIdentifier.gateConfirm.localizedLabel + ". " + chosen.label
                )

                Button(role: .cancel) {
                    self.chosen = nil
                } label: {
                    Text("gate.confirm.cancel")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isSending)
                .accessibilityIdentifier(AccessibilityIdentifier.gateCancel.identifier)
                .accessibilityLabel(AccessibilityIdentifier.gateCancel.localizedLabel)
            } header: {
                Text(verbatim: chosen.label)
            } footer: {
                Text("gate.confirm.help")
            }
        } else {
            Section {
                ForEach(gate.signal.buttons, id: \.self) { button in
                    Button {
                        model.clearDecisionFailure(for: gate)
                        chosen = button
                    } label: {
                        Text(verbatim: button.label)
                    }
                    // A decision that needs a comment is unavailable until there is one, rather
                    // than failing after the second tap.
                    .disabled(button.requiresComment && trimmedComment.isEmpty)
                    .accessibilityIdentifier(AccessibilityIdentifier.gateDecision.identifier)
                }
            } header: {
                Text("gate.decision.title")
            }
        }
    }

    private func send(_ button: SignalButton) {
        Task {
            let accepted = await model.decide(gate: gate, button: button, comment: comment)
            chosen = nil
            if accepted {
                wasSent = true
                dismiss()
            }
        }
    }
}

/// Why a decision did not land, in words that say what to do next.
struct GateFailureRow: View {

    let failure: ControlPlaneModel.DecisionFailure

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.messageKey).font(.footnote)
                if case .refused(let message?) = failure {
                    // The orchestrator's own words, shown as given.
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: failure.symbolName)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.gateFailure.identifier)
    }
}

extension ControlPlaneModel.DecisionFailure {

    var symbolName: String {
        switch self {
        case .readOnly, .tokenRejected: return "lock"
        case .accessDenied: return "hand.raised"
        case .gateChanged: return "arrow.triangle.2.circlepath"
        case .commentRequired: return "text.bubble"
        case .outcomeUnknown: return "questionmark.circle"
        case .refused: return "exclamationmark.triangle"
        }
    }

    var messageKey: LocalizedStringKey {
        switch self {
        case .readOnly: return "gate.failure.readOnly"
        case .tokenRejected: return "gate.failure.tokenRejected"
        case .accessDenied: return "gate.failure.accessDenied"
        case .gateChanged: return "gate.failure.gateChanged"
        case .commentRequired: return "gate.failure.commentRequired"
        case .outcomeUnknown: return "gate.failure.outcomeUnknown"
        case .refused: return "gate.failure.refused"
        }
    }
}
