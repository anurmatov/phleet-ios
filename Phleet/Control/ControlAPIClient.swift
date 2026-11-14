import Foundation

/// Why a control-plane call failed.
enum ControlAPIError: Error, Equatable, Sendable {
    /// Whatever sits in front of the orchestrator turned the request away: a redirect to a
    /// sign-in page, or a `403`. The orchestrator itself never saw it.
    case accessDenied
    /// `401`: the orchestrator refused this phone's sign-in.
    case unauthorized
    /// `409`: the run or its gate is no longer what was on screen. Carries the server's code.
    case gateChanged(String?)
    /// Any other refusal the server named.
    case refused(status: Int, message: String?)
    /// The request never completed.
    case transport(String)
    /// The response completed and was not what an orchestrator answers with.
    case decoding(String)
}

/// The orchestrator routes the control plane uses.
///
/// Everything a request needs arrives as a parameter, as on `FleetAPIClient`: setup probes an
/// address before any credential is stored.
protocol ControlAPIClient {

    /// `GET /api/agents`
    func agents(_ connection: ControlConnection) async throws -> [FleetAgent]

    /// `GET /api/workflows`
    func workflows(_ connection: ControlConnection) async throws -> [WorkflowRun]

    /// `GET /api/signals` — workflow type to the signals it accepts.
    func signalRegistry(
        _ connection: ControlConnection
    ) async throws -> [String: [SignalDefinition]]

    /// `POST /api/workflows/{namespace}/signal/{workflowId}`
    func sendSignal(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        body: SignalRequestBody
    ) async throws

    /// `POST /api/agents/{name}/{start|stop|restart|cancel}`
    func performAgentAction(
        _ connection: ControlConnection,
        agentName: String,
        action: AgentAction
    ) async throws

    /// `GET /api/workflows/completed?hours=` — runs that closed in the window, **however** they
    /// closed: the route's name notwithstanding, it lists failed, cancelled and terminated runs
    /// too, newest first, capped by the orchestrator.
    func closedRuns(_ connection: ControlConnection, hours: Int) async throws -> [WorkflowRun]

    /// `GET /api/workflows/{namespace}/history/{workflowId}`
    func runHistory(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String
    ) async throws -> [WorkflowEvent]

    /// Original input for an exact run. Never falls back to latest-run history.
    func exactRunHistory(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        runId: String
    ) async throws -> [WorkflowEvent]

    /// `POST /api/workflows/{namespace}/cancel/{workflowId}?runId=`
    func cancelRun(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        runId: String
    ) async throws

    /// `POST /api/workflows/{namespace}/terminate/{workflowId}?runId=` — stops the run at once,
    /// without giving the workflow a chance to wind down.
    func terminateRun(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        runId: String
    ) async throws

    /// `POST /api/workflows/{namespace}/restart/{workflowId}?runId=` — starts a new run of the
    /// same type with the input that run was started with.
    func restartRun(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        runId: String
    ) async throws -> RestartedRun

    /// `GET /api/schedules`
    func schedules(_ connection: ControlConnection) async throws -> [FleetSchedule]

    /// `POST /api/schedules/{namespace}/{pause|unpause|trigger}/{scheduleId}`
    func performScheduleAction(
        _ connection: ControlConnection,
        namespace: String,
        scheduleId: String,
        action: ScheduleAction
    ) async throws

    /// `GET /api/memory/search?q=`
    func searchMemory(
        _ connection: ControlConnection,
        query: String
    ) async throws -> [MemorySearchResult]

    /// `GET /api/memory/{id}`
    func memory(_ connection: ControlConnection, id: String) async throws -> MemoryDocument

    /// `GET /api/workflow-types`
    func workflowTypes(_ connection: ControlConnection) async throws -> [WorkflowType]

    /// `POST /api/workflows/start`. Returns the identifier of the run that was started.
    func startWorkflow(
        _ connection: ControlConnection,
        body: StartWorkflowBody
    ) async throws -> String

    /// `PUT /api/push/devices/{deviceId}` — tell the orchestrator where to send this install's
    /// notifications.
    func registerPushDevice(
        _ connection: ControlConnection,
        deviceId: String,
        token: String
    ) async throws

    /// `DELETE /api/push/devices/{deviceId}`
    func unregisterPushDevice(_ connection: ControlConnection, deviceId: String) async throws

    // MARK: - Signing in

    /// `POST /api/auth/devices` — registers this phone with a one-time enrollment code. Sent
    /// with no access token: it is how a device is obtained.
    func registerDevice(
        _ connection: ControlConnection,
        enrollmentCode: String,
        deviceName: String?
    ) async throws -> RegisteredDevice

    /// `POST /api/auth/token` — a fifteen-minute access token for this phone. Sent with no access
    /// token: it is how one is obtained.
    func mintToken(
        _ connection: ControlConnection,
        deviceId: String,
        deviceSecret: String
    ) async throws -> MintTokenResponse

