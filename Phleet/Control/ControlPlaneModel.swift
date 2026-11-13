import Foundation
import Observation

/// The fleet at a glance: who is up, what is waiting for a person, and the answer to give.
///
/// Two sources feed it. HTTPS reads are the source of truth and run on a timer; the live socket
/// only makes changes arrive sooner. That order is deliberate: the socket has to pass whatever
/// proxy sits in front of the orchestrator, and a control plane that goes blank when it does not
/// would be worse than one that is thirty seconds behind.
@MainActor
@Observable
final class ControlPlaneModel {

    /// How often the HTTPS reads repeat while the screen is in use.
    nonisolated static let refreshIntervalSeconds: Double = 30

    /// Why the fleet could not be read.
    enum Failure: Equatable, Sendable {
        /// The proxy in front of the orchestrator refused this device.
        case accessDenied
        /// Nothing answered.
        case unreachable
        /// Something answered, and it was not an orchestrator.
        case unexpectedAnswer
    }

    enum Status: Equatable, Sendable {
        /// Nothing has been read yet.
        case loading
        /// The last read succeeded. `isLive` says whether the socket is delivering as well.
        case current(isLive: Bool)
        /// The last read failed. Whatever was read before stays on screen.
        case failed(Failure)
    }

    /// Why a decision did not land.
    enum DecisionFailure: Equatable, Sendable {
        /// The orchestrator refused this phone's sign-in, even with a freshly minted token.
        case tokenRejected
        case accessDenied
        /// The gate is no longer the one that was on screen. Nothing was sent to the workflow.
        case gateChanged
        /// The button needs a comment.
        case commentRequired
        /// The request did not complete. It may or may not have reached the workflow, which is
        /// why this is not offered as a plain retry.
        case outcomeUnknown
        /// The orchestrator said no, in its own words when it gave any.
        case refused(String?)
    }

    enum DecisionState: Equatable, Sendable {
        case sending
        case failed(DecisionFailure)
    }

    /// Why something other than a gate decision did not land: an agent action, a cancelled run,
    /// a started workflow.
    enum ActionFailure: Equatable, Sendable {
        /// The orchestrator refused this phone's sign-in, even with a freshly minted token.
        case tokenRejected
        case accessDenied
        /// The request did not complete, so it may or may not have taken effect.
        case outcomeUnknown
        case refused(String?)

        static func from(_ error: Error) -> ActionFailure {
            switch error as? ControlAPIError {
            case .unauthorized?:
                return .tokenRejected
            case .accessDenied?:
                return .accessDenied
            case .gateChanged(let message)?:
                return .refused(message)
            case .refused(_, let message)?:
                return .refused(message)
            case .transport?, .decoding?, nil:
                return .outcomeUnknown
            }
        }
    }

    enum AgentActionState: Equatable, Sendable {
        case sending(AgentAction)
        /// The orchestrator accepted the request. The agent's state follows on a later read.
        case requested(AgentAction)
        case failed(AgentAction, ActionFailure)
    }

    // MARK: - Dependencies

    private let api: ControlAPIClient
    private let stream: ControlLiveStream
    private let connection: ControlConnection
    private let sleep: (Double) async -> Void
    private let now: () -> Date
    private let randomFraction: () -> Double

    // MARK: - Observable state

    private(set) var status: Status = .loading
    private(set) var lastUpdated: Date?

    private var agentsByName: [String: FleetAgent] = [:]
    private(set) var runs: [WorkflowRun] = []
    private(set) var registry: [String: [SignalDefinition]] = [:]

    /// Gates this device has answered and the orchestrator still lists.
    ///
    /// A workflow takes a moment to leave the phase it was waiting in. Without this the gate
    /// would sit on the list after its answer was accepted, inviting a second one.
    private(set) var answeredGateIds: Set<String> = []

    private(set) var decisionStates: [String: DecisionState] = [:]

    /// The last action sent to each agent, by agent name.
    private(set) var agentActionStates: [String: AgentActionState] = [:]

