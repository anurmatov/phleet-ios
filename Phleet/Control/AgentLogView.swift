import SwiftUI

/// The tail of one agent's container log, following it while the screen is open.
///
/// The newest line is at the bottom and the view opens there. Lines can be selected, because the
/// reason to read a log on a phone is usually to quote one line of it to someone.
struct AgentLogView: View {

    let agentName: String

    @Environment(AppEnvironment.self) private var appEnvironment
    @State private var model: AgentLogModel?

    var body: some View {
        Group {
            if let model {
                log(model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text("agentLog.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil {
                model = appEnvironment.makeAgentLogModel(agentName: agentName)
            }
            model?.start()
        }
        .onDisappear {
            model?.stop()
        }
    }

    private func log(_ model: AgentLogModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.tail.droppedCount > 0 {
                    Text("agentLog.truncated")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                }

                ForEach(model.tail.lines) { line in
                    Text(verbatim: line.text.isEmpty ? " " : line.text)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(AccessibilityIdentifier.agentLogLine.identifier)
                }

                AgentLogStateLine(state: model.state, isEmpty: model.tail.lines.isEmpty)
                    .padding(.top, 8)
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier(AccessibilityIdentifier.agentLogReload.identifier)
                .accessibilityLabel(AccessibilityIdentifier.agentLogReload.localizedLabel)
            }
        }
    }
}

/// Whether the log is still being followed.
struct AgentLogStateLine: View {

    let state: AgentLogModel.State
    let isEmpty: Bool

    private var messageKey: LocalizedStringKey {
        switch state {
        case .connecting: return "agentLog.state.connecting"
        case .following: return "agentLog.state.following"
        case .ended: return isEmpty ? "agentLog.state.unavailable" : "agentLog.state.ended"
        }
    }

    private var symbolName: String {
        switch state {
        case .connecting: return "ellipsis.circle"
        case .following: return "dot.radiowaves.up.forward"
        case .ended: return "pause.circle"
        }
    }

    var body: some View {
        Label {
            Text(messageKey).font(.footnote)
        } icon: {
            Image(systemName: symbolName)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.agentLogState.identifier)
    }
}
