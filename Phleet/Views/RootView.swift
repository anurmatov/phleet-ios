import SwiftUI

/// Three tabs, for two surfaces that share nothing but the app.
///
/// **Fleet** and **Runs** are the control plane: they talk to the orchestrator's operator API
/// through one connection. **Chat** is the thread: it talks to the device boundary. The two
/// surfaces hold different credentials, are set up separately, and either works without the
/// other — which is why neither is nested inside the other's navigation.
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
    @State private var isShowingThread = false

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                fleet
            }
            .tabItem {
                Label {
                    Text("tab.fleet")
                } icon: {
                    Image(systemName: "square.grid.2x2")
                }
            }
            .tag(Pane.fleet)

            NavigationStack {
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

            NavigationStack {
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
    }

    /// Takes a tapped notification to its tab, and clears the request so it is honoured once.
    private func open(_ destination: PushDestination?) {
        guard let destination else { return }
        switch destination {
        case .fleet: selection = .fleet
        case .runs: selection = .runs
        }
        appEnvironment.requestedDestination = nil
    }

    // MARK: - Fleet

    @ViewBuilder
    private var fleet: some View {
        if let model = appEnvironment.controlPlane,
           let credential = appEnvironment.controlCredential {
            FleetView(
                model: model,
                credential: credential,
                tokenVerification: appEnvironment.controlTokenVerification,
                push: appEnvironment.pushNotifications
            ) {
                appEnvironment.removeControlConnection()
            }
        } else {
            ControlSetupView()
        }
    }

    // MARK: - Runs

    /// Shares the fleet's connection: without one there is nothing to list, and the place to
    /// make one is the Fleet tab.
    @ViewBuilder
    private var runs: some View {
        if let fleet = appEnvironment.controlPlane, let runs = appEnvironment.runs {
            RunsView(fleet: fleet, runs: runs)
        } else {
            ContentUnavailableView {
                Label {
                    Text("runs.unconnected.title")
                } icon: {
                    Image(systemName: "list.bullet.rectangle")
                }
            } description: {
                Text("runs.unconnected.description")
            }
            .accessibilityIdentifier(AccessibilityIdentifier.runsUnconnected.identifier)
        }
    }

    // MARK: - Chat

    /// Routes on enrolled, unenrolled and revoked.
    ///
    /// A stale credential whose token has never been minted still counts as enrolled: the device
    /// record exists server-side, and the way to find out whether it is alive is to spend it.
    /// Only the one sign-out condition — a `401` from the token mint — moves this tab back to
    /// enrollment.
    @ViewBuilder
    private var chat: some View {
        switch appEnvironment.route {
        case .enrollment:
            EnrollmentView()

        case .agent:
            agent
        }
    }

    @ViewBuilder
    private var agent: some View {
        if let summary = appEnvironment.agentSummary {
            AgentSummaryView(summary: summary) {
                isShowingThread = true
            }
            .navigationDestination(isPresented: $isShowingThread) {
                if let conversation = appEnvironment.conversation {
                    // The thread keeps the whole screen, as it did before there were tabs: the
                    // composer sits on the bottom edge, and a tab bar under it would put two
                    // rows of controls where a thumb expects one.
                    ConversationView(model: conversation)
                        .toolbar(.hidden, for: .tabBar)
                }
            }
        } else {
            ProgressView()
        }
    }
}
