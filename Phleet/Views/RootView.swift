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

    var body: some View {
        if appEnvironment.isSignedIn {
            tabs
        } else {
            NavigationStack {
                SetupView()
            }
        }
    }

    private var tabs: some View {
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
        case .chat: selection = .chat
        }
        appEnvironment.requestedDestination = nil
    }

    // MARK: - Fleet

    @ViewBuilder
    private var fleet: some View {
        if let model = appEnvironment.controlPlane, let credential = appEnvironment.credential {
            FleetView(model: model, credential: credential, push: appEnvironment.pushNotifications)
        } else {
            ProgressView()
        }
    }

    // MARK: - Runs

    @ViewBuilder
    private var runs: some View {
        if let fleet = appEnvironment.controlPlane, let runs = appEnvironment.runs {
            RunsView(fleet: fleet, runs: runs)
        } else {
            ProgressView()
        }
    }

    // MARK: - Chat

    @ViewBuilder
    private var chat: some View {
        if let chat = appEnvironment.chat {
            ChatView(model: chat)
        } else {
            ProgressView()
        }
    }
}
