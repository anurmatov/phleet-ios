import SwiftUI

/// What can be done to one agent, and what happened to the last thing that was.
///
/// Two taps, like a gate decision: choose, then confirm. Stopping or restarting an agent
/// interrupts whatever it has in hand, and there is no undo.
struct AgentActionsSection: View {

    let model: ControlPlaneModel
    let agent: FleetAgent

    @State private var chosen: AgentAction?

    private var state: ControlPlaneModel.AgentActionState? {
        model.agentActionState(for: agent.agentName)
    }

    private var isSending: Bool {
        if case .sending? = state { return true }
        return false
    }

    var body: some View {
        let actions = AgentAction.available(for: agent.health)

        Section {
            if actions.isEmpty {
                notice("agentAction.notice.none", symbolName: "info.circle")
            } else if let chosen {
                confirmation(chosen)
            } else {
                ForEach(actions, id: \.self) { action in
                    Button {
                        model.clearAgentActionState(for: agent.agentName)
                        chosen = action
                    } label: {
                        Label {
                            Text(verbatim: action.localizedTitle)
                        } icon: {
                            Image(systemName: action.symbolName)
                        }
                    }
                    .disabled(isSending)
                    .accessibilityIdentifier(AccessibilityIdentifier.agentAction.identifier)
                }
            }

            if let state {
                AgentActionStateRow(state: state)
            }
        } header: {
            Text("agentAction.title")
        }
    }

    @ViewBuilder
    private func confirmation(_ action: AgentAction) -> some View {
        Button(role: action.isDisruptive ? .destructive : nil) {
            send(action)
        } label: {
            Text(verbatim: action.localizedTitle + ": " + agent.title)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .disabled(isSending)
        .accessibilityIdentifier(AccessibilityIdentifier.agentActionConfirm.identifier)
        .accessibilityLabel(
            AccessibilityIdentifier.agentActionConfirm.localizedLabel + ". "
                + action.localizedTitle
        )

        Button(role: .cancel) {
            chosen = nil
        } label: {
            Text("agentAction.cancel")
                .frame(maxWidth: .infinity)
        }
        .disabled(isSending)
        .accessibilityIdentifier(AccessibilityIdentifier.agentActionCancel.identifier)
        .accessibilityLabel(AccessibilityIdentifier.agentActionCancel.localizedLabel)

        if action.isDisruptive {
            Text("agentAction.disruptive.help")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func notice(_ key: LocalizedStringKey, symbolName: String) -> some View {
        Label {
            Text(key).font(.footnote)
        } icon: {
            Image(systemName: symbolName)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.agentActionNotice.identifier)
    }

    private func send(_ action: AgentAction) {
        Task {
            await model.perform(action, on: agent.agentName)
            chosen = nil
        }
    }
}

/// The last action sent to an agent: in flight, accepted, or why not.
struct AgentActionStateRow: View {

    let state: ControlPlaneModel.AgentActionState

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: headline).font(.footnote)
                if case .failed(_, let failure) = state {
                    ActionFailureText(failure: failure)
                }
            }
        } icon: {
            Image(systemName: symbolName)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.agentActionState.identifier)
    }

    private var headline: String {
        switch state {
        case .sending(let action):
            return String(localized: "agentAction.state.sending") + " " + action.localizedTitle
        case .requested(let action):
            return String(localized: "agentAction.state.requested") + " " + action.localizedTitle
        case .failed(let action, _):
            return String(localized: "agentAction.state.failed") + " " + action.localizedTitle
        }
    }

    private var symbolName: String {
        switch state {
        case .sending: return "ellipsis.circle"
        case .requested: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// Why an action did not land, in words that say what to do next.
struct ActionFailureText: View {

    let failure: ControlPlaneModel.ActionFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(failure.messageKey)
                .font(.footnote)
            if case .refused(let message?) = failure {
                // The orchestrator's own words, shown as given.
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension ControlPlaneModel.ActionFailure {

    var messageKey: LocalizedStringKey {
        switch self {
        case .tokenRejected: return "action.failure.tokenRejected"
        case .accessDenied: return "action.failure.accessDenied"
        case .outcomeUnknown: return "action.failure.outcomeUnknown"
        case .refused: return "action.failure.refused"
        }
    }
}
