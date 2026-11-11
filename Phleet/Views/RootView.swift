import SwiftUI

/// Two tabs, for two surfaces that share nothing but the app.
///
/// **Fleet** is the control plane: it talks to the orchestrator's operator API. **Chat** is the
/// thread: it talks to the device boundary. They hold different credentials, are set up
/// separately, and either works without the other — which is why neither is nested inside the
/// other's navigation.
///
/// Fleet is first because it answers the question a person opens the app with: is anything
/// waiting for me.
struct RootView: View {

    /// Named `Pane` rather than `Tab`: newer SDKs ship a `Tab` type of their own.
    enum Pane: Hashable {
        case fleet
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
    }

    // MARK: - Fleet

    @ViewBuilder
    private var fleet: some View {
        if let model = appEnvironment.controlPlane,
           let credential = appEnvironment.controlCredential {
            FleetView(model: model, credential: credential) {
                appEnvironment.removeControlConnection()
            }
        } else {
            ControlSetupView()
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
