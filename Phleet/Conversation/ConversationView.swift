import PhotosUI
import SwiftUI
import UIKit

/// The thread: what has happened, and one place to say something.
///
/// Keyboard behaviour is the platform's, not this app's. Scrolling dismisses through
/// `scrollDismissesKeyboard(.interactively)` rather than a gesture recogniser watching the
/// content offset, so the keyboard tracks the finger and comes back if the drag is reversed —
/// which is the part a hand-rolled version never gets right. A tap outside the composer also
/// dismisses, attached as a *simultaneous* gesture so it cannot swallow the long press and
/// double tap that selecting message text depends on.
struct ConversationView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let model: ConversationModel

    /// Told how far the thread has been shown, while it is on screen, so the list it was opened
    /// from does not announce what was just read as new.
    var onSeen: ((Int) -> Void)?

    /// Opens this agent's own screen. `nil` where the fleet does not list it.
    var openAgent: (() -> Void)?

    @State private var announcedCount = 0
    @State private var pickedItems: [PhotosPickerItem] = []

    @FocusState private var composerFocused: Bool

    @ScaledMetric(relativeTo: .body) private var draftImageSide: CGFloat = 56

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner(state: model.connectionState) {
                Task { await model.resumeManually() }
            }

            transcript

            composer(draft: draft)
        }
        .navigationTitle(Text(verbatim: model.agent.displayName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let openAgent {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        openAgent()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.conversationAgentInfo.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.conversationAgentInfo.localizedLabel)
                }
            }
        }
        .task {
            await model.run()
        }
        .onChange(of: model.machine.pendingAnnouncements.count) { _, newValue in
            announce(upTo: newValue)
        }
        .onChange(of: model.lastAppliedSeq, initial: true) { _, position in
            onSeen?(position)
        }
        .onChange(of: pickedItems) { _, items in
            addPicked(items)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // One coalesced write on the way out, so a cursor is not left behind by a session
            // that ended between windows.
            if newPhase != .active {
                Task { await model.advanceCursor(force: true) }
            }
        }
    }

    /// This agent's draft. Held on the environment, one per agent, so a message typed to one
    /// agent is never offered for sending to another — and so signing out does not discard it.
    private var draft: Binding<String> {
        let environment = appEnvironment
        let agentName = model.agent.agentName
        return Binding(
            get: { environment.draft(for: agentName) },
            set: { environment.setDraft($0, for: agentName) }
        )
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
                                images: model.images,
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
                            // Its own elements, for the same reason as every other body: text
                            // merged into an opaque parent cannot be long-pressed, so it cannot
                            // be selected. An agent's words, so rendered as Markdown.
                            MarkdownBlocksView(
                                text: reply.text,
                                identifier: .conversationReplyBody,
                                spokenPrefix: String(localized: "conversation.recovered"),
                                copyActionKey: "conversation.copy.reply"
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(
                            AccessibilityIdentifier.conversationAgentReply.identifier
                        )
                    }
                }
            }
            .padding()
        }
        // A conversation opens at its newest entry, not its oldest. The stock anchor does it at
        // render time, so there is no visible flight to the bottom, and the view follows the
        // bottom as content arrives. Deliberately not a `ScrollViewReader` with offset maths:
        // scroll position is a view concern and the platform already models it.
        //
        // Both of those are asserted by tests. The third criterion in #10 — that an event
        // arriving while someone has scrolled up leaves the viewport where they left it — is
        // **not** asserted here and is not claimed: the scripted backend only emits in response
        // to a send, so there is no unsolicited event to land on a scrolled-up view. Recorded as
        // a gap on #10 rather than described as behaviour nobody checked.
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        // Covers the area below short content, so an early thread with two messages in it
        // dismisses on a tap in the empty space the same way a full one does.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
        .accessibilityIdentifier(AccessibilityIdentifier.conversationTranscript.identifier)
        .accessibilityLabel(AccessibilityIdentifier.conversationTranscript.localizedLabel)
    }

    @ViewBuilder
    private func systemLineView(_ line: SystemLine) -> some View {
        if line.kind == .nothingToStop {
            // This app's own words for an acknowledgement that carries none: a stop was asked
            // for, and there was nothing running to stop.
            HStack(spacing: 8) {
                Image(systemName: "stop.circle")
                    .imageScale(.small)
                Text("conversation.stop.nothing")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityIdentifier.conversationStopNotice.identifier)
        } else {
            notedLine(line)
        }
    }

    private func notedLine(_ line: SystemLine) -> some View {
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
            stopRow

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

            draftImagesRow

            if let failure = model.attachmentFailure {
                Text(attachmentFailureKey(failure))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        AccessibilityIdentifier.conversationAttachmentNotice.identifier
                    )
            }

            composerControls(draft: draft)

            if model.attachmentsUnsupported {
                // Said plainly rather than implied by a button that went away: this server has
                // images switched off, and someone looking for the picker should find out why
                // instead of concluding the app is broken.
                Text("conversation.media.unsupported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        AccessibilityIdentifier.conversationMediaUnsupported.identifier
                    )
                    .accessibilityLabel(
                        AccessibilityIdentifier.conversationMediaUnsupported.localizedLabel
                    )
            }
        }
        .padding()
        .background(.thinMaterial)
    }

    /// Stop, while a turn of this thread is running. One tap: stopping costs the answer that was
    /// on its way and nothing else, and the moment it is wanted is the moment a second tap is
    /// one too many.
    @ViewBuilder
    private var stopRow: some View {
        if model.canStop || model.isStopping {
            Button(role: .destructive) {
                Task { await model.stop() }
            } label: {
                Label {
                    Text(model.isStopping ? "conversation.stop.stopping" : "conversation.stop")
                } icon: {
                    Image(systemName: "stop.circle")
                }
                .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .disabled(model.isStopping)
            .accessibilityIdentifier(AccessibilityIdentifier.conversationStop.identifier)
            .accessibilityLabel(AccessibilityIdentifier.conversationStop.localizedLabel)
        }

        if let failure = model.stopFailure {
            Text(stopFailureKey(failure))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityIdentifier.conversationStopNotice.identifier)
        }
    }

    /// The images picked for this message, each with a way to take it back out.
    @ViewBuilder
    private var draftImagesRow: some View {
        if !model.draftImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.draftImages) { image in
                        draftImage(image)
                    }
                    if model.isUploading {
                        ProgressView()
                    }
                }
            }
        }
    }

    private func draftImage(_ image: ConversationModel.OutgoingImage) -> some View {
        ZStack(alignment: .topTrailing) {
            if let picture = UIImage(data: image.jpeg) {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: draftImageSide, height: draftImageSide)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier(
                        AccessibilityIdentifier.conversationAttachment.identifier
                    )
                    .accessibilityLabel(
                        AccessibilityIdentifier.conversationAttachment.localizedLabel
                    )
            }

            Button {
                model.removeImage(id: image.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .disabled(model.isUploading)
            .accessibilityIdentifier(
                AccessibilityIdentifier.conversationAttachmentRemove.identifier
            )
            .accessibilityLabel(
                AccessibilityIdentifier.conversationAttachmentRemove.localizedLabel
            )
        }
    }

    /// Reflows vertically at accessibility sizes rather than truncating.
    @ViewBuilder
    private func composerControls(draft: Binding<String>) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                composerField(draft: draft)
                HStack(spacing: 12) {
                    imagePicker
                    sendButton(draft: draft)
                }
            }
        } else {
            HStack(spacing: 8) {
                imagePicker
                composerField(draft: draft)
                sendButton(draft: draft)
            }
        }
    }

    /// The system's photo picker. It runs outside this app and hands over only what was picked,
    /// so nothing here asks for access to the photo library.
    @ViewBuilder
    private var imagePicker: some View {
        if !model.attachmentsUnsupported {
            PhotosPicker(
                selection: $pickedItems,
                maxSelectionCount: max(
                    1,
                    ConversationModel.maxImagesPerMessage - model.draftImages.count
                ),
                matching: .images
            ) {
                // The hook is on the label as well as the picker: the picker is the system's
                // control, and where it puts an identifier given to it is the system's business.
                Image(systemName: "photo.on.rectangle.angled")
                    .imageScale(.large)
                    .accessibilityIdentifier(AccessibilityIdentifier.conversationAttach.identifier)
            }
            .disabled(!model.canAddImage)
            .accessibilityIdentifier(AccessibilityIdentifier.conversationAttach.identifier)
            .accessibilityLabel(AccessibilityIdentifier.conversationAttach.localizedLabel)
        }
    }

    /// Takes what the picker returned, one image at a time, and clears the selection so the same
    /// photo can be picked again later.
    private func addPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickedItems = []
        Task {
            for item in items {
                // No bytes is the same failure as bytes that are not an image: empty data is
                // refused by the same check, with the same words.
                let data = (try? await item.loadTransferable(type: Data.self)) ?? Data()
                model.addImage(data)
            }
        }
    }

    private func composerField(draft: Binding<String>) -> some View {
        TextField("conversation.composer.prompt", text: draft, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...5)
            .focused($composerFocused)
            .accessibilityIdentifier(AccessibilityIdentifier.conversationComposer.identifier)
            .accessibilityLabel(AccessibilityIdentifier.conversationComposer.localizedLabel)
    }

    private func sendButton(draft: Binding<String>) -> some View {
        Button {
            // Captured before anything else touches the field, and restored only if it was
            // already focused. A burst of messages should not cost a tap on the field between
            // each one — but sending from a dismissed keyboard must not re-open it, which is
            // what an unconditional set would do to someone who had just tapped outside.
            let wasFocused = composerFocused
            let text = draft.wrappedValue
            draft.wrappedValue = ""
            if wasFocused {
                composerFocused = true
            }
            Task {
                let sent = await model.send(text)
                // An image that did not go up sent nothing. The words go back in the field,
                // beside the images that are still there, unless something was typed meanwhile.
                if sent == nil, model.attachmentFailure != nil, draft.wrappedValue.isEmpty {
                    draft.wrappedValue = text
                }
            }
        } label: {
            Text("conversation.send")
                .font(.headline)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSend(draft.wrappedValue))
        .accessibilityIdentifier(AccessibilityIdentifier.conversationSend.identifier)
        .accessibilityLabel(AccessibilityIdentifier.conversationSend.localizedLabel)
        .accessibilityHint(Text("conversation.send.hint"))
    }

    /// Words, or at least one image, within the size limit, and no upload already under way.
    private func canSend(_ text: String) -> Bool {
        let hasWords = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasWords || !model.draftImages.isEmpty else { return false }
        return model.isWithinInboundLimit(text) && !model.isUploading
    }

    private func stopFailureKey(_ failure: ConversationModel.StopFailure) -> LocalizedStringKey {
        switch failure {
        case .agentUnavailable: return "conversation.send.failure.agentUnavailable"
        case .notSent: return "conversation.stop.failure.notSent"
        }
    }

    private func attachmentFailureKey(
        _ failure: ConversationModel.AttachmentFailure
    ) -> LocalizedStringKey {
        switch failure {
        case .unreadable: return "conversation.attachment.failure.unreadable"
        case .tooMany: return "conversation.attachment.failure.tooMany"
        case .unsupportedServer: return "conversation.attachment.failure.unsupported"
        case .refused: return "conversation.attachment.failure.refused"
        case .notSent: return "conversation.attachment.failure.notSent"
        }
    }

    private func failureKey(_ failure: ConversationModel.SendFailure) -> LocalizedStringKey {
        switch failure {
        case .tooLarge: return "conversation.send.failure.tooLarge"
        case .idempotencyConflict: return "conversation.send.failure.idempotencyConflict"
        case .agentUnavailable: return "conversation.send.failure.agentUnavailable"
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
