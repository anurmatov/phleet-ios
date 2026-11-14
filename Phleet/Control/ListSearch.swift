import Foundation

/// Narrowing the agent and run lists by what was typed.
///
/// Every word typed must be found somewhere in the row — in any order, without regard to case or
/// accents — so "review 42" finds the reviewer's run on pull request 42. Nothing is sent
/// anywhere: this filters what has already been read.
enum ListSearch {

    static func terms(in query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func matches(fields: [String?], query: String) -> Bool {
        let wanted = terms(in: query)
        guard !wanted.isEmpty else { return true }
        let present = fields.compactMap { $0 }
        return wanted.allSatisfy { term in
            present.contains { $0.localizedStandardContains(term) }
        }
    }

    static func matches(_ agent: FleetAgent, query: String) -> Bool {
        matches(
            fields: [
                agent.agentName,
                agent.displayName,
                agent.role,
                agent.model,
                agent.currentTask,
                agent.health.localizedLabel
            ],
            query: query
        )
    }

    static func matches(_ run: WorkflowRun, query: String) -> Bool {
        matches(
            fields: [
                RunSubject.text(for: run),
                run.workflowId,
                run.workflowType,
                run.phase,
                run.outcome.localizedLabel
            ],
            query: query
        )
    }

    static func matches(_ gate: PendingGate, query: String) -> Bool {
        matches(gate.run, query: query)
            || matches(fields: [gate.heading, gate.signal.name], query: query)
    }
}
