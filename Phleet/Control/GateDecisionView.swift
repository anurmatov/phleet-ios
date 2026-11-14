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
    @Environment(\.confirmOwner) private var confirmOwner

    @State private var comment = ""
    @State private var chosen: SignalButton?
    @State private var wasSent = false
    @State private var humanValue = ""
    @State private var confirmedHumanValue: String?

    private var isHumanSignal: Bool { gate.signal.name == "request-input" }
    private var humanRequest: HumanInputRequest? { model.humanInput(for: gate) }

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

            if isHumanSignal {
                humanInputSection
            } else if isWaiting {
                commentSection
                decisionSection
            }

            if case .failed(let failure)? = model.decisionState(for: gate) {
                Section {
                    GateFailureRow(failure: failure)
                }
            }

            // Under the decision, not above it: the answer stays where a thumb expects it, and
            // what led here is one scroll away for whoever wants it before answering.
            if !isHumanSignal {
                activitySection
            }
        }
        .navigationTitle(Text(verbatim: gate.heading))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: gate) {
            if isHumanSignal {
                await model.loadHumanInput(for: gate)
            } else {
                await model.loadGateActivity(for: gate)
            }
        }
    }

    /// Why no decision is offered, when none is.
    private var noticeKey: LocalizedStringKey? {
        if wasSent { return nil }
        if !isWaiting { return "gate.notice.notWaiting" }
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

            RunWebLinkRow(run: gate.run)
        }
    }

    /// What the run did on its way here: the last things an agent produced, what failed, what
    /// was signalled. Read from that exact run, and never a condition of deciding — a gate whose
    /// history cannot be read still offers its decision.
    @ViewBuilder
    private var activitySection: some View {
        switch model.gateActivity(for: gate) {
        case .loaded(let events)? where !events.isEmpty:
            Section {
                ForEach(events) { event in
                    RunEventRow(event: event)
                }
            } header: {
                Text("gate.activity.title")
            } footer: {
                Text("gate.activity.help")
            }
        case .unavailable?:
            Section {
                Label {
                    Text("gate.activity.unavailable").font(.footnote)
                } icon: {
                    Image(systemName: "clock.badge.questionmark")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityIdentifier.gateActivityUnavailable.identifier)
            } header: {
                Text("gate.activity.title")
            }
        case .loading?, .loaded?, nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var humanInputSection: some View {
        Section {
            Text(verbatim: gate.run.namespace).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: gate.run.workflowId).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: gate.run.runId).fixedSize(horizontal: false, vertical: true)
        } header: { Text("humanInput.identity") }

        if let request = humanRequest {
            Section {
                ForEach(Array(request.origin.enumerated()), id: \.offset) { item in
                    Text(verbatim: item.element).fixedSize(horizontal: false, vertical: true)
                }
            } header: { Text("humanInput.requester") }
            Section {
                LabeledContent { Text(verbatim: request.mode.rawValue) }
                    label: { Text("humanInput.mode") }
            }
            Section {
                Text(verbatim: request.question)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityIdentifier.humanInputQuestion.identifier)
            } header: { Text("humanInput.question") }
            Section {
                Text(verbatim: request.context).fixedSize(horizontal: false, vertical: true)
            } header: { Text("humanInput.context") }

            if isWaiting {
                Section {
                    if request.mode == .text {
                        TextField("humanInput.answer", text: $humanValue, axis: .vertical)
                            .accessibilityIdentifier(AccessibilityIdentifier.humanInputAnswer.identifier)
                            .accessibilityLabel(AccessibilityIdentifier.humanInputAnswer.localizedLabel)
                    } else {
                        ForEach(request.choices) { choice in
                            Button { humanValue = choice.id } label: {
                                HStack {
                                    Text(verbatim: choice.label)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if humanValue == choice.id { Image(systemName: "checkmark") }
                                }
                            }
                            .accessibilityIdentifier(AccessibilityIdentifier.humanInputChoice.identifier)
                            .accessibilityLabel(choice.label)
                            .accessibilityAddTraits(humanValue == choice.id ? .isSelected : [])
                        }
                    }
                } header: { Text("humanInput.answer") }
                  footer: { Text("humanInput.limits") }
                .disabled(isSending || confirmedHumanValue != nil)

                commentSection.disabled(confirmedHumanValue != nil)
                Section {
                    if let value = confirmedHumanValue {
                        Text(verbatim: request.choices.first { $0.id == value }?.label ?? value)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("gate.confirm.send") {
                            Task {
                                guard await confirmOwner(String(localized: "confirmOwner.reason.decision")) else {
                                    return
                                }
                                let accepted = await model.answerHumanInput(gate: gate, value: value, comment: comment)
                                confirmedHumanValue = nil
                                if accepted { wasSent = true; dismiss() }
                            }
                        }
                        .disabled(isSending || !request.valid(value: value, comment: comment))
                        .accessibilityIdentifier(AccessibilityIdentifier.gateConfirm.identifier)
                        .accessibilityLabel(AccessibilityIdentifier.gateConfirm.localizedLabel)
                        Button("gate.confirm.cancel", role: .cancel) { confirmedHumanValue = nil }
                            .disabled(isSending)
                            .accessibilityIdentifier(AccessibilityIdentifier.gateCancel.identifier)
                            .accessibilityLabel(AccessibilityIdentifier.gateCancel.localizedLabel)
                    } else {
                        Button("humanInput.review") { confirmedHumanValue = humanValue }
                            .disabled(!request.valid(value: humanValue, comment: comment))
                            .accessibilityIdentifier(AccessibilityIdentifier.gateDecision.identifier)
                            .accessibilityLabel(String(localized: "humanInput.review"))
                    }
                } footer: { Text("humanInput.dataOnly") }
            }
        } else if isWaiting {
            Section {
                if model.humanInputStates[gate.id] == .loading {
                    Text("humanInput.loading")
                } else {
                    Text("humanInput.unavailable")
                    Button("humanInput.reload") {
                        humanValue = ""
                        confirmedHumanValue = nil
                        Task {
                            await model.refresh()
                            await model.loadHumanInput(for: gate)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.humanInputReload.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.humanInputReload.localizedLabel)
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
            // The second look, when the switch is on. A refusal leaves the choice standing, so
            // trying again is one tap rather than a new decision.
            guard await confirmOwner(String(localized: "confirmOwner.reason.decision")) else {
                return
            }
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
        case .tokenRejected: return "lock"
        case .accessDenied: return "hand.raised"
        case .gateChanged: return "arrow.triangle.2.circlepath"
        case .commentRequired: return "text.bubble"
        case .outcomeUnknown: return "questionmark.circle"
        case .refused: return "exclamationmark.triangle"
        }
    }

    var messageKey: LocalizedStringKey {
        switch self {
        case .tokenRejected: return "gate.failure.tokenRejected"
        case .accessDenied: return "gate.failure.accessDenied"
        case .gateChanged: return "gate.failure.gateChanged"
        case .commentRequired: return "gate.failure.commentRequired"
        case .outcomeUnknown: return "gate.failure.outcomeUnknown"
        case .refused: return "gate.failure.refused"
        }
    }
}
