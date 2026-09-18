import Foundation

/// Which submissions a terminal closes.
///
/// Correlating strictly by `identity.submissionId` gets this wrong, and the failure is silent:
/// a message folded into a running turn — `submission.accepted { disposition: "injected" }` — or
/// coalesced with others at turn start **never receives a terminal whose `identity.submissionId`
/// is its own**. Nothing else will ever close it, so it spins forever.
///
/// Three rules, and the first is what makes the other two safe.
///
/// 1. A submission dispositioned `injected` never owns a turn and never owns a spinner. It is
///    *attached* to the turn currently running.
/// 2. `mergedSubmissionIds` on a terminal is authoritative closure for every id it lists,
///    including the host. An id the client has never seen is ignored, never synthesised.
/// 3. `turn.error` and `turn.outcome_unknown` carry **no** merged list — their payloads are
///    `{ code, message }` and `{ reason }`. The host turn's terminal therefore closes every
///    submission attached to that turn, by rule 1's attachment, with the same terminal state.
enum MergedTurnClosure {

    /// What a terminal event resolves.
    struct Closure: Equatable, Sendable {
        /// Every submission the terminal closes, in send order.
        let closedSubmissionIds: [String]

        /// The submission the agent's single reply attaches to: the **last** of the group in
        /// send order. There is no duplicated reply bubble per child and no synthetic per-child
        /// terminal — one turn produced one answer, and the interface says so.
        let replyOwnerId: String?

        /// Ids named in `mergedSubmissionIds` that this client has never seen. Ignored; recorded
        /// only so the fact can be logged.
        let unknownMergedIds: [String]

        /// More than one submission was answered by this turn, so each of them carries the
        /// "answered together" marker.
        var isMergedGroup: Bool { closedSubmissionIds.count > 1 }
    }

    /// Computes the closure a terminal event produces.
    ///
    /// - Parameters:
    ///   - event: a terminal event. Passing a non-terminal kind yields an empty closure.
    ///   - knownSubmissionIdsInSendOrder: every submission this client has a record of, oldest
    ///     first. Both membership and ordering are read from it.
    ///   - attachedSubmissionIds: submissions attached to the turn this terminal ends.
    static func closure(
        for event: ConversationEvent,
        knownSubmissionIdsInSendOrder: [String],
        attachedSubmissionIds: [String]
    ) -> Closure {
        guard event.kind.isTerminal else {
            return Closure(closedSubmissionIds: [], replyOwnerId: nil, unknownMergedIds: [])
        }

        let merged = event.payload.mergedSubmissionIds
        let known = Set(knownSubmissionIdsInSendOrder)

        var candidates: Set<String> = []
        if let host = event.identity.submissionId {
            candidates.insert(host)
        }
        candidates.formUnion(merged)
        candidates.formUnion(attachedSubmissionIds)

        // Rule 2: an id the client has never seen is ignored. Synthesising a placeholder message
        // for it would put a bubble on screen for something nobody on this device sent.
        let closed = knownSubmissionIdsInSendOrder.filter { candidates.contains($0) }
        let unknown = merged.filter { !known.contains($0) }

        return Closure(
            closedSubmissionIds: closed,
            replyOwnerId: closed.last,
            unknownMergedIds: unknown
        )
    }
}
