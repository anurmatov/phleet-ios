import Foundation

/// The orchestrator's routes, signed in as this phone.
///
/// Every request goes out with a current access token, reads included: through the dashboard's
/// address the orchestrator answers nothing without one. The models above this hold a connection
/// with no token in it and never see one.
///
/// A `401` means the token is no longer good — it expired early, or the orchestrator restarted
/// and forgot it — so a fresh one is minted and the request sent once more. A second `401` is
/// that request's own failure and is reported as such. Whether this phone is still signed in at
/// all is decided by the mint alone: `AccessTokenHolder` is where a refused device credential
/// ends the sign-in, and the only place.
final class SignedInControlAPI: ControlAPIClient {

    private let base: ControlAPIClient
    private let tokens: AccessTokenHolder

    init(base: ControlAPIClient, tokens: AccessTokenHolder) {
        self.base = base
        self.tokens = tokens
    }

    /// Runs `operation` with a current token, and once more with a fresh one after a `401`.
    private func signedIn<Value>(
        _ connection: ControlConnection,
        _ operation: (ControlConnection) async throws -> Value
    ) async throws -> Value {
        let first = try await bearer()
        do {
            return try await operation(connection.bearing(first))
        } catch ControlAPIError.unauthorized {
            await tokens.invalidateToken()
            let fresh = try await bearer()
            return try await operation(connection.bearing(fresh))
        }
    }

    /// A current token. A device credential the orchestrator refused, or none at all, reads to
    /// the models as the request being refused: the sign-in itself is being torn down above them.
    private func bearer() async throws -> String {
        do {
            return try await tokens.accessToken()
        } catch is AccessTokenHolder.Failure {
            throw ControlAPIError.unauthorized
        }
    }

    // MARK: - ControlAPIClient

    func agents(_ connection: ControlConnection) async throws -> [FleetAgent] {
        try await signedIn(connection) { try await base.agents($0) }
    }

    func workflows(_ connection: ControlConnection) async throws -> [WorkflowRun] {
        try await signedIn(connection) { try await base.workflows($0) }
    }

    func signalRegistry(
        _ connection: ControlConnection
    ) async throws -> [String: [SignalDefinition]] {
        try await signedIn(connection) { try await base.signalRegistry($0) }
    }

    func sendSignal(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        body: SignalRequestBody
    ) async throws {
        try await signedIn(connection) {
            try await base.sendSignal($0, namespace: namespace, workflowId: workflowId, body: body)
        }
    }

    func performAgentAction(
        _ connection: ControlConnection,
        agentName: String,
        action: AgentAction
    ) async throws {
        try await signedIn(connection) {
            try await base.performAgentAction($0, agentName: agentName, action: action)
        }
    }

    func closedRuns(_ connection: ControlConnection, hours: Int) async throws -> [WorkflowRun] {
        try await signedIn(connection) { try await base.closedRuns($0, hours: hours) }
    }

    func runHistory(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String
    ) async throws -> [WorkflowEvent] {
        try await signedIn(connection) {
            try await base.runHistory($0, namespace: namespace, workflowId: workflowId)
        }
    }

    func cancelRun(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        runId: String
    ) async throws {
        try await signedIn(connection) {
            try await base.cancelRun(
                $0,
                namespace: namespace,
                workflowId: workflowId,
                runId: runId
            )
        }
    }

    func workflowTypes(_ connection: ControlConnection) async throws -> [WorkflowType] {
        try await signedIn(connection) { try await base.workflowTypes($0) }
    }

    func startWorkflow(
        _ connection: ControlConnection,
        body: StartWorkflowBody
    ) async throws -> String {
        try await signedIn(connection) { try await base.startWorkflow($0, body: body) }
    }

    func registerPushDevice(
        _ connection: ControlConnection,
        deviceId: String,
        token: String
    ) async throws {
        try await signedIn(connection) {
            try await base.registerPushDevice($0, deviceId: deviceId, token: token)
        }
    }

    func unregisterPushDevice(_ connection: ControlConnection, deviceId: String) async throws {
        try await signedIn(connection) {
            try await base.unregisterPushDevice($0, deviceId: deviceId)
        }
    }

    /// Passed through untouched: it is how a device is obtained, and carries no token.
    func registerDevice(
        _ connection: ControlConnection,
        enrollmentCode: String,
        deviceName: String?
    ) async throws -> RegisteredDevice {
        try await base.registerDevice(
            connection,
            enrollmentCode: enrollmentCode,
            deviceName: deviceName
        )
    }

    /// Passed through untouched: it is how a token is obtained, and carries none.
    func mintToken(
        _ connection: ControlConnection,
        deviceId: String,
        deviceSecret: String
    ) async throws -> MintTokenResponse {
        try await base.mintToken(connection, deviceId: deviceId, deviceSecret: deviceSecret)
    }

    func revokeDevice(_ connection: ControlConnection, deviceId: String) async throws {
        try await signedIn(connection) { try await base.revokeDevice($0, deviceId: deviceId) }
    }

    func chatAgents(_ connection: ControlConnection) async throws -> ChatAgentList {
        try await signedIn(connection) { try await base.chatAgents($0) }
    }
}

/// The orchestrator's live socket, signed in as this phone.
///
/// A socket is opened with the token current at that moment; the orchestrator does not ask again
/// while it stays open. When one ends, the model above opens the next, which takes the token
/// current then.
@MainActor
final class SignedInControlLiveStream: ControlLiveStream {

    private let base: ControlLiveStream
    private let tokens: AccessTokenHolder

    init(base: ControlLiveStream, tokens: AccessTokenHolder) {
        self.base = base
        self.tokens = tokens
    }

    nonisolated func frames(_ connection: ControlConnection) -> AsyncStream<ControlLiveEvent> {
        AsyncStream { continuation in
            let relay = Task { @MainActor in
                await self.relay(connection, into: continuation)
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }

    private func relay(
        _ connection: ControlConnection,
        into continuation: AsyncStream<ControlLiveEvent>.Continuation
    ) async {
        guard let token = try? await tokens.accessToken() else {
            continuation.yield(.ended)
            continuation.finish()
            return
        }
        for await event in base.frames(connection.bearing(token)) {
            continuation.yield(event)
        }
        continuation.finish()
    }
}

/// One agent's log socket, signed in as this phone.
@MainActor
final class SignedInAgentLogStream: AgentLogStream {

    private let base: AgentLogStream
    private let tokens: AccessTokenHolder

    init(base: AgentLogStream, tokens: AccessTokenHolder) {
        self.base = base
        self.tokens = tokens
    }

    nonisolated func log(
        _ connection: ControlConnection,
        agentName: String
    ) -> AsyncStream<AgentLogEvent> {
        AsyncStream { continuation in
            let relay = Task { @MainActor in
                await self.relay(connection, agentName: agentName, into: continuation)
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }

    private func relay(
        _ connection: ControlConnection,
        agentName: String,
        into continuation: AsyncStream<AgentLogEvent>.Continuation
    ) async {
        guard let token = try? await tokens.accessToken() else {
            continuation.yield(.ended)
            continuation.finish()
            return
        }
        for await event in base.log(connection.bearing(token), agentName: agentName) {
            continuation.yield(event)
        }
        continuation.finish()
    }
}
