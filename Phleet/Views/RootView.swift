import SwiftUI

/// Routes on enrolled, unenrolled and revoked.
///
/// A stale credential whose token has never been minted still counts as enrolled: the device
/// record exists server-side, and the way to find out whether it is alive is to spend it. Only
/// the one sign-out condition — a `401` from the token mint — moves the app back here.
struct RootView: View {

    @Environment(AppEnvironment.self) private var appEnvironment

    @State private var isShowingThread = false

    var body: some View {
        NavigationStack {
            switch appEnvironment.route {
            case .enrollment:
                EnrollmentView()

            case .agent:
                agent
            }
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
                    ConversationView(model: conversation)
                }
            }
        } else {
            ProgressView()
        }
    }
}
