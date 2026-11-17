import Foundation

/// Which run belongs under which.
///
/// The list of running workflows is flat, and several of its rows are one piece of work: a
/// driver, the runs it started, and the reviews those runs started in turn. Two things link them.
/// A run started as a child workflow names its parent. A run a driver started through the start
/// tool is not the engine's child, and names the driver as the run that waits for it. This lays a
/// list out as the tree those links make, without changing which runs are in it or the order of
/// runs at the same level. The same rule as the dashboard's.
enum RunTree {

    /// How a run is tied to the one it sits under.
    enum Link: Equatable, Sendable {
        /// Started as a child workflow.
        case child
        /// Started by a driver that waits for it.
        case started
    }

    /// The run a row belongs to, when that run has no row to nest it under.
    struct Elsewhere: Equatable, Sendable {
        let workflowId: String
        let link: Link
        /// The run itself, when it is known from another list.
        let run: WorkflowRun?
    }

    struct Placed: Equatable, Sendable, Identifiable {
        let run: WorkflowRun
        /// 0 for a run at the top of the list.
        let depth: Int
        /// How it is tied to the row it is nested under. `nil` at the top.
        let link: Link?
        let elsewhere: Elsewhere?

        var id: String { run.identity }
    }

    /// Deeper than this, rows stop moving right: a phone has no room, and the order still says it.
    static let maximumDepth = 4

    /// `runs` in tree order: each run that belongs to another in the list directly after it, one
    /// level in. Every run is placed exactly once.
    /// - Parameter everything: every run known, to name an owner that is not in `runs`.
    static func arrange(_ runs: [WorkflowRun], everything: [WorkflowRun]? = nil) -> [Placed] {
        let known = everything ?? runs
        var owners: [String: (owner: WorkflowRun, link: Link)] = [:]
        var children: [String: [WorkflowRun]] = [:]
        for run in runs {
            guard let tie = owner(of: run, among: runs) else { continue }
            owners[run.identity] = tie
            children[tie.owner.identity, default: []].append(run)
        }

        var placed: [Placed] = []
        var seen = Set<String>()
        func place(_ run: WorkflowRun, depth: Int) {
            guard seen.insert(run.identity).inserted else { return }
            let tie = depth > 0 ? owners[run.identity] : nil
            placed.append(Placed(
                run: run,
                depth: min(depth, maximumDepth),
                link: tie?.link,
                elsewhere: tie == nil ? elsewhere(for: run, in: runs, everything: known) : nil
            ))
            for child in children[run.identity] ?? [] {
                place(child, depth: depth + 1)
            }
        }
        for run in runs where owners[run.identity] == nil {
            place(run, depth: 0)
        }
        // Runs that only point at each other have no top: each still gets its row.
        for run in runs {
            place(run, depth: 0)
        }
        return placed
    }

    /// The run `run` belongs to among `candidates`, and how. The parent wins over the waiter.
    static func owner(of run: WorkflowRun, among candidates: [WorkflowRun]) -> (owner: WorkflowRun, link: Link)? {
        if let parentId = run.parentWorkflowId, !parentId.isEmpty {
            let parent = candidates.first { candidate in
                candidate.identity != run.identity
                    && candidate.namespace == run.namespace
                    && candidate.workflowId == parentId
                    // A workflow id is reused across its runs; the run id says which one.
                    && (run.parentRunId.map { $0.isEmpty || $0 == candidate.runId } ?? true)
            }
            if let parent { return (parent, .child) }
        }
        if let waiterId = run.waiterWorkflowId, !waiterId.isEmpty {
            let waiters = candidates.filter { $0.identity != run.identity && $0.workflowId == waiterId }
            if let waiter = waiters.first(where: { $0.namespace == run.namespace }) ?? waiters.first {
                return (waiter, .started)
            }
        }
        return nil
    }

    private static func elsewhere(for run: WorkflowRun, in runs: [WorkflowRun], everything: [WorkflowRun]) -> Elsewhere? {
        if owner(of: run, among: runs) != nil { return nil }
        if let known = owner(of: run, among: everything) {
            return Elsewhere(workflowId: known.owner.workflowId, link: known.link, run: known.owner)
        }
        if let parentId = run.parentWorkflowId, !parentId.isEmpty {
            return Elsewhere(workflowId: parentId, link: .child, run: nil)
        }
        if let waiterId = run.waiterWorkflowId, !waiterId.isEmpty {
            return Elsewhere(workflowId: waiterId, link: .started, run: nil)
        }
        return nil
    }
}