    private var refreshLoop: Task<Void, Never>?
    private var liveLoop: Task<Void, Never>?
    private var isLive = false

    init(
        api: ControlAPIClient,
        stream: ControlLiveStream,
        connection: ControlConnection,
        sleep: @escaping (Double) async -> Void = ControlPlaneModel.defaultSleep,
        now: @escaping () -> Date = Date.init,
        randomFraction: @escaping () -> Double = { Double.random(in: 0...1) }
    ) {
        self.api = api
        self.stream = stream
        self.connection = connection
        self.sleep = sleep
        self.now = now
        self.randomFraction = randomFraction
    }

    nonisolated static func defaultSleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }

    // MARK: - Derived

    /// Runs that are in progress, oldest first.
    var runningRuns: [WorkflowRun] {
        runs.filter(\.isRunning).sorted {
            ($0.startTime ?? .distantFuture, $0.identity) < ($1.startTime ?? .distantFuture, $1.identity)
        }
    }

    /// Every agent, the ones needing attention first.
    var agents: [FleetAgent] {
        agentsByName.values.sorted(by: FleetAgent.glanceOrder)
    }

    func agent(named name: String) -> FleetAgent? {
        agentsByName[name]
    }

    /// The runs waiting for a person that this device has not already answered.
    var gates: [PendingGate] {
        PendingGates.derive(runs: runs, registry: registry)
            .filter { !answeredGateIds.contains($0.id) }
    }

    /// Whether a gate that was on screen is still waiting.
    func isWaiting(_ gate: PendingGate) -> Bool {
        gates.contains { $0.id == gate.id }
    }

    func decisionState(for gate: PendingGate) -> DecisionState? {
        decisionStates[gate.id]
    }

    // MARK: - Lifecycle

    /// Starts reading. Safe to call again while running.
    func start() {
        if refreshLoop == nil {
            refreshLoop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.refresh()
                    await self.sleep(Self.refreshIntervalSeconds)
                }
            }
        }
        if liveLoop == nil {
            liveLoop = Task { [weak self] in
                await self?.runLiveLoop()
            }
        }
    }

    /// Stops reading. What was read stays on screen.
    func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
        liveLoop?.cancel()
        liveLoop = nil
        setLive(false)
    }

    // MARK: - Reading

    /// Reads agents, runs and the signal registry once.
    ///
    /// Agents are **replaced**, not merged: an agent the orchestrator no longer lists is gone,
    /// and merging would keep it on screen forever.
    func refresh() async {
        do {
            let registry = try await api.signalRegistry(connection)
            let agents = try await api.agents(connection)
            let runs = try await api.workflows(connection)

            self.registry = registry
            self.agentsByName = Dictionary(
                agents.map { ($0.agentName, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            applyRuns(runs)
            lastUpdated = now()
            status = .current(isLive: isLive)
        } catch {
            // A read interrupted by `stop()` says nothing about the orchestrator, and must not
            // leave "unreachable" on screen for a fleet that was merely backgrounded.
            guard !Task.isCancelled else { return }
            status = .failed(Self.failure(for: error))
        }
    }

    /// Applies one live event.
    func apply(_ event: ControlLiveEvent) {
        switch event {
        case .frame(.agent(let agent)):
            agentsByName[agent.agentName] = agent
            setLive(true)
        case .frame(.workflows(let runs)):
            applyRuns(runs)
            setLive(true)
        case .undecodableFrame:
            break
        case .ended:
            setLive(false)
        }
    }

    private func applyRuns(_ runs: [WorkflowRun]) {
        self.runs = runs

        // An answered gate is forgotten once the orchestrator stops listing it — which also
        // bounds the set — and its failure state goes with it.
        let listed = Set(PendingGates.derive(runs: runs, registry: registry).map(\.id))
        answeredGateIds.formIntersection(listed)
        decisionStates = decisionStates.filter { listed.contains($0.key) }
    }

    private func setLive(_ live: Bool) {
        isLive = live
        if case .current = status {
            status = .current(isLive: live)
        }
    }

    private func runLiveLoop() async {
        var policy = ReconnectPolicy()
        while !Task.isCancelled {
            let openedAt = now()
            for await event in stream.frames(connection) {
                apply(event)
            }
            if Task.isCancelled { return }

            setLive(false)
            policy.recordConnectionEnded(connectedForSeconds: now().timeIntervalSince(openedAt))
            guard let delay = policy.nextDelay(randomFraction: randomFraction()) else { return }
            await sleep(delay)
        }
    }

    private static func failure(for error: Error) -> Failure {
        switch error as? ControlAPIError {
        case .accessDenied?:
            return .accessDenied
        case .transport?:
            return .unreachable
        case .decoding?, .unauthorized?, .gateChanged?, .refused?, nil:
            return .unexpectedAnswer
        }
    }

    // MARK: - Deciding

    /// Sends one answer to one gate.
    ///
    /// The request is built from the gate **as it was shown**. If the run has moved on, the
    /// orchestrator answers `409` and nothing reaches the workflow.
    @discardableResult
    func decide(gate: PendingGate, button: SignalButton, comment: String) async -> Bool {
        guard decisionStates[gate.id] != .sending else { return false }

        let body: SignalRequestBody
        do {
            body = try SignalRequest.body(gate: gate, button: button, comment: comment)
        } catch SignalRequestError.commentRequired {
            decisionStates[gate.id] = .failed(.commentRequired)
            return false
        } catch {
            decisionStates[gate.id] = .failed(.refused(nil))
            return false
        }

        decisionStates[gate.id] = .sending
        do {
            try await api.sendSignal(
                connection,
                namespace: gate.run.namespace,
                workflowId: gate.run.workflowId,
                body: body
            )
        } catch {
            let failure = Self.decisionFailure(for: error)
            decisionStates[gate.id] = .failed(failure)
            if failure == .gateChanged || failure == .outcomeUnknown {
                // Either the screen was stale or the outcome is unknown. Both are settled by
                // reading again, and reading drops the state above if the gate has gone.
                await refresh()
            }
            return false
        }

        decisionStates[gate.id] = nil
        answeredGateIds.insert(gate.id)
        return true
    }

    func clearDecisionFailure(for gate: PendingGate) {
        if case .failed? = decisionStates[gate.id] {
            decisionStates[gate.id] = nil
        }
    }

    // MARK: - Agent actions

    func agentActionState(for agentName: String) -> AgentActionState? {
        agentActionStates[agentName]
    }

    /// Sends one action to one agent.
    ///
    /// "Accepted" means the orchestrator took the request, not that the agent has changed: a
    /// restart takes a while to show. The fleet is read again straight away, and the agent's
    /// own state is what says whether it worked.
    @discardableResult
    func perform(_ action: AgentAction, on agentName: String) async -> Bool {
        if case .sending? = agentActionStates[agentName] { return false }

        agentActionStates[agentName] = .sending(action)
        do {
            try await api.performAgentAction(connection, agentName: agentName, action: action)
        } catch {
            let failure = ActionFailure.from(error)
            agentActionStates[agentName] = .failed(action, failure)
            if failure == .outcomeUnknown {
                await refresh()
            }
            return false
        }

        agentActionStates[agentName] = .requested(action)
        await refresh()
        return true
    }

    func clearAgentActionState(for agentName: String) {
        if case .sending? = agentActionStates[agentName] { return }
        agentActionStates[agentName] = nil
    }

    private static func decisionFailure(for error: Error) -> DecisionFailure {
        switch error as? ControlAPIError {
        case .unauthorized?:
            return .tokenRejected
        case .accessDenied?:
            return .accessDenied
        case .gateChanged?:
            return .gateChanged
        case .refused(_, let message)?:
            return .refused(message)
        case .transport?, .decoding?, nil:
            return .outcomeUnknown
        }
    }
}
