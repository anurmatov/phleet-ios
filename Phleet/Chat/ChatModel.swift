import Foundation
import Observation

/// Who this phone can chat with, and one thread with each.
///
/// The list comes from the orchestrator (`GET /api/chat/agents`), which owns the per-agent chat
/// switch. Each agent has one thread, opened as `"main"` — the same one the dashboard opens — and
/// its model is kept for as long as this sign-in, so leaving a thread and coming back keeps the
/// transcript and resumes from where it was rather than from nothing.
@MainActor
@Observable
final class ChatModel {

    enum State: Equatable, Sendable {
        case loading
        /// The list was read. It may be empty: no agent has chat turned on.
        case loaded
        /// This server has no chat: the chat service is not deployed, or not connected.
        case notAvailable
        /// The list could not be read. Whatever was read before stays on screen.
        case failed(ControlPlaneModel.Failure)
    }

    private(set) var state: State = .loading
    private(set) var agents: [ChatAgent] = []

    /// The limits the chat service enforces. The documented defaults until it has said.
    private(set) var limits: SessionLimits = .documentedDefaults

    /// What the chat service says about each agent's thread, by agent name: when it was last
    /// active and how far it has got. Empty until read, and for an agent never written to.
    private(set) var threads: [String: ConversationSummary] = [:]

    /// The furthest position this phone has shown of each thread, by agent name.
    private(set) var seenPositions: [String: Int]

    private let api: ControlAPIClient
    private let connection: ControlConnection
    private let chatAPI: FleetAPIClient
    private let tokens: AccessTokenHolder
    private let preferences: PreferenceStore
    private let makeConversation: @MainActor (ChatAgent, SessionLimits) -> ConversationModel

    /// Not observed: a thread's model is made the first time its screen asks for it, which is
    /// while that screen is being built, and recording it must not invalidate the screen.
    @ObservationIgnored private var conversations: [String: ConversationModel] = [:]
    @ObservationIgnored private var hasReadLimits = false

    init(
        api: ControlAPIClient,
        connection: ControlConnection,
        chatAPI: FleetAPIClient,
        tokens: AccessTokenHolder,
        preferences: PreferenceStore = InMemoryPreferenceStore(),
        makeConversation: @escaping @MainActor (ChatAgent, SessionLimits) -> ConversationModel
    ) {
        self.api = api
        self.connection = connection
        self.chatAPI = chatAPI
        self.tokens = tokens
        self.preferences = preferences
        self.seenPositions = preferences.integers(forKey: PreferenceKey.seenThreadPositions)
        self.makeConversation = makeConversation
    }

    /// Reads who can be chatted with. Replaces the list, so an agent whose chat was turned off
    /// is gone from it.
    func load() async {
        do {
            let list = try await api.chatAgents(connection)
            agents = list.agents
            state = list.available ? .loaded : .notAvailable
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(Self.failure(for: error))
            return
        }

        if state == .loaded && !hasReadLimits {
            await readLimits()
        }
        if state == .loaded {
            await readThreads()
        }
    }

    // MARK: - What is new

    /// Whether an agent's thread has moved on since this phone last showed it.
    ///
    /// "Moved on" is all it claims. The newest event may be the agent's reply, a message sent
    /// from the dashboard, or progress on a turn still running — the list says there is
    /// something to look at, not what it is, and never how many.
    func hasNewActivity(_ agent: ChatAgent) -> Bool {
        guard let thread = threads[agent.agentName] else { return false }
        return thread.nextSeq - 1 > (seenPositions[agent.agentName] ?? 0)
    }

    func lastActivity(_ agent: ChatAgent) -> Date? {
        threads[agent.agentName]?.lastActivityAt
    }

    /// Records how far a thread has been shown. Called while its screen is open, so what was
    /// read there is not announced as new on the way back to the list.
    func markSeen(_ agent: ChatAgent, position: Int) {
        guard position > (seenPositions[agent.agentName] ?? 0) else { return }
        seenPositions[agent.agentName] = position
        preferences.setIntegers(seenPositions, forKey: PreferenceKey.seenThreadPositions)
    }

    /// `GET /v1/conversations`, for the thread each agent has under the reference both clients
    /// use. Best effort: without it the list shows no times and no marks, and still opens.
    private func readThreads() async {
        let origin = connection.origin
        let chatAPI = self.chatAPI
        do {
            let list = try await tokens.authorized { token in
                try await chatAPI.conversations(origin: origin, accessToken: token)
            }
            var byAgent: [String: ConversationSummary] = [:]
            for conversation in list.conversations
            where conversation.externalRef == ConversationModel.externalRef {
                byAgent[conversation.agent] = conversation
            }
            threads = byAgent
        } catch {
            // What was read before stands.
        }
    }

    /// The agent with this name, if it is one that can be chatted with.
    func agent(named name: String) -> ChatAgent? {
        agents.first { $0.agentName == name }
    }

    /// This agent's thread. The same model every time, for the life of the sign-in.
    func conversation(for agent: ChatAgent) -> ConversationModel {
        if let existing = conversations[agent.agentName] {
            return existing
        }
        let model = makeConversation(agent, limits)
        conversations[agent.agentName] = model
        return model
    }

    /// `GET /v1/session`, once, for the limits a thread opened later is sized by. Best effort:
    /// a thread works within the documented defaults, and this is tried again on the next load.
    private func readLimits() async {
        let origin = connection.origin
        let chatAPI = self.chatAPI
        do {
            let session = try await tokens.authorized { token in
                try await chatAPI.session(origin: origin, accessToken: token)
            }
            limits = session.limits
            hasReadLimits = true
        } catch {
            // The documented defaults stand.
        }
    }

    private static func failure(for error: Error) -> ControlPlaneModel.Failure {
        switch error as? ControlAPIError {
        case .accessDenied?:
            return .accessDenied
        case .transport?:
            return .unreachable
        case .decoding?, .unauthorized?, .gateChanged?, .refused?, nil:
            return .unexpectedAnswer
        }
    }
}
