import AppIntents
import Foundation

/// The two things this app offers to Shortcuts, Siri and the Action button.
///
/// Reading, and sending a message. Neither answers a gate, starts a workflow or acts on an
/// agent: those are sent from a screen that shows what is being decided, with two taps. A
/// shortcut can run from a lock screen or a watch, and an approval should not.

/// Why a shortcut could not do what it was asked, in words.
struct QuickActionError: Error, CustomLocalizedStringResourceConvertible {

    let failure: QuickActions.Failure

    var localizedStringResource: LocalizedStringResource {
        switch failure {
        case .signedOut: return "shortcut.failure.signedOut"
        case .unreachable: return "shortcut.failure.unreachable"
        case .agentUnavailable: return "shortcut.failure.agentUnavailable"
        case .tooLong: return "shortcut.failure.tooLong"
        case .imagesUnsupported: return "shortcut.failure.imagesUnsupported"
        case .refused: return "shortcut.failure.refused"
        }
    }

    /// Runs `operation`, turning what it throws into something a shortcut can say.
    static func saying<Value>(_ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch let failure as QuickActions.Failure {
            throw QuickActionError(failure: failure)
        } catch {
            throw QuickActionError(failure: .unreachable)
        }
    }
}

/// "What needs me": how many runs are waiting and which agents are down.
struct FleetStatusIntent: AppIntent {

    static let title: LocalizedStringResource = "shortcut.status.title"
    static let description = IntentDescription("shortcut.status.description")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let summary = try await QuickActionError.saying {
            try await QuickActions.live().fleetSummary()
        }
        return .result(value: summary.waiting.count, dialog: "\(summary.spoken)")
    }
}

/// An agent that can be chatted with, as Shortcuts offers it.
struct ChatAgentEntity: AppEntity {

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "shortcut.agent.type")
    static let defaultQuery = ChatAgentQuery()

    /// The agent's unique name: what a message is addressed to.
    let id: String
    let displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

/// Reads who can be chatted with from the server each time, so an agent whose chat was turned
/// off is not offered and one that was just turned on is.
struct ChatAgentQuery: EntityQuery {

    func entities(for identifiers: [String]) async throws -> [ChatAgentEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ChatAgentEntity] {
        let agents = try await QuickActionError.saying {
            try await QuickActions.live().chatAgents()
        }
        return agents.map { ChatAgentEntity(id: $0.agentName, displayName: $0.displayName) }
    }
}

/// "Ask an agent": one message into that agent's thread.
struct AskAgentIntent: AppIntent {

    static let title: LocalizedStringResource = "shortcut.ask.title"
    static let description = IntentDescription("shortcut.ask.description")

    @Parameter(title: "shortcut.ask.agent")
    var agent: ChatAgentEntity

    @Parameter(title: "shortcut.ask.message")
    var message: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = message
        let name = agent.id
        try await QuickActionError.saying {
            try await QuickActions.live().send(text, toAgentNamed: name)
        }
        let sent = String(localized: "shortcut.ask.sent", bundle: .main) + " " + agent.displayName + "."
        return .result(dialog: "\(sent)")
    }
}

/// What appears in Shortcuts and Spotlight without anyone building a shortcut first.
struct PhleetShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FleetStatusIntent(),
            phrases: [
                "What needs me in \(.applicationName)",
                "\(.applicationName) status"
            ],
            shortTitle: "shortcut.status.title",
            systemImageName: "square.grid.2x2"
        )
        AppShortcut(
            intent: AskAgentIntent(),
            phrases: [
                "Ask an agent in \(.applicationName)",
                "Ask \(\.$agent) in \(.applicationName)"
            ],
            shortTitle: "shortcut.ask.title",
            systemImageName: "bubble.left.and.bubble.right"
        )
    }
}
