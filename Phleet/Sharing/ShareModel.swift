import Foundation
import Observation

/// Sending something from another app to an agent: who to, what, and what happened.
///
/// The share sheet's whole behaviour, with nothing of the sheet in it, so it is tested in the
/// app's own test suite. It runs in the extension's process, where there is no thread on screen
/// and no stream to listen to: it sends, says that it sent, and the reply arrives in the app.
@MainActor
@Observable
final class ShareModel {

    enum Agents: Equatable, Sendable {
        case loading
        /// Read. May be empty: no agent has chat turned on.
        case loaded([ChatAgent])
        case failed(QuickActions.Failure)
    }

    enum Sending: Equatable, Sendable {
        case idle
        case sending
        /// Accepted by the server. The sheet closes.
        case sent(agentName: String)
        case failed(QuickActions.Failure)
    }

    /// The most a message may carry. The server refuses a fifth.
    nonisolated static let maxImages = 4

    private let actions: QuickActions
    private let prepareImage: (Data) -> Data?

    private(set) var agents: Agents = .loading
    private(set) var sending: Sending = .idle

    /// The agent the message goes to. The first one listed until another is chosen.
    var selectedAgentName: String?

    /// What will be sent: the shared text and address to begin with, then whatever is typed.
    var text: String

    /// The shared images, converted and ready to go up.
    private(set) var images: [Data] = []

    /// Shared images that could not be read as images, or were more than a message carries.
    private(set) var skippedImageCount = 0

    init(
        actions: QuickActions,
        text: String = "",
        prepareImage: @escaping (Data) -> Data? = { ImagePreparation.jpeg(from: $0) }
    ) {
        self.actions = actions
        self.text = text
        self.prepareImage = prepareImage
    }

    var listedAgents: [ChatAgent] {
        if case .loaded(let agents) = agents { return agents }
        return []
    }

    var selectedAgent: ChatAgent? {
        listedAgents.first { $0.agentName == selectedAgentName }
    }

    /// Something to send, someone to send it to, and no send already under way.
    var canSend: Bool {
        guard selectedAgent != nil, sending != .sending else { return false }
        if case .sent = sending { return false }
        let hasWords = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasWords || !images.isEmpty
    }

    /// Reads who can be chatted with.
    func loadAgents() async {
        agents = .loading
        do {
            let listed = try await actions.chatAgents()
            agents = .loaded(listed)
            if selectedAgent == nil {
                selectedAgentName = listed.first?.agentName
            }
        } catch let failure as QuickActions.Failure {
            agents = .failed(failure)
        } catch {
            agents = .failed(.unreachable)
        }
    }

    /// Adds what was shared, as text: one piece to a paragraph, in the order given.
    func add(texts: [String]) {
        let pieces = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return }
        let existing = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ([existing] + pieces).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Adds one shared image, converted to what the server takes. One that cannot be read, or
    /// that is one too many, is counted and said rather than dropped silently.
    func add(image data: Data) {
        guard images.count < Self.maxImages, let jpeg = prepareImage(data) else {
            skippedImageCount += 1
            return
        }
        images.append(jpeg)
    }

    /// Sends once. A send that did not complete is not tried again under new identifiers: the
    /// person decides, with the failure in front of them.
    func send() async {
        guard canSend, let agent = selectedAgent else { return }
        sending = .sending
        do {
            try await actions.send(text, images: images, toAgentNamed: agent.agentName)
            sending = .sent(agentName: agent.displayName)
        } catch let failure as QuickActions.Failure {
            sending = .failed(failure)
        } catch {
            sending = .failed(.unreachable)
        }
    }
}

extension QuickActions.Failure {

    /// The catalog key that says this failure in words. One wording for a shortcut, the widget
    /// and the share sheet alike.
    var messageKey: String {
        switch self {
        case .signedOut: return "shortcut.failure.signedOut"
        case .unreachable: return "shortcut.failure.unreachable"
        case .agentUnavailable: return "shortcut.failure.agentUnavailable"
        case .tooLong: return "shortcut.failure.tooLong"
        case .imagesUnsupported: return "shortcut.failure.imagesUnsupported"
        case .refused: return "shortcut.failure.refused"
        }
    }

    var localizedMessage: String {
        String(localized: String.LocalizationValue(messageKey), bundle: .main)
    }
}
