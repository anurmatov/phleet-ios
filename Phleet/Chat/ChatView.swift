import SwiftUI

/// The agents this person can chat with. Choosing one opens its thread.
///
/// Read from the orchestrator each time the list appears and on pull-to-refresh, so an agent
/// whose chat was just turned on in the dashboard shows up without relaunching.
struct ChatView: View {

    let model: ChatModel

    var body: some View {
        List {
            if case .failed(let failure) = model.state {
                Section {
                    FleetStatusRow(symbolName: failure.symbolName, messageKey: failure.messageKey)
                }
            }

            switch model.state {
            case .loading where model.agents.isEmpty:
                ProgressView()
                    .frame(maxWidth: .infinity)

            case .notAvailable:
                unavailable(
                    titleKey: "chat.notAvailable.title",
                    descriptionKey: "chat.notAvailable.description",
                    identifier: .chatNotAvailable
                )

            case .loaded where model.agents.isEmpty:
                unavailable(
                    titleKey: "chat.noAgents.title",
                    descriptionKey: "chat.noAgents.description",
                    identifier: .chatNoAgents
                )

            default:
                Section {
                    ForEach(model.agents) { agent in
                        NavigationLink(value: agent) {
                            ChatAgentRow(agent: agent)
                        }
                        .accessibilityIdentifier(AccessibilityIdentifier.chatAgent.identifier)
                        .accessibilityLabel(ChatAgentRow.spokenLabel(for: agent))
                    }
                } footer: {
                    Text("chat.agents.footer")
                }
            }
        }
        .navigationTitle(Text("chat.title"))
        .navigationDestination(for: ChatAgent.self) { agent in
            // The thread keeps the whole screen: the composer sits on the bottom edge, and a tab
            // bar under it would put two rows of controls where a thumb expects one.
            ConversationView(model: model.conversation(for: agent))
                .toolbar(.hidden, for: .tabBar)
        }
        .refreshable {
            await model.load()
        }
        .task {
            await model.load()
        }
    }

    private func unavailable(
        titleKey: LocalizedStringKey,
        descriptionKey: LocalizedStringKey,
        identifier: AccessibilityIdentifier
    ) -> some View {
        ContentUnavailableView {
            Label {
                Text(titleKey)
            } icon: {
                Image(systemName: "bubble.left.and.bubble.right")
            }
        } description: {
            Text(descriptionKey)
        }
        .accessibilityIdentifier(identifier.identifier)
    }
}

/// One agent: what a person calls it, and its name when that differs.
struct ChatAgentRow: View {

    let agent: ChatAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: agent.displayName)
                .font(.body)
            if agent.displayName != agent.agentName {
                Text(verbatim: agent.agentName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func spokenLabel(for agent: ChatAgent) -> String {
        agent.displayName
    }
}
