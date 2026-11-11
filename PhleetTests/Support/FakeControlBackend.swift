import Foundation
@testable import Phleet

/// A scripted orchestrator.
///
/// Records every call in order and answers from values a test sets. Nothing here opens a socket.
final class FakeControlAPI: ControlAPIClient {

    enum Call: Equatable {
        case agents
        case workflows
        case signalRegistry
        case sendSignal(namespace: String, workflowId: String, body: SignalRequestBody)
        case agentAction(agentName: String, action: AgentAction)
        case closedRuns(hours: Int)
        case runHistory(namespace: String, workflowId: String)
        case cancelRun(namespace: String, workflowId: String, runId: String)
        case workflowTypes
        case startWorkflow(StartWorkflowBody)
        case checkOperatorToken
        case registerPush(deviceId: String, token: String)
        case unregisterPush(deviceId: String)
    }

    private(set) var calls: [Call] = []
    private(set) var connections: [ControlConnection] = []

    var agentsResult: Result<[FleetAgent], Error> = .success([])
    var workflowsResult: Result<[WorkflowRun], Error> = .success([])
    var registryResult: Result<[String: [SignalDefinition]], Error> = .success([:])
    var signalResult: Result<Void, Error> = .success(())
    var agentActionResult: Result<Void, Error> = .success(())
    var closedResult: Result<[WorkflowRun], Error> = .success([])
    var historyResult: Result<[WorkflowEvent], Error> = .success([])
    var cancelResult: Result<Void, Error> = .success(())
    var typesResult: Result<[WorkflowType], Error> = .success([])
    var startResult: Result<String, Error> = .success("started-1")
    var tokenCheckResult: Result<OperatorTokenCheck, Error> = .success(.accepted)
    var registerPushResult: Result<Void, Error> = .success(())
    var unregisterPushResult: Result<Void, Error> = .success(())

    /// Push registrations held open, by token, and push removals held open, by device, until a
    /// test lets them finish. Lets a test choose whether a call completes before or after
    /// something else the person does. Read from whichever thread runs the call, so guarded.
    private var heldRegistrations: Set<String> = []
    private var heldRemovals: Set<String> = []

    /// Guards what a held push call shares with the test: the recorded calls, the held sets and
    /// the answers. The route methods are `nonisolated async`, so a held call waits on another
    /// thread while the test, and the next call, carry on.
    private let lock = NSLock()

    /// Runs when an agent action is sent, before its result is produced.
    var onAgentAction: (() -> Void)?

    /// Runs when a signal is sent, before its result is produced. Lets a test change what the
    /// next read returns, the way a real decision moves a workflow out of its phase.
    var onSendSignal: (() -> Void)?

    var sentSignals: [SignalRequestBody] {
        calls.compactMap {
            if case .sendSignal(_, _, let body) = $0 { return body }
            return nil
        }
    }

    func count(of call: Call) -> Int {
        lock.withLock { calls.filter { $0 == call }.count }
    }

    func record(_ call: Call, _ connection: ControlConnection) {
        lock.withLock {
            calls.append(call)
            connections.append(connection)
        }
    }

    func hold(registrationOf token: String) {
        lock.withLock { _ = heldRegistrations.insert(token) }
    }

    func release(registrationOf token: String) {
        lock.withLock { _ = heldRegistrations.remove(token) }
    }

    func hold(removalOf deviceId: String) {
        lock.withLock { _ = heldRemovals.insert(deviceId) }
    }

    func release(removalOf deviceId: String) {
        lock.withLock { _ = heldRemovals.remove(deviceId) }
    }

    /// Waits while `isHeld` says so, within the same bound as the other doubles' gates, so a hold
    /// that is never released fails the test instead of hanging the suite.
    private func waitWhileHeld(_ isHeld: () -> Bool) async {
        var yields = 0
        while lock.withLock(isHeld), yields < FakeFleetAPI.maxGateYields {
            await Task.yield()
            yields += 1
        }
    }

    func agents(_ connection: ControlConnection) async throws -> [FleetAgent] {
        calls.append(.agents)
        connections.append(connection)
        return try agentsResult.get()
    }

    func workflows(_ connection: ControlConnection) async throws -> [WorkflowRun] {
        calls.append(.workflows)
        connections.append(connection)
        return try workflowsResult.get()
    }

