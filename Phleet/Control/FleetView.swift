import SwiftUI

/// Where an agent row leads. A name rather than the agent itself, so the detail screen reads the
/// agent's **current** state from the model instead of the snapshot that was tapped.
struct AgentRoute: Hashable {
    let agentName: String
}

/// The fleet at a glance.
///
/// What is waiting for a person comes first, because that is the reason to open this screen at
/// all; every agent follows, the ones that need attention at the top. Nothing here edits
/// anything long-form — that stays on the web dashboard, where a wrong tap is cheaper.
struct FleetView: View {

    let model: ControlPlaneModel
    let credential: DeviceCredential
    let push: PushNotificationsModel?
    /// The fleet's memory, or `nil` where there is no search to offer.
    var memory: MemoryModel?

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingConnection = false
    @State private var query = ""

    var body: some View {
        List {
            statusSection
            gatesSection
            agentsSection
        }
        .navigationTitle(Text("fleet.title"))
        .navigationDestination(for: PendingGate.self) { gate in
            GateDecisionView(model: model, gate: gate)
        }
        .searchable(text: $query, prompt: Text("fleet.search.prompt"))
        .navigationDestination(for: AgentRoute.self) { route in
            AgentDetailView(
                model: model,
                agentName: route.agentName,
                openChat: chatOpener(for: route.agentName)
            )
        }
        .navigationDestination(for: MemorySearchRoute.self) { _ in
            if let memory {
                MemorySearchView(model: memory)
            }
        }
        .navigationDestination(for: AgentLogRoute.self) { route in
            AgentLogView(agentName: route.agentName)
        }
        .refreshable {
            await model.refresh()
        }
        .toolbar {
            if memory != nil {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: MemorySearchRoute()) {
                        Image(systemName: "books.vertical")
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.memoryOpen.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.memoryOpen.localizedLabel)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingConnection = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityIdentifier(AccessibilityIdentifier.fleetConnection.identifier)
                .accessibilityLabel(AccessibilityIdentifier.fleetConnection.localizedLabel)
            }
        }
        .sheet(isPresented: $isShowingConnection) {
            // Handed on explicitly: the sheet signs out through it, and a presented sheet is
            // not a place to rely on the environment arriving by inheritance.
            ControlConnectionView(
                credential: credential,
                push: push,
                ownerConfirmation: appEnvironment.ownerConfirmation
            )
            .environment(appEnvironment)
        }
        .onAppear {
            model.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Reading stops in the background and resumes with a fresh read. It is not stopped
            // when this screen is merely covered: a gate that is open on top of it still needs
            // to learn that someone else answered first.
            switch newPhase {
            case .active: model.start()
            case .background: model.stop()
            default: break
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        switch model.status {
        case .loading:
            Section {
                FleetStatusRow(symbolName: "ellipsis.circle", messageKey: "fleet.status.loading")
            }
        case .failed(let failure):
            Section {
                FleetStatusRow(symbolName: failure.symbolName, messageKey: failure.messageKey)
            }
        case .current:
            EmptyView()
        }
    }

    /// Opens this agent's thread, when it is one that can be chatted with. `nil` otherwise, and
    /// the agent's screen then offers nothing: a link that leads to a refusal is worse than none.
    private func chatOpener(for agentName: String) -> (() -> Void)? {
        guard let chat = appEnvironment.chat, chat.agent(named: agentName) != nil else {
            return nil
        }
        let environment = appEnvironment
        return { environment.requestedDestination = .thread(agentName: agentName) }
    }

    private var gatesSection: some View {
        Section {
            let all = model.gates
            let gates = all.filter { ListSearch.matches($0, query: query) }
            if gates.isEmpty {
                Text(all.isEmpty ? "fleet.needsYou.empty" : "fleet.search.empty")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityIdentifier.fleetNoGates.identifier)
            } else {
                ForEach(gates) { gate in
                    NavigationLink(value: gate) {
                        GateRow(gate: gate)
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.fleetGate.identifier)
                    .accessibilityLabel(GateRow.spokenLabel(for: gate))
                }
            }
        } header: {
            Text("fleet.needsYou.title")
        }
    }

