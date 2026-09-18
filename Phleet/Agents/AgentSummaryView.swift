import SwiftUI

/// The one agent this deployment binds, as reported by `GET /v1/session`.
struct AgentSummary: Equatable, Sendable {
    /// Cosmetic and non-authoritative: a display string, and nothing routes on it.
    let label: String?
    let principalId: String?
    let serverDisplayName: String

    /// Falls back to a neutral localized label rather than showing an empty row.
    var displayLabel: String {
        guard let label, !label.trimmingCharacters(in: .whitespaces).isEmpty else {
            return String(localized: "agent.unnamed")
        }
        return label
    }
}

/// A single agent entry, not a list with a selection model.
///
/// **There is no agent-list route on the north boundary.** The complete device-reachable route
/// set does not enumerate agents: `GET /v1/session` returns one `agentLabel`, and the deployment
/// binds exactly one agent name. A one-row list would mean building a selection model with
/// nothing to select and rebuilding it when the real shape lands — and an empty state reading
/// "no other agents yet" would promise something the API does not.
struct AgentSummaryView: View {

    let summary: AgentSummary
    let openThread: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("agent.section")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(verbatim: summary.displayLabel)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier(AccessibilityIdentifier.agentLabel.identifier)
                    .accessibilityLabel(
                        AccessibilityIdentifier.agentLabel.localizedLabel + ". "
                            + summary.displayLabel
                    )
            }

            detail(
                captionKey: "agent.server.caption",
                value: summary.serverDisplayName,
                identifier: .agentServer
            )

            if let principalId = summary.principalId {
                detail(
                    captionKey: "agent.principal.caption",
                    value: principalId,
                    identifier: .agentPrincipal
                )
            }

            Button(action: openThread) {
                Text("agent.openThread")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityIdentifier.agentOpenThread.identifier)
            .accessibilityLabel(AccessibilityIdentifier.agentOpenThread.localizedLabel)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    /// A caption and its value, stacked at accessibility sizes rather than truncated.
    @ViewBuilder
    private func detail(
        captionKey: LocalizedStringKey,
        value: String,
        identifier: AccessibilityIdentifier
    ) -> some View {
        let caption = Text(captionKey).font(.footnote).foregroundStyle(.secondary)
        let detail = Text(verbatim: value).font(.body)

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    caption
                    detail
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    caption
                    detail
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(identifier.identifier)
        .accessibilityLabel(identifier.localizedLabel + ". " + value)
    }
}
