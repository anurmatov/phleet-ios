import SwiftUI

/// The share sheet: pick an agent, look over what will be sent, send it.
///
/// One screen and one send. There is no thread here and no reply: the message goes into the
/// agent's thread, the same one the app shows, and the answer arrives there.
struct ShareView: View {

    let model: ShareModel
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                agentsSection
                messageSection
                outcomeSection
            }
            .navigationTitle(Text("share.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        cancel()
                    } label: {
                        Text("share.cancel")
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.shareCancel.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.shareCancel.localizedLabel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await model.send() }
                    } label: {
                        Text("share.send")
                    }
                    .disabled(!model.canSend)
                    .accessibilityIdentifier(AccessibilityIdentifier.shareSend.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.shareSend.localizedLabel)
                }
            }
        }
        .onChange(of: model.sending) { _, sending in
            guard case .sent = sending else { return }
            // Long enough to read that it went, then out of the way.
            Task {
                try? await Task.sleep(nanoseconds: 900_000_000)
                done()
            }
        }
    }

    // MARK: - Who to

    @ViewBuilder
    private var agentsSection: some View {
        Section {
            switch model.agents {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)

            case .failed(let failure):
                Label {
                    Text(verbatim: failure.localizedMessage).font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityIdentifier.shareState.identifier)

                Button {
                    Task { await model.loadAgents() }
                } label: {
                    Text("share.retry")
                }

            case .loaded(let agents):
                if agents.isEmpty {
                    Text("share.noAgents")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityIdentifier.shareState.identifier)
                } else {
                    ForEach(agents) { agent in
                        agentRow(agent)
                    }
                }
            }
        } header: {
            Text("share.agents.title")
        }
    }

    private func agentRow(_ agent: ChatAgent) -> some View {
        let isSelected = model.selectedAgentName == agent.agentName
        return Button {
            model.selectedAgentName = agent.agentName
        } label: {
            HStack {
                Text(verbatim: agent.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifier.shareAgent.identifier)
        .accessibilityLabel(agent.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - What

    private var messageSection: some View {
        Section {
            TextField(
                "share.message.prompt",
                text: Binding(get: { model.text }, set: { model.text = $0 }),
                axis: .vertical
            )
            .lineLimit(3...10)
            .accessibilityIdentifier(AccessibilityIdentifier.shareMessage.identifier)
            .accessibilityLabel(AccessibilityIdentifier.shareMessage.localizedLabel)

            if !model.images.isEmpty {
                Label {
                    Text(verbatim: String(model.images.count) + " " + String(localized: "share.images"))
                } icon: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityIdentifier.shareImages.identifier)
            }
        } header: {
            Text("share.message.title")
        } footer: {
            if model.skippedImageCount > 0 {
                Text("share.images.skipped")
            }
        }
    }

    // MARK: - What happened

    @ViewBuilder
    private var outcomeSection: some View {
        switch model.sending {
        case .idle:
            EmptyView()

        case .sending:
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("share.sending")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityIdentifier.shareState.identifier)
            }

        case .sent(let agentName):
            Section {
                Label {
                    Text(verbatim: String(localized: "shortcut.ask.sent") + " " + agentName + ".")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityIdentifier.shareState.identifier)
            } footer: {
                Text("share.sent.help")
            }

        case .failed(let failure):
            Section {
                Label {
                    Text(verbatim: failure.localizedMessage).font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityIdentifier.shareState.identifier)
            }
        }
    }
}
