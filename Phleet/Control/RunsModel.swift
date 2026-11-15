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

    /// How far back closed runs are read when nothing else was chosen. The orchestrator caps the
    /// list regardless.
    nonisolated static let closedWindowHours = 24

    /// The windows offered: the last day, and the three days the orchestrator reads at most.
    nonisolated static let windowChoices = [24, 72]

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

    enum RestartState: Equatable, Sendable {
        case sending
        /// A new run was started. The run that was restarted is unchanged.
        case restarted(workflowId: String)
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
    private(set) var terminateStates: [String: CancelState] = [:]
    private(set) var restartStates: [String: RestartState] = [:]

    /// How far back closed runs are read, in hours. One of `windowChoices`.
    private(set) var windowHours = RunsModel.closedWindowHours

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
            let hours = windowHours
            let read = try await api.closedRuns(connection, hours: hours)
            // A read for a window that has since been changed is not what the screen asks for.
            guard hours == windowHours else { return }
            closed = read
            closedLoad = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            closedLoad = .failed(Self.failure(for: error))
        }
    }

    /// Changes how far back closed runs are read, and reads again.
    func setWindow(hours: Int) async {
        guard Self.windowChoices.contains(hours), hours != windowHours else { return }
        windowHours = hours
        await refreshClosed()
    }

    // MARK: - History

    func history(for run: WorkflowRun) -> History? {
        histories[run.identity]
    }

    /// Reads one run's history. A reload keeps the events already on screen until the new ones
    /// arrive, so a refresh never blanks the screen first.
    ///
    /// Read by the run's own identifier: a complete value is read by event number from that run,
    /// and the latest run of the same workflow numbers its events differently.
    func loadHistory(for run: WorkflowRun) async {
        if histories[run.identity] == nil {
            histories[run.identity] = .loading
        }
        do {
            let events = try await api.runHistory(
                connection,
                namespace: run.namespace,
                workflowId: run.workflowId,
                runId: run.runId
            )
            histories[run.identity] = .loaded(events)
        } catch {
            guard !Task.isCancelled else { return }
            if case .loaded? = histories[run.identity] { return }
            histories[run.identity] = .failed
        }
    }

    /// The complete values of one event, for its screen. Held by that screen and gone with it:
    /// nothing read in full is kept here.
    func eventValues(of event: WorkflowEvent, in run: WorkflowRun) -> EventValuesModel {
        EventValuesModel(api: api, connection: connection, run: run, event: event)
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

    // MARK: - Terminating

    func terminateState(for run: WorkflowRun) -> CancelState? {
        terminateStates[run.identity]
    }

    /// Stops one run at once. Unlike a cancel, the workflow gets no chance to wind down, which is
    /// what a run that ignores a cancel needs.
    @discardableResult
    func terminate(_ run: WorkflowRun) async -> Bool {
        guard terminateStates[run.identity] != .sending else { return false }

        terminateStates[run.identity] = .sending
        do {
            try await api.terminateRun(
                connection,
                namespace: run.namespace,
                workflowId: run.workflowId,
                runId: run.runId
            )
        } catch {
            terminateStates[run.identity] = .failed(ControlPlaneModel.ActionFailure.from(error))
            return false
        }
        terminateStates[run.identity] = .requested
        return true
    }

    // MARK: - Restarting

    func restartState(for run: WorkflowRun) -> RestartState? {
        restartStates[run.identity]
    }

    /// Starts a new run of the same type with the input this run was started with.
    ///
    /// Offered for a run that has closed. The orchestrator reads the type and input from that
    /// run's own history, so the run is named by its run identifier.
    @discardableResult
    func restart(_ run: WorkflowRun) async -> RestartedRun? {
        guard restartStates[run.identity] != .sending else { return nil }

        restartStates[run.identity] = .sending
        do {
            let restarted = try await api.restartRun(
                connection,
                namespace: run.namespace,
                workflowId: run.workflowId,
                runId: run.runId
            )
            restartStates[run.identity] = .restarted(workflowId: restarted.newWorkflowId)
            return restarted
        } catch {
            restartStates[run.identity] = .failed(ControlPlaneModel.ActionFailure.from(error))
            return nil
        }
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
        ControlPlaneModel.Failure.from(error)
    }
}

