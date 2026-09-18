import SwiftUI

/// The connection, in one line.
///
/// Every state here is reachable and distinct, because every close code has a distinct outcome.
/// The two that must not read as ordinary are `superseded` — which offers a **manual** resume,
/// because automatic reconnect is switched off rather than delayed — and `notPermitted`, which
/// is terminal and offers nothing.
struct ConnectionBanner: View {

    let state: ConversationModel.ConnectionState
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .imageScale(.medium)
                .accessibilityHidden(true)

            Text(messageKey)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)

            if case .superseded = state {
                Button(action: resume) {
                    Text("conversation.resume")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AccessibilityIdentifier.conversationResume.identifier)
                .accessibilityLabel(AccessibilityIdentifier.conversationResume.localizedLabel)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifier.conversationBanner.identifier)
        .accessibilityLabel(AccessibilityIdentifier.conversationBanner.localizedLabel)
        .accessibilityValue(Text(messageKey))
    }

    /// State is never carried by colour alone: each one has its own symbol as well.
    private var symbolName: String {
        switch state {
        case .idle, .connecting: return "ellipsis.circle"
        case .live: return "dot.radiowaves.up.forward"
        case .waiting: return "clock"
        case .rateLimited: return "hourglass"
        case .superseded: return "rectangle.on.rectangle.slash"
        case .notPermitted: return "hand.raised"
        case .unavailable: return "questionmark.circle"
        case .revoked: return "lock.slash"
        case .offline: return "wifi.slash"
        }
    }

    private var messageKey: LocalizedStringKey {
        switch state {
        case .idle: return "conversation.banner.idle"
        case .connecting: return "conversation.banner.connecting"
        case .live: return "conversation.banner.live"
        case .waiting: return "conversation.banner.waiting"
        case .rateLimited: return "conversation.banner.rateLimited"
        case .superseded: return "conversation.banner.superseded"
        case .notPermitted: return "conversation.banner.notPermitted"
        case .unavailable: return "conversation.banner.unavailable"
        case .revoked: return "conversation.banner.revoked"
        case .offline: return "conversation.banner.offline"
        }
    }
}
