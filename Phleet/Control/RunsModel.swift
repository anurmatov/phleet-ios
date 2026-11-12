import Foundation
import Observation

/// Runs that have closed, a run's history, and the two things that can be done about runs from
/// here: cancel one, start one.
///
/// Runs in progress are not held here. They belong to `ControlPlaneModel`, which already reads
/// them on a timer and from the live socket; keeping a second copy would give the same run two
/// states that could disagree.
@MainActor
@Observable
final class RunsModel {

    /// How far back closed runs are read. The orchestrator caps the list regardless.
    nonisolated static let closedWindowHours = 24

    enum Load: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(ControlPlaneModel.Failure)
    }

    enum History: Equatable, Sendable {
        case loading
        case loaded([WorkflowEvent])
        case failed
    }

    enum CancelState: Equatable, Sendable {
        case sending
        /// The orchestrator accepted the request. A workflow winds down in its own time.
        case requested
        case failed(ControlPlaneModel.ActionFailure)
    }

    enum StartState: Equatable, Sendable {
        case idle
        case sending
        case started(workflowId: String)
        case invalid(StartWorkflowError)
        case failed(ControlPlaneModel.ActionFailure)
    }

    private let api: ControlAPIClient
    private let connection: ControlConnection

    private(set) var closedLoad: Load = .idle
    private(set) var closed: [WorkflowRun] = []

    /// By `WorkflowRun.identity`.
    private(set) var histories: [String: History] = [:]
    private(set) var cancelStates: [String: CancelState] = [:]

    private(set) var typesLoad: Load = .idle
    private(set) var types: [WorkflowType] = []
    private(set) var startState: StartState = .idle

    init(api: ControlAPIClient, connection: ControlConnection) {
        self.api = api
        self.connection = connection
    }

    /// Closed runs that did not finish: failed, timed out, terminated or cancelled.
    var stopped: [WorkflowRun] {
        closed.filter { $0.outcome != .completed }
    }

    /// Closed runs that finished.
    var finished: [WorkflowRun] {
        closed.filter { $0.outcome == .completed }
    }

    // MARK: - Closed runs

    func refreshClosed() async {
        if closedLoad == .idle {
            closedLoad = .loading
        }
        do {
            closed = try await api.closedRuns(connection, hours: Self.closedWindowHours)
            closedLoad = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            closedLoad = .failed(Self.failure(for: error))
        }
    }

    // MARK: - History

    func history(for run: WorkflowRun) -> History? {
        histories[run.identity]
    }

    /// Reads one run's history. A reload keeps the events already on screen until the new ones
    /// arrive, so a refresh never blanks the screen first.
    func loadHistory(for run: WorkflowRun) async {
        if histories[run.identity] == nil {
            histories[run.identity] = .loading
        }
        do {
            let events = try await api.runHistory(
                connection,
                namespace: run.namespace,
                workflowId: run.workflowId
            )
            histories[run.identity] = .loaded(events)
        } catch {
            guard !Task.isCancelled else { return }
            if case .loaded? = histories[run.identity] { return }
            histories[run.identity] = .failed
        }
    }

    // MARK: - Cancelling

    func cancelState(for run: WorkflowRun) -> CancelState? {
        cancelStates[run.identity]
    }

    /// Asks the orchestrator to cancel one run — that run, by its run identifier, so a workflow
    /// restarted under the same name is not cancelled by a screen showing the old one.
    @discardableResult
    func cancel(_ run: WorkflowRun) async -> Bool {
        guard cancelStates[run.identity] != .sending else { return false }

        cancelStates[run.identity] = .sending
        do {
            try await api.cancelRun(
                connection,
                namespace: run.namespace,
                workflowId: run.workflowId,
                runId: run.runId
            )
        } catch {
            cancelStates[run.identity] = .failed(ControlPlaneModel.ActionFailure.from(error))
            return false
        }
        cancelStates[run.identity] = .requested
        return true
    }

    // MARK: - Starting

    func loadTypes() async {
        if typesLoad == .idle {
            typesLoad = .loading
        }
        do {
            types = try await api.workflowTypes(connection).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            typesLoad = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            typesLoad = .failed(Self.failure(for: error))
        }
    }

    /// Starts a workflow from what was typed. Returns the new run's workflow identifier.
    @discardableResult
    func start(
        _ type: WorkflowType,
        text: [String: String],
        toggles: [String: Bool]
    ) async -> String? {
        guard startState != .sending else { return nil }

        let body: StartWorkflowBody
        do {
            body = try StartWorkflow.body(type: type, text: text, toggles: toggles)
        } catch let error as StartWorkflowError {
            startState = .invalid(error)
            return nil
        } catch {
            startState = .failed(.refused(nil))
            return nil
        }

        startState = .sending
        do {
            let workflowId = try await api.startWorkflow(connection, body: body)
            startState = .started(workflowId: workflowId)
            return workflowId
        } catch {
            startState = .failed(ControlPlaneModel.ActionFailure.from(error))
            return nil
        }
    }

    func resetStart() {
        if startState != .sending {
            startState = .idle
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

/// One agent's log, while its screen is open.
@MainActor
@Observable
final class AgentLogModel {

    enum State: Equatable, Sendable {
        case connecting
        case following
        /// The socket ended. What was received stays on screen.
        case ended
    }

    private let stream: AgentLogStream
    private let connection: ControlConnection
    let agentName: String

    private(set) var tail = LogTail()
    private(set) var state: State = .connecting

    private var follow: Task<Void, Never>?

    init(stream: AgentLogStream, connection: ControlConnection, agentName: String) {
        self.stream = stream
        self.connection = connection
        self.agentName = agentName
    }

    /// Starts following. Safe to call again while following.
    func start() {
        guard follow == nil else { return }
        state = .connecting
        follow = Task { [weak self] in
            guard let self else { return }
            for await event in self.stream.log(self.connection, agentName: self.agentName) {
                self.apply(event)
            }
        }
    }

    /// Stops following. There is no automatic reconnect: a log that silently resumed would
    /// show a gap as if it were continuous.
    func stop() {
        follow?.cancel()
        follow = nil
    }

    /// Clears what was received and follows again from the orchestrator's replay.
    func reload() {
        stop()
        tail.removeAll()
        start()
    }

    func apply(_ event: AgentLogEvent) {
        switch event {
        case .text(let frame):
            tail.append(frame)
            state = .following
        case .ended:
            state = .ended
            follow = nil
        }
    }
}