/// One history event's complete values, while its screen is open.
///
/// Nothing is read until a person asks for a field, and each field is read on its own: the
/// history list never reads complete values, and opening this screen does not either.
@MainActor
@Observable
final class EventValuesModel {

    /// Why a read gave no answer to show.
    enum Failure: Equatable, Sendable {
        /// The server has no complete-value route: an orchestrator older than it.
        case notOffered
        /// The server found no such run or event, or does not know the namespace.
        case notFound
        /// The server could not read the run's history.
        case historyUnavailable
        /// Reading the history took longer than the server allows.
        case timedOut
        /// The answer did not decode, named another run or event, or contradicted itself.
        /// Nothing from it is shown.
        case unreadableAnswer
        case tokenRejected
        case accessDenied
        case unreachable
        /// Any other refusal, with the server's code when it gave one.
        case refused(String?)
    }

    enum State: Equatable, Sendable {
        case idle
        case loading
        case loaded(EventValueResult)
        case failed(Failure)
        /// Stopped before an answer arrived, by the person or by leaving the screen.
        case stopped
    }

    let run: WorkflowRun
    let event: WorkflowEvent

    private let api: ControlAPIClient
    private let connection: ControlConnection

    private(set) var states: [EventValueField: State] = [:]
    private var reads: [EventValueField: Task<Void, Never>] = [:]
    /// Which read an answer belongs to. A stopped read that answers anyway changes nothing.
    private var generations: [EventValueField: Int] = [:]

    init(api: ControlAPIClient, connection: ControlConnection, run: WorkflowRun, event: WorkflowEvent) {
        self.api = api
        self.connection = connection
        self.run = run
        self.event = event
    }

    /// The fields this kind of event has, in the order they are shown.
    var fields: [EventValueField] {
        EventValueRequest.fields(for: event)
    }

    func state(of field: EventValueField) -> State {
        states[field] ?? .idle
    }

    /// The exact read for one field: this run, this event. Never the latest run.
    func request(for field: EventValueField) -> EventValueRequest {
        EventValueRequest(run: run, event: event, field: field)
    }

    /// Reads one field in full. Asking again while it is being read does nothing.
    func load(_ field: EventValueField) {
        guard fields.contains(field), state(of: field) != .loading else { return }
        let generation = (generations[field] ?? 0) + 1
        generations[field] = generation
        states[field] = .loading

        let request = request(for: field)
        reads[field] = Task { [weak self] in
            guard let self else { return }
            let outcome: State
            do {
                outcome = .loaded(try await self.api.eventValue(self.connection, request: request))
            } catch {
                outcome = Task.isCancelled ? .stopped : .failed(Self.failure(for: error))
            }
            guard self.generations[field] == generation else { return }
            self.states[field] = outcome
            self.reads[field] = nil
        }
    }

    /// Stops one read. The request is cancelled, and an answer that arrives anyway is dropped.
    func stop(_ field: EventValueField) {
        generations[field, default: 0] += 1
        reads[field]?.cancel()
        reads[field] = nil
        if state(of: field) == .loading {
            states[field] = .stopped
        }
    }

    /// Stops every read in flight, as the screen goes away.
    func stopAll() {
        for field in Array(reads.keys) {
            stop(field)
        }
    }

    /// Waits for the read in flight on one field, if there is one.
    func settle(_ field: EventValueField) async {
        await reads[field]?.value
    }

    nonisolated static func failure(for error: Error) -> Failure {
        if error is EventValueAnswerError {
            return .unreadableAnswer
        }
        switch error as? ControlAPIError {
        case .unauthorized?:
            return .tokenRejected
        case .accessDenied?:
            return .accessDenied
        case .transport?:
            return .unreachable
        case .decoding?:
            return .unreadableAnswer
        case .refused(404, let code)?:
            // The route answers a missing run or event with its own code. A 404 without it is
            // a server that has no such route at all.
            return code == "not_found" ? .notFound : .notOffered
        case .refused(405, _)?:
            return .notOffered
        case .refused(503, "history_timeout"?)?:
            return .timedOut
        case .refused(503, "history_unavailable"?)?:
            return .historyUnavailable
        case .refused(_, let code)?:
            return .refused(code)
        case .gateChanged(let code)?:
            return .refused(code)
        case nil:
            return .unreachable
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