    func signalRegistry(
        _ connection: ControlConnection
    ) async throws -> [String: [SignalDefinition]] {
        calls.append(.signalRegistry)
        connections.append(connection)
        return try registryResult.get()
    }

    func sendSignal(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        body: SignalRequestBody
    ) async throws {
        calls.append(.sendSignal(namespace: namespace, workflowId: workflowId, body: body))
        connections.append(connection)
        onSendSignal?()
        try signalResult.get()
    }
}

extension FakeControlAPI {

    func performAgentAction(
        _ connection: ControlConnection,
        agentName: String,
        action: AgentAction
    ) async throws {
        record(.agentAction(agentName: agentName, action: action), connection)
        onAgentAction?()
        try agentActionResult.get()
    }

    func closedRuns(_ connection: ControlConnection, hours: Int) async throws -> [WorkflowRun] {
        record(.closedRuns(hours: hours), connection)
        return try closedResult.get()
    }

    func runHistory(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String
    ) async throws -> [WorkflowEvent] {
        record(.runHistory(namespace: namespace, workflowId: workflowId), connection)
        return try historyResult.get()
    }

    func cancelRun(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        runId: String
    ) async throws {
        record(.cancelRun(namespace: namespace, workflowId: workflowId, runId: runId), connection)
        try cancelResult.get()
    }

    func workflowTypes(_ connection: ControlConnection) async throws -> [WorkflowType] {
        record(.workflowTypes, connection)
        return try typesResult.get()
    }

    func startWorkflow(
        _ connection: ControlConnection,
        body: StartWorkflowBody
    ) async throws -> String {
        record(.startWorkflow(body), connection)
        return try startResult.get()
    }

    func checkOperatorToken(_ connection: ControlConnection) async throws -> OperatorTokenCheck {
        record(.checkOperatorToken, connection)
        return try tokenCheckResult.get()
    }

    func registerPushDevice(
        _ connection: ControlConnection,
        deviceId: String,
        token: String
    ) async throws {
        record(.registerPush(deviceId: deviceId, token: token), connection)
        await waitWhileHeld { heldRegistrations.contains(token) }
        try lock.withLock { try registerPushResult.get() }
    }

    func unregisterPushDevice(_ connection: ControlConnection, deviceId: String) async throws {
        record(.unregisterPush(deviceId: deviceId), connection)
        await waitWhileHeld { heldRemovals.contains(deviceId) }
        try lock.withLock { try unregisterPushResult.get() }
    }
}

/// A scripted agent log. Each attach replays its script and ends.
final class FakeAgentLogStream: AgentLogStream {

    private(set) var agentNames: [String] = []
    var script: [AgentLogEvent]

    init(script: [AgentLogEvent] = [.ended]) {
        self.script = script
    }

    func log(_ connection: ControlConnection, agentName: String) -> AsyncStream<AgentLogEvent> {
        agentNames.append(agentName)
        let script = self.script
        return AsyncStream { continuation in
            for event in script {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

/// A scripted live socket. Each attach replays its script and ends.
final class FakeControlLiveStream: ControlLiveStream {

    private(set) var attachCount = 0

    /// One script per attach, consumed in order. The last one repeats.
    var scripts: [[ControlLiveEvent]]

    init(scripts: [[ControlLiveEvent]] = [[.ended]]) {
        self.scripts = scripts
    }

    func frames(_ connection: ControlConnection) -> AsyncStream<ControlLiveEvent> {
        let index = min(attachCount, scripts.count - 1)
        attachCount += 1
        let script = scripts.isEmpty ? [.ended] : scripts[max(index, 0)]

        return AsyncStream { continuation in
            for event in script {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

/// A scripted notification system. Records what was asked of it; a test delivers the token.
@MainActor
final class FakePushSystem: PushSystem {

    var onDeviceToken: ((String) -> Void)?
    var onRegistrationFailed: (() -> Void)?
    var onOpened: ((PushDestination) -> Void)?

    var permission: PushPermission = .granted
    private(set) var permissionRequests = 0
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    func requestPermission() async -> PushPermission {
        permissionRequests += 1
        return permission
    }

    func registerForRemoteNotifications() { registerCalls += 1 }
    func unregisterForRemoteNotifications() { unregisterCalls += 1 }
}
