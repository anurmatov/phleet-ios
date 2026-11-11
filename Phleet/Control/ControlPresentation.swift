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