    /// `POST /api/auth/devices/{deviceId}/revoke` — this phone signing itself out.
    func revokeDevice(_ connection: ControlConnection, deviceId: String) async throws

    // MARK: - Chat

    /// `GET /api/chat/agents` — the agents a person can chat with.
    func chatAgents(_ connection: ControlConnection) async throws -> ChatAgentList
}

/// What registering a device returned. The secret is stored in the Keychain and nowhere else.
struct RegisteredDevice: Equatable, Sendable, Decodable {
    let deviceId: String
    let deviceSecret: String
}

/// How control-plane requests are put on the wire.
///
/// Static and reachable from the tests on purpose. The properties worth asserting — the access
/// token rides in a header on every signed-in request, reads included, and neither it nor the
/// service token ever appears in a URL — are properties of these functions, and asserting them
/// on a double that is merely handed the values would prove nothing.
enum ControlRequest {

    static let accessClientIdHeader = "CF-Access-Client-Id"
    static let accessClientSecretHeader = "CF-Access-Client-Secret"

    /// Builds a request.
    ///
    /// - The service token goes on **every** request: the proxy in front authenticates reads too.
    /// - The access token goes on every request that has one, reads included: through the
    ///   dashboard's address the orchestrator answers nothing without a sign-in. Only the routes
    ///   that obtain a token are built without one.
    static func make(
        connection: ControlConnection,
        method: String,
        percentEncodedPath: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) throws -> URLRequest {
        var request = URLRequest(
            url: try url(
                origin: connection.origin,
                percentEncodedPath: percentEncodedPath,
                query: query
            )
        )
        request.httpMethod = method

        if let serviceToken = connection.serviceToken {
            request.setValue(serviceToken.clientId, forHTTPHeaderField: accessClientIdHeader)
            request.setValue(
                serviceToken.clientSecret,
                forHTTPHeaderField: accessClientSecretHeader
            )
        }
        if let accessToken = connection.accessToken {
            request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// Builds a route URL. A query never carries a secret: the only values that ride in one
    /// are a run identifier, a number of hours and the words of a memory search.
    static func url(
        origin: URL,
        percentEncodedPath: String,
        query: [URLQueryItem] = []
    ) throws -> URL {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw ControlAPIError.transport("malformed origin")
        }
        var base = components.percentEncodedPath
        if base.hasSuffix("/") {
            base.removeLast()
        }
        components.percentEncodedPath = base + percentEncodedPath
        components.queryItems = query.isEmpty ? nil : query
        components.fragment = nil

        guard let built = components.url else {
            throw ControlAPIError.transport("malformed request URL")
        }
        return built
    }

    /// The signal route for one run.
    ///
    /// A workflow identifier may contain a slash, and the route takes it as one segment, so both
    /// values are escaped down to the unreserved set — which is what the dashboard sends and what
    /// the orchestrator unescapes.
    static func signalPath(namespace: String, workflowId: String) -> String {
        "/api/workflows/" + escaped(namespace) + "/signal/" + escaped(workflowId)
    }

    static let registerDevicePath = "/api/auth/devices"
    static let mintTokenPath = "/api/auth/token"
    static let chatAgentsPath = "/api/chat/agents"

    static func revokeDevicePath(deviceId: String) -> String {
        "/api/auth/devices/" + escaped(deviceId) + "/revoke"
    }

    static func pushDevicePath(deviceId: String) -> String {
        "/api/push/devices/" + escaped(deviceId)
    }

    static func agentActionPath(agentName: String, action: AgentAction) -> String {
        "/api/agents/" + escaped(agentName) + "/" + action.rawValue
    }

    static func runHistoryPath(namespace: String, workflowId: String) -> String {
        "/api/workflows/" + escaped(namespace) + "/history/" + escaped(workflowId)
    }

    static func cancelRunPath(namespace: String, workflowId: String) -> String {
        "/api/workflows/" + escaped(namespace) + "/cancel/" + escaped(workflowId)
    }

    static func terminateRunPath(namespace: String, workflowId: String) -> String {
        "/api/workflows/" + escaped(namespace) + "/terminate/" + escaped(workflowId)
    }

    static func restartRunPath(namespace: String, workflowId: String) -> String {
        "/api/workflows/" + escaped(namespace) + "/restart/" + escaped(workflowId)
    }

    static let schedulesPath = "/api/schedules"

    static func scheduleActionPath(
        namespace: String,
        scheduleId: String,
        action: ScheduleAction
    ) -> String {
        "/api/schedules/" + escaped(namespace) + "/" + action.rawValue + "/" + escaped(scheduleId)
    }

    static let memorySearchPath = "/api/memory/search"

    static func memoryPath(id: String) -> String {
        "/api/memory/" + escaped(id)
    }

    static func agentLogsPath(agentName: String) -> String {
        "/ws/logs/" + escaped(agentName)
    }

    static func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }

    /// ASCII only. `CharacterSet.alphanumerics` also admits non-ASCII letters, which would then
    /// be left unescaped in a path.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
