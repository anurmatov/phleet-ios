import SwiftUI

/// The agents this person can chat with. Choosing one opens its thread.
///
/// Read from the orchestrator each time the list appears and on pull-to-refresh, so an agent
/// whose chat was just turned on in the dashboard shows up without relaunching.
struct ChatView: View {

    let model: ChatModel
    /// The fleet, for how each agent is doing. `nil` where there is none to read, and the rows
    /// then show names only.
    var fleet: ControlPlaneModel?

    @Environment(AppEnvironment.self) private var appEnvironment

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
                        let fleetAgent = fleet?.agent(named: agent.agentName)
                        let hasNew = model.hasNewActivity(agent)
                        NavigationLink(value: agent) {
                            ChatAgentRow(
                                agent: agent,
                                fleetAgent: fleetAgent,
                                hasNewActivity: hasNew,
                                lastActivity: model.lastActivity(agent)
                            )
                        }
                        .accessibilityIdentifier(AccessibilityIdentifier.chatAgent.identifier)
                        .accessibilityLabel(
                            ChatAgentRow.spokenLabel(
                                for: agent,
                                fleetAgent: fleetAgent,
                                hasNewActivity: hasNew
                            )
                        )
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
            ConversationView(
                model: model.conversation(for: agent),
                onSeen: { position in model.markSeen(agent, position: position) },
                openAgent: agentOpener(for: agent)
            )
            .toolbar(.hidden, for: .tabBar)
        }
        .refreshable {
            await model.load()
        }
        .task {
            await model.load()
        }
    }

    /// Opens this agent's own screen on the Fleet tab, when the fleet lists it.
    private func agentOpener(for agent: ChatAgent) -> (() -> Void)? {
        guard fleet?.agent(named: agent.agentName) != nil else { return nil }
        let environment = appEnvironment
        let name = agent.agentName
        return { environment.requestedDestination = .agent(name: name) }
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

/// One agent: what a person calls it, how it is doing, and whether its thread has moved on.
///
/// How it is doing comes from the fleet, when the fleet lists it: an agent that is down will not
/// answer, and that is worth knowing before writing to it. The mark for new activity is a shape
/// with a word beside it, never a colour alone.
struct ChatAgentRow: View {

    let agent: ChatAgent
    var fleetAgent: FleetAgent?
    var hasNewActivity = false
    var lastActivity: Date?

    @ScaledMetric(relativeTo: .body) private var symbolColumn: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let fleetAgent {
                Image(systemName: fleetAgent.health.symbolName)
                    .foregroundStyle(fleetAgent.health.tint)
                    .frame(width: symbolColumn)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: agent.displayName)
                    .font(.body)

                if let caption = Self.caption(for: agent, fleetAgent: fleetAgent) {
                    Text(verbatim: caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityIdentifier(AccessibilityIdentifier.chatAgentState.identifier)
                }

                if hasNewActivity || lastActivity != nil {
                    HStack(spacing: 6) {
                        if hasNewActivity {
                            Label {
                                Text("chat.agent.new")
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .imageScale(.small)
                            }
                            .foregroundStyle(.tint)
                        }
                        if let lastActivity {
                            Text(lastActivity, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The task in hand, else how the agent is doing — or, where the fleet does not list it, its
    /// name when that differs from what it is called.
    static func caption(for agent: ChatAgent, fleetAgent: FleetAgent?) -> String? {
        if let fleetAgent {
            return fleetAgent.taskSummary ?? fleetAgent.health.localizedLabel
        }
        return agent.displayName != agent.agentName ? agent.agentName : nil
    }

    static func spokenLabel(
        for agent: ChatAgent,
        fleetAgent: FleetAgent? = nil,
        hasNewActivity: Bool = false
    ) -> String {
        var parts = [agent.displayName]
        if let fleetAgent {
            parts.append(fleetAgent.health.localizedLabel)
        }
        if hasNewActivity {
            parts.append(String(localized: "chat.agent.new", bundle: .main))
        }
        return parts.joined(separator: ". ")
    }
}
