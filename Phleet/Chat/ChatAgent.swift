import Foundation

/// An agent a person can chat with, as `GET /api/chat/agents` lists it.
struct ChatAgent: Hashable, Sendable, Identifiable, Decodable {

    /// The agent's unique name. What a conversation is opened with, and what the chat service
    /// routes on.
    let agentName: String

    /// What a person calls it. The orchestrator falls back to the name, and so does this.
    let displayName: String

    var id: String { agentName }

    init(agentName: String, displayName: String) {
        self.agentName = agentName
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case agentName
        case displayName
    }

    /// An entry without a name cannot be chatted with and is dropped by the list; a missing or
    /// blank display name costs only the display name.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .agentName)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .agentName,
                in: container,
                debugDescription: "an agent with no name"
            )
        }
        let display = container.lenient(String.self, .displayName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        agentName = name
        if let display, !display.isEmpty {
            displayName = display
        } else {
            displayName = name
        }
    }
}

/// `GET /api/chat/agents`.
struct ChatAgentList: Equatable, Sendable, Decodable {

    /// Whether this server has chat at all. `false` when the chat service is not deployed or not
    /// connected to the orchestrator, whatever any agent's switch says.
    let available: Bool

    /// The chat-enabled agents, by name.
    let agents: [ChatAgent]

    init(available: Bool, agents: [ChatAgent]) {
        self.available = available
        self.agents = agents
    }

    private enum CodingKeys: String, CodingKey {
        case available
        case agents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Required: an answer that does not say whether chat is available is not this route's.
        available = try container.decode(Bool.self, forKey: .available)
        agents = container.lenient(LossyList<ChatAgent>.self, .agents)?.items ?? []
    }
}
