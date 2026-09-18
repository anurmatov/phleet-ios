import SwiftUI

/// The third state.
///
/// `turn.outcome_unknown` is what a crash between an external effect and the result commit
/// produces, and it is genuinely unknown: the work may have run in full, in part, or not at all.
/// It is not the success treatment, not the error treatment, and never an unresolved spinner.
///
/// The action says **"Send again"**, not "Retry". "Retry" implies the first attempt did not
/// land; "send again" is honest about the person choosing to do it twice. There is no automatic
/// resend anywhere — the server never auto-reruns and neither does the client.
struct OutcomeUnknownView: View {

    let reason: OutcomeUnknownReason
    let sendAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("conversation.outcomeUnknown.title")
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "questionmark.circle")
            }

            Text("conversation.outcomeUnknown.body")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(action: sendAgain) {
                Text("conversation.outcomeUnknown.sendAgain")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityIdentifier.conversationSendAgain.identifier)
            .accessibilityLabel(AccessibilityIdentifier.conversationSendAgain.localizedLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifier.conversationOutcomeUnknown.identifier)
        .accessibilityLabel(AccessibilityIdentifier.conversationOutcomeUnknown.localizedLabel)
        // The raw reason is exposed as a value rather than a branch: an unrecognised one must
        // read as the same uncertain state, not fall through to a default that looks like
        // success.
        .accessibilityValue(Text(verbatim: reason.rawValue))
    }
}
