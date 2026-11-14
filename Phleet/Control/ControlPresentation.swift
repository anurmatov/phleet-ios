import Foundation

/// How control-plane values are worded.
///
/// Kept out of the views so the wording is one decision, read by the row, the detail screen and
/// the spoken label alike — a row that says "Down" and a label that says "Offline" for the same
/// agent is the kind of drift this prevents.
extension AgentHealth {

    /// A shape as well as a colour: state is never carried by colour alone.
    var symbolName: String {
        switch self {
        case .down: return "xmark.octagon.fill"
        case .stale: return "exclamationmark.triangle.fill"
        case .working: return "circle.fill"
        case .idle: return "circle"
        case .stopped: return "stop.circle"
        case .notProvisioned: return "circle.dashed"
        case .unknown: return "questionmark.circle"
        }
    }

    var labelKey: String {
        switch self {
        case .down: return "agent.health.down"
        case .stale: return "agent.health.stale"
        case .working: return "agent.health.working"
        case .idle: return "agent.health.idle"
        case .stopped: return "agent.health.stopped"
        case .notProvisioned: return "agent.health.notProvisioned"
        case .unknown: return "agent.health.unknown"
        }
    }

    /// The label a person reads. An unrecognised status is shown as the orchestrator spelled it,
    /// because that spelling is the only thing known about it.
    var localizedLabel: String {
        if case .unknown(let raw) = self, !raw.isEmpty {
            return raw
        }
        return String(localized: String.LocalizationValue(labelKey), bundle: .main)
    }
}

/// What a run is about, in the fewest words that identify it.
enum RunSubject {

    /// The repository and the pull request or issue, falling back to the workflow identifier
    /// when the run reports neither. The number is written without grouping separators: it is
    /// an identifier, not a quantity.
    static func text(for run: WorkflowRun) -> String {
        var parts: [String] = []
        if let repo = run.repo?.trimmingCharacters(in: .whitespacesAndNewlines), !repo.isEmpty {
            parts.append(repo)
        }
        if let pullRequest = run.prNumber {
            parts.append(String(localized: "run.pullRequest", bundle: .main) + " #" + String(pullRequest))
        } else if let issue = run.issueNumber {
            parts.append(String(localized: "run.issue", bundle: .main) + " #" + String(issue))
        }
        return parts.isEmpty ? run.workflowId : parts.joined(separator: " · ")
    }
}

extension PendingGate {

    /// The signal's name as a heading: the orchestrator spells labels in lower case.
    var heading: String {
        let label = signal.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = label.first else { return signal.name }
        return first.uppercased() + label.dropFirst()
    }
}

extension AgentAction {

    /// What is worth offering for an agent in a given state.
    ///
    /// Restart rather than start for an agent that has gone quiet: a restart brings a stopped
    /// container up as well as recycling a hung one, so it is right whichever of the two "no
    /// heartbeat" turns out to mean. An agent that was never provisioned has no container to act
    /// on; that is done from the dashboard.
    ///
    /// Reprovisioning is offered wherever there is a container to recreate: it is what a changed
    /// model, instruction or harness setting waits for, and it brings a stopped agent up as well.
    static func available(for health: AgentHealth) -> [AgentAction] {
        switch health {
        case .working: return [.cancelTask, .restart, .stop, .reprovision]
        case .idle: return [.restart, .stop, .reprovision]
        case .down, .stale, .unknown: return [.restart, .stop, .reprovision]
        case .stopped: return [.start, .reprovision]
        case .notProvisioned: return []
        }
    }

    var titleKey: String {
        switch self {
        case .cancelTask: return "agentAction.cancelTask"
        case .restart: return "agentAction.restart"
        case .stop: return "agentAction.stop"
        case .start: return "agentAction.start"
        case .reprovision: return "agentAction.reprovision"
        }
    }

    var localizedTitle: String {
        String(localized: String.LocalizationValue(titleKey), bundle: .main)
    }

    var symbolName: String {
        switch self {
        case .cancelTask: return "xmark.circle"
        case .restart: return "arrow.clockwise.circle"
        case .stop: return "stop.circle"
        case .start: return "play.circle"
        case .reprovision: return "shippingbox.circle"
        }
    }

    /// Stopping, restarting and reprovisioning interrupt whatever the agent is doing.
    var isDisruptive: Bool {
        switch self {
        case .cancelTask, .restart, .stop, .reprovision: return true
        case .start: return false
        }
    }
}

extension WorkflowRun.Outcome {

    var symbolName: String {
        switch self {
        case .running: return "play.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .canceled: return "xmark.circle"
        case .other: return "questionmark.circle"
        }
    }

    var labelKey: String {
        switch self {
        case .running: return "run.outcome.running"
        case .completed: return "run.outcome.completed"
        case .failed: return "run.outcome.failed"
        case .canceled: return "run.outcome.canceled"
        case .other: return "run.outcome.other"
        }
    }

    /// An unrecognised status is shown as the orchestrator spelled it.
    var localizedLabel: String {
        if case .other(let raw) = self, !raw.isEmpty {
            return raw
        }
        return String(localized: String.LocalizationValue(labelKey), bundle: .main)
    }
}

extension WorkflowEvent {

    /// The event's name with spaces: `ActivityCompleted` reads as "Activity completed".
    var title: String {
        var words: [String] = []
        var current = ""
        for character in eventType {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty {
            words.append(current)
        }
        guard let first = words.first else { return eventType }
        return ([first] + words.dropFirst().map { $0.lowercased() }).joined(separator: " ")
    }

    /// What the event was about, when it says: the agent, the activity, or the signal.
    var subject: String? {
        let parts = [agent, signalName ?? activityType].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The failure when there is one, the output otherwise.
    var detail: String? {
        for candidate in [failureMessage, outputSummary] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return nil
    }
}
