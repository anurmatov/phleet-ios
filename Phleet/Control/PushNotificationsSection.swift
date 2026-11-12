import SwiftUI

/// Notifications for this connection: whether they are on, and the one thing to do about it.
///
/// The state is always said in words, including every reason they are not on. A switch that
/// simply would not turn on tells a person nothing about whether to look in Settings, at the
/// orchestrator, or at their connection.
struct PushNotificationsSection: View {

    let model: PushNotificationsModel

    private var isBusy: Bool {
        model.state == .asking || model.state == .registering
    }

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.state.titleKey)
                        .font(.body)
                    if let detailKey = model.state.detailKey {
                        Text(detailKey)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if case .failed(let failure) = model.state {
                        ActionFailureText(failure: failure)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: model.state.symbolName)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityIdentifier.pushState.identifier)

            if model.offersTurnOff {
                Button(role: .destructive) {
                    Task { await model.turnOff() }
                } label: {
                    Text("push.turnOff")
                }
                .disabled(model.state == .asking)
                .accessibilityIdentifier(AccessibilityIdentifier.pushTurnOff.identifier)
                .accessibilityLabel(AccessibilityIdentifier.pushTurnOff.localizedLabel)
            } else if model.state.offersTurnOn {
                Button {
                    Task { await model.turnOn() }
                } label: {
                    Text("push.turnOn")
                }
                .disabled(isBusy)
                .accessibilityIdentifier(AccessibilityIdentifier.pushTurnOn.identifier)
                .accessibilityLabel(AccessibilityIdentifier.pushTurnOn.localizedLabel)
            }
        } header: {
            Text("push.title")
        } footer: {
            Text("push.help")
        }
    }
}

extension PushNotificationsModel.State {

    var symbolName: String {
        switch self {
        case .on: return "bell.badge"
        case .off: return "bell.slash"
        case .asking, .registering: return "ellipsis.circle"
        case .denied, .readOnly: return "lock"
        case .disabledOnServer, .unsupportedServer: return "server.rack"
        case .tokenUnavailable, .failed: return "exclamationmark.triangle"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .on: return "push.state.on"
        case .off: return "push.state.off"
        case .asking: return "push.state.asking"
        case .registering: return "push.state.registering"
        case .denied: return "push.state.denied"
        case .readOnly: return "push.state.readOnly"
        case .disabledOnServer: return "push.state.disabledOnServer"
        case .unsupportedServer: return "push.state.unsupportedServer"
        case .tokenUnavailable: return "push.state.tokenUnavailable"
        case .failed: return "push.state.failed"
        }
    }

    /// What to do about it, for the states where something can be done.
    var detailKey: LocalizedStringKey? {
        switch self {
        case .denied: return "push.detail.denied"
        case .readOnly: return "push.detail.readOnly"
        case .disabledOnServer: return "push.detail.disabledOnServer"
        case .unsupportedServer: return "push.detail.unsupportedServer"
        case .tokenUnavailable: return "push.detail.tokenUnavailable"
        case .on, .off, .asking, .registering, .failed: return nil
        }
    }
}