    private var agentsSection: some View {
        Section {
            let all = model.agents
            let agents = all.filter { ListSearch.matches($0, query: query) }
            if agents.isEmpty {
                Text(all.isEmpty ? "fleet.agents.empty" : "fleet.search.empty")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityIdentifier.fleetNoAgents.identifier)
            } else {
                ForEach(agents) { agent in
                    NavigationLink(value: AgentRoute(agentName: agent.agentName)) {
                        AgentRow(agent: agent)
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.fleetAgent.identifier)
                    .accessibilityLabel(AgentRow.spokenLabel(for: agent))
                }
            }
        } header: {
            Text("fleet.agents.title")
        } footer: {
            if let lastUpdated = model.lastUpdated {
                FleetUpdatedLine(lastUpdated: lastUpdated, isLive: model.status == .current(isLive: true))
            }
        }
    }
}

/// When the fleet was last read, and whether changes are arriving on their own.
struct FleetUpdatedLine: View {

    let lastUpdated: Date
    let isLive: Bool

    // Typed explicitly so it is looked up in the catalog rather than shown as its own key.
    private var captionKey: LocalizedStringKey {
        isLive ? "fleet.updated.live" : "fleet.updated.polling"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isLive ? "dot.radiowaves.up.forward" : "arrow.clockwise")
                .accessibilityHidden(true)
            Text(captionKey)
            Text(lastUpdated, style: .time)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.fleetUpdated.identifier)
    }
}

/// One line saying why the fleet is not on screen, or not yet.
struct FleetStatusRow: View {

    let symbolName: String
    let messageKey: LocalizedStringKey

    var body: some View {
        Label {
            Text(messageKey).font(.footnote)
        } icon: {
            Image(systemName: symbolName)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.fleetStatus.identifier)
    }
}

extension ControlPlaneModel.Failure {

    var symbolName: String {
        switch self {
        case .accessDenied: return "hand.raised"
        case .unreachable: return "wifi.slash"
        case .unexpectedAnswer: return "questionmark.circle"
        }
    }

    var messageKey: LocalizedStringKey {
        switch self {
        case .accessDenied: return "fleet.status.accessDenied"
        case .unreachable: return "fleet.status.unreachable"
        case .unexpectedAnswer: return "fleet.status.unexpectedAnswer"
        }
    }
}

/// A run that is waiting for a person.
struct GateRow: View {

    let gate: PendingGate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: gate.heading)
                .font(.headline)

            Text(verbatim: RunSubject.text(for: gate.run))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let startTime = gate.run.startTime {
                HStack(spacing: 4) {
                    Text("gate.runningFor")
                    Text(startTime, style: .relative)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One sentence: what is being asked, and about what.
    static func spokenLabel(for gate: PendingGate) -> String {
        gate.heading + ". " + RunSubject.text(for: gate.run)
    }
}

/// One agent, in a line: how it is doing, and what it has in hand.
struct AgentRow: View {

    let agent: FleetAgent

    /// One column for the state symbol, as wide at every text size as the widest of them.
    /// Without it each symbol takes its own width and the names beside them do not line up.
    @ScaledMetric(relativeTo: .body) private var symbolColumn: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: agent.health.symbolName)
                .foregroundStyle(agent.health.tint)
                .frame(width: symbolColumn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: agent.title)
                    .font(.body)

                Text(verbatim: agent.taskSummary ?? agent.health.localizedLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if agent.queuedCount > 0 {
                    HStack(spacing: 4) {
                        Text("agent.queued")
                        Text(verbatim: String(agent.queuedCount))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Name, state, then the task — the state is spoken even when the row shows the task in its
    /// place, because the symbol that carries it is invisible to VoiceOver.
    static func spokenLabel(for agent: FleetAgent) -> String {
        var parts = [agent.title, agent.health.localizedLabel]
        if let task = agent.taskSummary {
            parts.append(task)
        }
        return parts.joined(separator: ". ")
    }
}

extension AgentHealth {

    /// A reinforcement of the symbol, never the only signal.
    var tint: Color {
        switch self {
        case .down: return .red
        case .stale: return .orange
        case .working: return .green
        case .idle, .stopped, .notProvisioned, .unknown: return .secondary
        }
    }
}
