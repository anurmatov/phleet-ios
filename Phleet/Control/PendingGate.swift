import Foundation

/// A workflow run that is waiting for a person, and the signal it is waiting for.
struct PendingGate: Hashable, Sendable, Identifiable {
    let run: WorkflowRun
    let signal: SignalDefinition

    /// Includes the phase and the gate reference on purpose.
    ///
    /// The same run can stop at the same gate twice. A later visit is a **different** question —
    /// the work under review changed — so it must not inherit "already answered" from the first.
    var id: String {
        [run.namespace, run.workflowId, run.runId, signal.name, run.phase ?? "", run.gateRef ?? ""]
            .joined(separator: "\u{1F}")
    }
}

/// Which runs are waiting for a person.
enum PendingGates {

    /// A run is waiting when it is running, reports a phase, and its workflow type registers a
    /// signal that **names** that phase.
    ///
    /// A signal with no phase list is one the orchestrator accepts at any time; it says nothing
    /// about whether anyone is waiting, so it never puts a run on this list. Showing every such
    /// run as "needs you" would bury the ones that do.
    static func derive(
        runs: [WorkflowRun],
        registry: [String: [SignalDefinition]]
    ) -> [PendingGate] {
        var gates: [PendingGate] = []
        for run in runs where run.isRunning {
            guard let phase = run.phase, !phase.isEmpty else { continue }
            for signal in definitions(for: run.workflowType, in: registry) {
                guard let validPhases = signal.validPhases, validPhases.contains(phase) else {
                    continue
                }
                gates.append(PendingGate(run: run, signal: signal))
            }
        }
        return gates.sorted(by: waitingLongestFirst)
    }

    /// The orchestrator looks a workflow type up without regard to case, so this does too.
    static func definitions(
        for workflowType: String,
        in registry: [String: [SignalDefinition]]
    ) -> [SignalDefinition] {
        if let exact = registry[workflowType] { return exact }
        let wanted = workflowType.lowercased()
        return registry.first { $0.key.lowercased() == wanted }?.value ?? []
    }

    /// Oldest run first. A run with no start time sorts last rather than first: an unknown age
    /// is not evidence of a long wait.
    private static func waitingLongestFirst(_ lhs: PendingGate, _ rhs: PendingGate) -> Bool {
        switch (lhs.run.startTime, rhs.run.startTime) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id < rhs.id
        }
    }
}

/// The body of `POST /api/workflows/{namespace}/signal/{workflowId}`.
///
/// `runId` and `expectedGateRef` are what make a decision safe to send from a screen that may be
/// seconds stale. They are taken from the gate **as it was rendered**, never refreshed on the
/// way out: the orchestrator compares them with the run's current state and answers `409` when
/// the question on screen is no longer the question being asked.
struct SignalRequestBody: Equatable, Sendable, Encodable {
    let signalName: String
    let workflowType: String
    let payload: String
    let runId: String
    let expectedGateRef: String?
}

/// Why a decision could not be put on the wire at all.
enum SignalRequestError: Error, Equatable, Sendable {
    /// The button's payload is not a JSON object, so a comment cannot be merged into it.
    case payloadNotAnObject
    /// The button requires a comment and none was given.
    case commentRequired
}

enum SignalRequest {

    /// Builds the request for one button at one gate.
    ///
    /// A comment is merged into the button's payload under `Comment`, which is the key the
    /// workflows read. Without a comment the payload is sent byte for byte.
    static func body(
        gate: PendingGate,
        button: SignalButton,
        comment: String
    ) throws -> SignalRequestBody {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if button.requiresComment && trimmed.isEmpty {
            throw SignalRequestError.commentRequired
        }

        let payload = trimmed.isEmpty
            ? button.payload
            : try merging(comment: trimmed, into: button.payload)

        return SignalRequestBody(
            signalName: gate.signal.name,
            workflowType: gate.run.workflowType,
            payload: payload,
            runId: gate.run.runId,
            expectedGateRef: gate.run.gateRef
        )
    }

    static func merging(comment: String, into payload: String) throws -> String {
        guard
            let data = payload.data(using: .utf8),
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw SignalRequestError.payloadNotAnObject
        }
        object["Comment"] = comment

        // Sorted so the same decision always produces the same bytes.
        guard
            let merged = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: merged, encoding: .utf8)
        else {
            throw SignalRequestError.payloadNotAnObject
        }
        return text
    }
}
