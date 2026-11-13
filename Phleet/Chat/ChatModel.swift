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

    private let api: ControlAPIClient
    private let connection: ControlConnection
    private let chatAPI: FleetAPIClient
    private let tokens: AccessTokenHolder
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
        makeConversation: @escaping @MainActor (ChatAgent, SessionLimits) -> ConversationModel
    ) {
        self.api = api
        self.connection = connection
        self.chatAPI = chatAPI
        self.tokens = tokens
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
