import Foundation

/// Why a control-plane call failed.
enum ControlAPIError: Error, Equatable, Sendable {
    /// Whatever sits in front of the orchestrator turned the request away: a redirect to a
    /// sign-in page, or a `403`. The orchestrator itself never saw it.
    case accessDenied
    /// `401`: the orchestrator refused the operator token.
    case unauthorized
    /// `409`: the run or its gate is no longer what was on screen. Carries the server's code.
    case gateChanged(String?)
    /// Any other refusal the server named.
    case refused(status: Int, message: String?)
    /// The request never completed.
    case transport(String)
    /// The response completed and was not what an orchestrator answers with.
    case decoding(String)
    /// This connection has no operator token, so nothing that changes state can be sent.
    case readOnly
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

    /// `POST /api/workflows/{namespace}/cancel/{workflowId}?runId=`
    func cancelRun(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        runId: String
    ) async throws

    /// `GET /api/workflow-types`
    func workflowTypes(_ connection: ControlConnection) async throws -> [WorkflowType]

    /// `POST /api/workflows/start`. Returns the identifier of the run that was started.
    func startWorkflow(
        _ connection: ControlConnection,
        body: StartWorkflowBody
    ) async throws -> String

    /// `GET /api/operator-token` — whether the orchestrator accepts this connection's operator
    /// token. Changes nothing.
    func checkOperatorToken(_ connection: ControlConnection) async throws -> OperatorTokenCheck

    /// `PUT /api/push/devices/{deviceId}` — tell the orchestrator where to send this install's
    /// notifications.
    func registerPushDevice(
        _ connection: ControlConnection,
        deviceId: String,
        token: String
    ) async throws

    /// `DELETE /api/push/devices/{deviceId}`
    func unregisterPushDevice(_ connection: ControlConnection, deviceId: String) async throws
}

/// What the orchestrator said about the operator token.
enum OperatorTokenCheck: Equatable, Sendable {
    /// It is the operator token.
    case accepted
    /// It is not.
    case rejected
    /// The orchestrator has no operator token configured, so writes are not gated at all. The
    /// token that was sent was not checked against anything.
    case notRequired
    /// The orchestrator has no such route: it predates the check. Nothing was learned.
    case unsupported
}

/// How control-plane requests are put on the wire.
///
/// Static and reachable from the tests on purpose. The properties worth asserting — the operator
/// token rides only on requests that change something, neither secret ever appears in a URL, and
/// a read-only connection cannot build a write — are properties of these functions, and
/// asserting them on a double that is merely handed the values would prove nothing.
enum ControlRequest {

    static let accessClientIdHeader = "CF-Access-Client-Id"
    static let accessClientSecretHeader = "CF-Access-Client-Secret"

    /// Builds a request.
    ///
    /// - The service token goes on **every** request: the proxy in front authenticates reads too.
    /// - The operator token goes on a request only when it changes something. The orchestrator
    ///   does not ask for it on a read, and a secret that is not sent cannot be logged in transit.
    /// - The one exception is `presentsOperatorToken`: the read whose whole purpose is to ask
    ///   whether the token is right.
    static func make(
        connection: ControlConnection,
        method: String,
        percentEncodedPath: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        presentsOperatorToken: Bool = false
    ) throws -> URLRequest {
        let changesState = method.uppercased() != "GET"
        let needsOperatorToken = changesState || presentsOperatorToken
        if needsOperatorToken && connection.operatorToken == nil {
            throw ControlAPIError.readOnly
        }

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
        if needsOperatorToken, let operatorToken = connection.operatorToken {
            request.setValue("Bearer " + operatorToken, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// Builds a route URL. A query never carries a secret: the only values that ride in one
    /// are a run identifier and a number of hours.
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

    static let operatorTokenPath = "/api/operator-token"

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
