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
        case registerPush(deviceId: String, token: String)
        case unregisterPush(deviceId: String)
        case registerDevice(enrollmentCode: String, deviceName: String?)
        case mintToken(deviceId: String, deviceSecret: String)
        case revokeDevice(deviceId: String)
        case chatAgents
    }

    private(set) var calls: [Call] = []
    private(set) var connections: [ControlConnection] = []

    var onAgents: (() async throws -> [FleetAgent])?
    var onRevoke: (() async throws -> Void)?
    var onMint: (() async throws -> MintTokenResponse)?

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
    var registerPushResult: Result<Void, Error> = .success(())
    var unregisterPushResult: Result<Void, Error> = .success(())
    var registerDeviceResult: Result<RegisteredDevice, Error> = .success(
        RegisteredDevice(deviceId: "device-1", deviceSecret: "secret-1")
    )
    /// One per mint, consumed in order; the last one repeats.
    var mintResults: [Result<MintTokenResponse, Error>] = [
        .success(MintTokenResponse(accessToken: "access-token-1", expiresInSeconds: 900))
    ]
    var revokeResult: Result<Void, Error> = .success(())
    var chatAgentsResult: Result<ChatAgentList, Error> = .success(
        ChatAgentList(available: true, agents: [])
    )

    /// Runs when a route that takes a token is called, with the token it was given, before the
    /// route's result is produced. Returning an error answers the call with it instead: lets a
    /// test refuse one token and accept the next, the way an orchestrator refuses an expired one.
    var onSignedRequest: ((String?) -> Error?)?

    /// Push registrations held open, by token, and push removals held open, by device, until a
    /// test lets them finish. Lets a test choose whether a call completes before or after
    /// something else the person does. Read from whichever thread runs the call, so guarded.
    private var heldRegistrations: Set<String> = []
    private var heldRemovals: Set<String> = []

    /// What the orchestrator would hold: the token each device's registration stored. A write is
    /// applied when its call is answered, so a test can see which of two writes landed last.
    private var registeredTokens: [String: String] = [:]

    /// The answer for a particular held registration, by token, given when the test releases it.
    /// Without one, a registration answers with `registerPushResult`.
    private var registrationAnswers: [String: Result<Void, Error>] = [:]

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

    /// The access token each recorded call carried, in order.
    var accessTokens: [String?] {
        lock.withLock { connections.map(\.accessToken) }
    }

    func mintCount() -> Int {
        lock.withLock {
            calls.filter { if case .mintToken = $0 { return true } else { return false } }.count
        }
    }

    private func refuseIfAsked(_ connection: ControlConnection) throws {
        if let error = onSignedRequest?(connection.accessToken) {
            throw error
        }
    }

    func registeredToken(of deviceId: String) -> String? {
        lock.withLock { registeredTokens[deviceId] }
    }

    func hold(registrationOf token: String) {
        lock.withLock { _ = heldRegistrations.insert(token) }
    }

    func release(registrationOf token: String, answering answer: Result<Void, Error>? = nil) {
        lock.withLock {
            if let answer { registrationAnswers[token] = answer }
            _ = heldRegistrations.remove(token)
        }
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
        record(.agents, connection)
        try refuseIfAsked(connection)
        if let onAgents { return try await onAgents() }
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


    func registerPushDevice(
        _ connection: ControlConnection,
        deviceId: String,
        token: String
    ) async throws {
        record(.registerPush(deviceId: deviceId, token: token), connection)
        await waitWhileHeld { heldRegistrations.contains(token) }
        try lock.withLock {
            try (registrationAnswers[token] ?? registerPushResult).get()
            registeredTokens[deviceId] = token
        }
    }

    func unregisterPushDevice(_ connection: ControlConnection, deviceId: String) async throws {
        record(.unregisterPush(deviceId: deviceId), connection)
        await waitWhileHeld { heldRemovals.contains(deviceId) }
        try lock.withLock {
            try unregisterPushResult.get()
            registeredTokens[deviceId] = nil
        }
    }

    func registerDevice(
        _ connection: ControlConnection,
        enrollmentCode: String,
        deviceName: String?
    ) async throws -> RegisteredDevice {
        record(.registerDevice(enrollmentCode: enrollmentCode, deviceName: deviceName), connection)
        return try registerDeviceResult.get()
    }

    func mintToken(
        _ connection: ControlConnection,
        deviceId: String,
        deviceSecret: String
    ) async throws -> MintTokenResponse {
        if let onMint {
            record(.mintToken(deviceId: deviceId, deviceSecret: deviceSecret), connection)
            return try await onMint()
        }
        return try lock.withLock {
            calls.append(.mintToken(deviceId: deviceId, deviceSecret: deviceSecret))
            connections.append(connection)
            guard let first = mintResults.first else {
                throw ControlAPIError.transport("no scripted mint")
            }
            if mintResults.count > 1 {
                mintResults.removeFirst()
            }
            return try first.get()
        }
    }

    func revokeDevice(_ connection: ControlConnection, deviceId: String) async throws {
        record(.revokeDevice(deviceId: deviceId), connection)
        try refuseIfAsked(connection)
        if let onRevoke { return try await onRevoke() }
        try revokeResult.get()
    }

    func chatAgents(_ connection: ControlConnection) async throws -> ChatAgentList {
        record(.chatAgents, connection)
        try refuseIfAsked(connection)
        return try chatAgentsResult.get()
    }
}

/// A scripted agent log. Each attach replays its script and ends.
final class FakeAgentLogStream: AgentLogStream {

    private(set) var agentNames: [String] = []
    private(set) var accessTokens: [String?] = []
    var script: [AgentLogEvent]

    init(script: [AgentLogEvent] = [.ended]) {
        self.script = script
    }

    func log(_ connection: ControlConnection, agentName: String) -> AsyncStream<AgentLogEvent> {
        agentNames.append(agentName)
        accessTokens.append(connection.accessToken)
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
    private(set) var accessTokens: [String?] = []

    /// One script per attach, consumed in order. The last one repeats.
    var scripts: [[ControlLiveEvent]]

    init(scripts: [[ControlLiveEvent]] = [[.ended]]) {
        self.scripts = scripts
    }

    func frames(_ connection: ControlConnection) -> AsyncStream<ControlLiveEvent> {
        let index = min(attachCount, scripts.count - 1)
        attachCount += 1
        accessTokens.append(connection.accessToken)
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
