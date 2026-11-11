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
/// Three reads and one write. Everything a request needs arrives as a parameter, as on
/// `FleetAPIClient`: setup probes an address before any credential is stored.
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
    static func make(
        connection: ControlConnection,
        method: String,
        percentEncodedPath: String,
        body: Data? = nil
    ) throws -> URLRequest {
        let changesState = method.uppercased() != "GET"
        if changesState && connection.operatorToken == nil {
            throw ControlAPIError.readOnly
        }

        var request = URLRequest(
            url: try url(origin: connection.origin, percentEncodedPath: percentEncodedPath)
        )
        request.httpMethod = method

        if let serviceToken = connection.serviceToken {
            request.setValue(serviceToken.clientId, forHTTPHeaderField: accessClientIdHeader)
            request.setValue(
                serviceToken.clientSecret,
                forHTTPHeaderField: accessClientSecretHeader
            )
        }
        if changesState, let operatorToken = connection.operatorToken {
            request.setValue("Bearer " + operatorToken, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    static func url(origin: URL, percentEncodedPath: String) throws -> URL {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw ControlAPIError.transport("malformed origin")
        }
        var base = components.percentEncodedPath
        if base.hasSuffix("/") {
            base.removeLast()
        }
        components.percentEncodedPath = base + percentEncodedPath
        components.query = nil
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

    static func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }

    /// ASCII only. `CharacterSet.alphanumerics` also admits non-ASCII letters, which would then
    /// be left unescaped in a path.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
