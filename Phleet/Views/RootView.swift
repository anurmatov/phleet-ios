import SwiftUI

/// One setup step, then three tabs over one sign-in.
///
/// Signed out, the app is the setup screen and nothing else: there is one credential, and every
/// tab needs it, so there is no tab that could do anything without it. Signed in, **Fleet** and
/// **Runs** are the orchestrator's operator API and **Chat** is the chat service, all reached
/// through the same address with the same access token.
///
/// Fleet is first because it answers the question a person opens the app with: is anything
/// waiting for me.
struct RootView: View {

    /// Named `Pane` rather than `Tab`: newer SDKs ship a `Tab` type of their own.
    enum Pane: Hashable {
        case fleet
        case runs
        case chat
    }

    @Environment(AppEnvironment.self) private var appEnvironment

    @State private var selection: Pane = .fleet
    @State private var fleetPath = NavigationPath()
    @State private var runsPath = NavigationPath()
    @State private var chatPath = NavigationPath()
    @State private var notificationVisit = UUID()

    var body: some View {
        Group {
            if appEnvironment.isSignedIn {
                tabs
            } else {
                NavigationStack {
                    SetupView()
                }
            }
        }
        // Every screen under here asks through this when it is about to send something that
        // cannot be undone. With the switch off it answers yes without asking anyone.
        .environment(\.confirmOwner, confirmOwner)
        // The paths outlive the tabs, so a screen opened under one sign-in must not reappear
        // under the next.
        .onChange(of: appEnvironment.controlPlane.map { ObjectIdentifier($0) }) { _, _ in
            fleetPath = NavigationPath()
            runsPath = NavigationPath()
            chatPath = NavigationPath()
        }
    }

    private var confirmOwner: ConfirmOwnerAction {
        let confirmation = appEnvironment.ownerConfirmation
        return ConfirmOwnerAction { reason in
            await confirmation.confirm(reason: reason)
        }
    }

    /// How many runs are waiting for a person. On the Fleet tab and on the app's icon, so the
    /// answer to "is anything waiting for me" does not need the app opened to that tab — or, on
    /// the icon, opened at all since it was last in use.
    private var waitingCount: Int {
        appEnvironment.controlPlane?.gates.count ?? 0
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            NavigationStack(path: $fleetPath) {
                fleet
            }
            .tabItem {
                Label {
                    Text("tab.fleet")
                } icon: {
                    Image(systemName: "square.grid.2x2")
                }
            }
            .badge(waitingCount)
            .tag(Pane.fleet)

            NavigationStack(path: $runsPath) {
                runs
            }
            .tabItem {
                Label {
                    Text("tab.runs")
                } icon: {
                    Image(systemName: "list.bullet.rectangle")
                }
            }
            .tag(Pane.runs)

            NavigationStack(path: $chatPath) {
                chat
            }
            .tabItem {
                Label {
                    Text("tab.chat")
                } icon: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
            }
            .tag(Pane.chat)
        }
        .onAppear {
            // A notification tapped while the app was not running is reported before this view
            // exists, so the request is already waiting.
            open(appEnvironment.requestedDestination)
        }
        .onChange(of: appEnvironment.requestedDestination) { _, destination in
            open(destination)
        }
        .onChange(of: waitingCount, initial: true) { _, count in
            appEnvironment.pushSystem.setBadgeCount(count)
            // The widget reads on the system's schedule; this is the moment the app knows better.
            appEnvironment.glance.refresh()
        }
        .task(id: appEnvironment.chat.map { ObjectIdentifier($0) }) {
            // Who can be chatted with, read once up front: an agent's screen offers its thread
            // only when it is on this list, and the Chat tab opens with it already there.
            await appEnvironment.chat?.load()
        }
    }

    /// Takes a request to its tab — and, when it names something, to that thing if a fresh read
    /// still finds it. The request is cleared so it is honoured once.
    ///
    /// A request comes from a tapped notification, or from a link between tabs: an agent's screen
    /// opening its thread, a thread opening its agent. Either way the name is only a hint. What
    /// opens is what the server lists now; a run that has moved on, an agent that is gone or a
    /// thread whose chat was turned off leaves the person on the list instead.
    private func open(_ destination: PushDestination?) {
        guard let destination else { return }
        let visit = UUID()
        notificationVisit = visit
        switch destination {
        case .fleet: selection = .fleet
        case .runs: selection = .runs
        case .chat: selection = .chat

        case .gate(let target):
            selection = .fleet
            fleetPath = NavigationPath()
            if let model = appEnvironment.controlPlane {
                Task {
                    let gate = await model.gateForNotification(target)
                    guard notificationVisit == visit, selection == .fleet, fleetPath.isEmpty,
                          appEnvironment.controlPlane === model,
                          let gate, model.isWaiting(gate) else { return }
                    fleetPath = NavigationPath([gate])
                }
            }

        case .agent(let name):
            selection = .fleet
            fleetPath = NavigationPath()
            if let model = appEnvironment.controlPlane {
                if model.agent(named: name) != nil {
                    fleetPath = NavigationPath([AgentRoute(agentName: name)])
                } else {
                    Task {
                        await model.refresh()
                        guard notificationVisit == visit, selection == .fleet, fleetPath.isEmpty,
                              appEnvironment.controlPlane === model,
                              model.agent(named: name) != nil else { return }
                        fleetPath = NavigationPath([AgentRoute(agentName: name)])
                    }
                }
            }

        case .run(let target):
            selection = .runs
            runsPath = NavigationPath()
            if let model = appEnvironment.controlPlane, let closed = appEnvironment.runs {
                Task {
                    // In progress first; a run that failed is among the closed ones.
                    var run = await model.runningRunForNotification(target)
                    if run == nil {
                        await closed.refreshClosed()
                        run = closed.closed.first { target.matches($0) }
                    }
                    guard notificationVisit == visit, selection == .runs, runsPath.isEmpty,
                          appEnvironment.controlPlane === model, let run else { return }
                    runsPath = NavigationPath([run])
                }
            }

        case .thread(let agentName):
            selection = .chat
            chatPath = NavigationPath()
            if let chat = appEnvironment.chat {
                if let agent = chat.agent(named: agentName) {
                    chatPath = NavigationPath([agent])
                } else {
                    Task {
                        await chat.load()
                        guard notificationVisit == visit, selection == .chat, chatPath.isEmpty,
                              appEnvironment.chat === chat,
                              let agent = chat.agent(named: agentName) else { return }
                        chatPath = NavigationPath([agent])
                    }
                }
            }
        }
        appEnvironment.requestedDestination = nil
    }

    // MARK: - Fleet

    @ViewBuilder
    private var fleet: some View {
        if let model = appEnvironment.controlPlane, let credential = appEnvironment.credential {
            FleetView(
                model: model,
                credential: credential,
                push: appEnvironment.pushNotifications,
                memory: appEnvironment.memory
            )
        } else {
            ProgressView()
        }
    }

    // MARK: - Runs

    @ViewBuilder
    private var runs: some View {
        if let fleet = appEnvironment.controlPlane, let runs = appEnvironment.runs {
            RunsView(fleet: fleet, runs: runs, schedules: appEnvironment.schedules)
        } else {
            ProgressView()
        }
    }

    // MARK: - Chat

    @ViewBuilder
    private var chat: some View {
        if let chat = appEnvironment.chat {
            ChatView(model: chat, fleet: appEnvironment.controlPlane)
        } else {
            ProgressView()
        }
    }
}
