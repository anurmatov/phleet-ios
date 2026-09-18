import SwiftUI

/// The thread: what has happened, and one place to say something.
struct ConversationView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let model: ConversationModel

    @State private var announcedCount = 0

    var body: some View {
        @Bindable var environment = appEnvironment

        VStack(spacing: 0) {
            ConnectionBanner(state: model.connectionState) {
                Task { await model.resumeManually() }
            }

            transcript

            composer(draft: $environment.composerDraft)
        }
        .navigationTitle(Text("conversation.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.run()
        }
        .onChange(of: model.machine.pendingAnnouncements.count) { _, newValue in
            announce(upTo: newValue)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // One coalesced write on the way out, so a cursor is not left behind by a session
            // that ended between windows.
            if newPhase != .active {
                Task { await model.advanceCursor(force: true) }
            }
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(model.machine.entries) { entry in
                    switch entry {
                    case .submission(let submissionId):
                        if let record = model.machine.record(submissionId) {
                            TranscriptEntryView(
                                record: record,
                                activity: model.machine.activity,
                                sendAgain: { Task { await model.sendAgain(after: submissionId) } }
                            )
                        }

                    case .systemLine(let line):
                        systemLineView(line)

                    case .recoveredAnswer(let reply):
                        // Labelled as recovered from an earlier turn: it arrives with no visible
                        // question attached and reads as a duplicate otherwise.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("conversation.recovered")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(verbatim: reply.text)
                                .font(.body)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier(
                            AccessibilityIdentifier.conversationAgentReply.identifier
                        )
                        .accessibilityLabel(
                            String(localized: "conversation.recovered") + ". " + reply.text
                        )
                    }
                }
            }
            .padding()
        }
        .accessibilityIdentifier(AccessibilityIdentifier.conversationTranscript.identifier)
        .accessibilityLabel(AccessibilityIdentifier.conversationTranscript.localizedLabel)
    }

    private func systemLineView(_ line: SystemLine) -> some View {
        let isGap = line.kind == .replayGap
        return HStack(spacing: 8) {
            Image(systemName: isGap ? "clock.arrow.circlepath" : "info.circle")
                .imageScale(.small)
            // The gap separator is this app's own copy; a notice carries text the server wrote,
            // which is rendered verbatim rather than looked up as a localization key.
            if isGap {
                Text("conversation.gap")
                    .font(.footnote)
            } else {
                Text(verbatim: line.text)
                    .font(.footnote)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(
            isGap
                ? AccessibilityIdentifier.conversationReplayGap.identifier
                : AccessibilityIdentifier.conversationSystemLine.identifier
        )
        .accessibilityLabel(
            isGap
                ? AccessibilityIdentifier.conversationReplayGap.localizedLabel
                : AccessibilityIdentifier.conversationSystemLine.localizedLabel
        )
    }

    private func composer(draft: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.sendFailure {
                Text(failureKey(failure))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.isWithinInboundLimit(draft.wrappedValue) {
                Text("conversation.composer.limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        AccessibilityIdentifier.conversationComposerLimit.identifier
                    )
                    .accessibilityLabel(
                        AccessibilityIdentifier.conversationComposerLimit.localizedLabel
                    )
            }

            composerControls(draft: draft)
        }
        .padding()
        .background(.thinMaterial)
    }

    /// Reflows vertically at accessibility sizes rather than truncating.
    @ViewBuilder
    private func composerControls(draft: Binding<String>) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                composerField(draft: draft)
                sendButton(draft: draft)
            }
        } else {
            HStack(spacing: 8) {
                composerField(draft: draft)
                sendButton(draft: draft)
            }
        }
    }

    private func composerField(draft: Binding<String>) -> some View {
        TextField("conversation.composer.prompt", text: draft, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...5)
            .accessibilityIdentifier(AccessibilityIdentifier.conversationComposer.identifier)
            .accessibilityLabel(AccessibilityIdentifier.conversationComposer.localizedLabel)
    }

    private func sendButton(draft: Binding<String>) -> some View {
        Button {
            let text = draft.wrappedValue
            draft.wrappedValue = ""
            Task { await model.send(text) }
        } label: {
            Text("conversation.send")
                .font(.headline)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.isWithinInboundLimit(draft.wrappedValue)
        )
        .accessibilityIdentifier(AccessibilityIdentifier.conversationSend.identifier)
        .accessibilityLabel(AccessibilityIdentifier.conversationSend.localizedLabel)
        .accessibilityHint(Text("conversation.send.hint"))
    }

    private func failureKey(_ failure: ConversationModel.SendFailure) -> LocalizedStringKey {
        switch failure {
        case .tooLarge: return "conversation.send.failure.tooLarge"
        case .idempotencyConflict: return "conversation.send.failure.idempotencyConflict"
        case .notKnownToHaveHappened: return "conversation.send.failure.notKnown"
        }
    }

    /// Posts an announcement for each terminal that has arrived since the last one.
    ///
    /// `turn.outcome_unknown` must announce: a spinner that quietly stops is unreadable to
    /// VoiceOver, and someone re-running work that already ran is exactly the misread this
    /// state exists to prevent.
    private func announce(upTo newCount: Int) {
        let announcements = model.machine.pendingAnnouncements
        guard newCount > announcedCount else {
            announcedCount = newCount
            return
        }
        for announcement in announcements.suffix(newCount - announcedCount) {
            AccessibilityNotification.Announcement(
                String(localized: announcementResource(for: announcement.kind))
            ).post()
        }
        announcedCount = newCount
    }

    private func announcementResource(for kind: EventKind) -> String.LocalizationValue {
        switch kind {
        case .turnFinal: return "conversation.announcement.final"
        case .turnError: return "conversation.announcement.error"
        case .turnCanceled: return "conversation.announcement.canceled"
        case .turnOutcomeUnknown: return "conversation.announcement.outcomeUnknown"
        default: return "conversation.announcement.final"
        }
    }
}
