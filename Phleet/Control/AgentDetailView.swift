import SwiftUI

/// One agent in full.
///
/// Reads the agent from the model by name on every render, so what is on screen is its current
/// state rather than the row that was tapped — which matters most right after an action, when
/// the state is the only evidence of whether it worked.
/// Where the log link leads.
struct AgentLogRoute: Hashable {
    let agentName: String
}

struct AgentDetailView: View {

    let model: ControlPlaneModel
    let agentName: String
    /// Opens this agent's thread. `nil` when it cannot be chatted with, and then nothing is
    /// offered.
    var openChat: (() -> Void)?

    var body: some View {
        Group {
            if let agent = model.agent(named: agentName) {
                detail(agent)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("agentDetail.gone.title")
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                    }
                } description: {
                    Text("agentDetail.gone.description")
                }
                .accessibilityIdentifier(AccessibilityIdentifier.agentDetailGone.identifier)
            }
        }
        .navigationTitle(Text(verbatim: model.agent(named: agentName)?.title ?? agentName))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ agent: FleetAgent) -> some View {
        List {
            Section {
                Label {
                    Text(verbatim: agent.health.localizedLabel)
                        .font(.headline)
                } icon: {
                    Image(systemName: agent.health.symbolName)
                        .foregroundStyle(agent.health.tint)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(AccessibilityIdentifier.agentDetailHealth.identifier)
                .accessibilityLabel(
                    AccessibilityIdentifier.agentDetailHealth.localizedLabel + ". "
                        + agent.health.localizedLabel
                )

                if let lastSeen = agent.lastSeen {
                    LabeledContent {
                        Text(lastSeen, style: .relative)
                    } label: {
                        Text("agentDetail.lastSeen")
                    }
                }
            }

            Section {
                if let task = agent.taskSummary {
                    Text(verbatim: task)
                        .font(.body)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(AccessibilityIdentifier.agentDetailTask.identifier)
                } else {
                    Text("agentDetail.task.none")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityIdentifier.agentDetailTask.identifier)
                }
            } header: {
                Text("agentDetail.task.title")
            }

            if let openChat {
                Section {
                    Button {
                        openChat()
                    } label: {
                        Label {
                            Text("agentDetail.chat")
                        } icon: {
                            Image(systemName: "bubble.left.and.bubble.right")
                        }
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.agentDetailChat.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.agentDetailChat.localizedLabel)
                }
            }

            AgentActionsSection(model: model, agent: agent)

            Section {
                NavigationLink(value: AgentLogRoute(agentName: agent.agentName)) {
                    Label {
                        Text("agentLog.open")
                    } icon: {
                        Image(systemName: "text.alignleft")
                    }
                }
                .accessibilityIdentifier(AccessibilityIdentifier.agentLogOpen.identifier)
                .accessibilityLabel(AccessibilityIdentifier.agentLogOpen.localizedLabel)
            }

            Section {
                fact("agentDetail.queued", String(agent.queuedCount))
                if agent.priorityQueuedCount > 0 {
                    fact("agentDetail.priorityQueued", String(agent.priorityQueuedCount))
                }
                fact("agentDetail.backgroundTasks", String(agent.backgroundTaskCount))
            } header: {
                Text("agentDetail.work.title")
            }

            Section {
                fact("agentDetail.name", agent.agentName)
                if let role = agent.role {
                    fact("agentDetail.role", role)
                }
                if let modelName = agent.model {
                    fact("agentDetail.model", modelName)
                }
                if let version = agent.version {
                    fact("agentDetail.version", version)
                }
            } header: {
                Text("agentDetail.about.title")
            }
        }
    }

    private func fact(_ titleKey: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: value)
        } label: {
            Text(titleKey)
        }
        .accessibilityIdentifier(AccessibilityIdentifier.agentDetailFact.identifier)
    }
}
