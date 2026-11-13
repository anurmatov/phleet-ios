import Foundation

/// Refuses every redirect.
///
/// An orchestrator never redirects. A proxy in front of one does, when it does not recognise the
/// caller: it answers with a redirect to a sign-in page. Following it would hand the next host
/// the service-token headers and return a web page where a list of agents was expected. Refusing
/// keeps the secrets on the origin they were stored for, and turns "not let in" into a status
/// this client can name.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// The session every request and socket to the Fleet server uses.
enum ControlTransport {

    /// How long an orchestrator request may wait for data.
    static let requestTimeoutSeconds: TimeInterval = 20

    /// The chat service holds a socket open between frames for longer than the orchestrator's
    /// requests should take, and pings it every twenty seconds: a twenty-second idle limit would
    /// race the ping and drop a healthy socket. Its session waits as long as the system default.
    static let chatRequestTimeoutSeconds: TimeInterval = 60

    /// No cookies, no cache, no redirects.
    ///
    /// Every request authenticates with its own headers, so nothing here depends on a cookie a
    /// proxy may hand back — and an ephemeral session writes neither secrets nor responses to
    /// disk.
    static func makeSession(
        requestTimeout: TimeInterval = ControlTransport.requestTimeoutSeconds
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        return URLSession(
            configuration: configuration,
            delegate: RedirectRefusingDelegate(),
            delegateQueue: nil
        )
    }
}

/// The `URLSession` implementation of the control-plane routes.
final class URLSessionControlAPIClient: ControlAPIClient {

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession) {
        self.session = session
    }

    func agents(_ connection: ControlConnection) async throws -> [FleetAgent] {
        let request = try ControlRequest.make(
            connection: connection,
            method: "GET",
            percentEncodedPath: "/api/agents"
        )
        let data = try await perform(request)
        let list: LossyList<FleetAgent> = try Self.decode(data, decoder)
        return list.items
    }

    func workflows(_ connection: ControlConnection) async throws -> [WorkflowRun] {
        let request = try ControlRequest.make(
            connection: connection,
            method: "GET",
            percentEncodedPath: "/api/workflows"
        )
        let data = try await perform(request)
        let list: LossyList<WorkflowRun> = try Self.decode(data, decoder)
        return list.items
    }

    func signalRegistry(
        _ connection: ControlConnection
    ) async throws -> [String: [SignalDefinition]] {
        let request = try ControlRequest.make(
            connection: connection,
            method: "GET",
            percentEncodedPath: "/api/signals"
        )
        let data = try await perform(request)
        let registry: [String: LossyList<SignalDefinition>] = try Self.decode(data, decoder)
        return registry.mapValues { $0.items }
    }

    func sendSignal(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        body: SignalRequestBody
    ) async throws {
        let payload: Data
        do {
            payload = try encoder.encode(body)
        } catch {
            throw ControlAPIError.decoding("request body could not be encoded")
        }
        let request = try ControlRequest.make(
            connection: connection,
            method: "POST",
            percentEncodedPath: ControlRequest.signalPath(
                namespace: namespace,
                workflowId: workflowId
            ),
            body: payload
        )
        _ = try await perform(request)
    }

    func performAgentAction(
        _ connection: ControlConnection,
        agentName: String,
        action: AgentAction
    ) async throws {
        let request = try ControlRequest.make(
            connection: connection,
            method: "POST",
            percentEncodedPath: ControlRequest.agentActionPath(
                agentName: agentName,
                action: action
            )
        )
        _ = try await perform(request)
    }

    func closedRuns(_ connection: ControlConnection, hours: Int) async throws -> [WorkflowRun] {
        let request = try ControlRequest.make(
            connection: connection,
            method: "GET",
            percentEncodedPath: "/api/workflows/completed",
            query: [URLQueryItem(name: "hours", value: String(hours))]
        )
        let data = try await perform(request)
        let list: LossyList<WorkflowRun> = try Self.decode(data, decoder)
        return list.items
    }

    func runHistory(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String
    ) async throws -> [WorkflowEvent] {
        let request = try ControlRequest.make(
            connection: connection,
            method: "GET",
            percentEncodedPath: ControlRequest.runHistoryPath(
                namespace: namespace,
                workflowId: workflowId
            )
        )
        let data = try await perform(request)
        let list: LossyList<WorkflowEvent> = try Self.decode(data, decoder)
        return list.items
    }

    func exactRunHistory(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        runId: String
    ) async throws -> [WorkflowEvent] {
        guard !runId.isEmpty else { throw ControlAPIError.decoding("exact run required") }
        let request = try ControlRequest.make(
            connection: connection,
            method: "GET",
            percentEncodedPath: ControlRequest.runHistoryPath(namespace: namespace, workflowId: workflowId),
            query: [URLQueryItem(name: "runId", value: runId)]
        )
        let data = try await perform(request)
        // Unlike display-only history, an unreadable event must fail the entire read.
        return try Self.decode(data, decoder)
    }

    func cancelRun(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        runId: String
    ) async throws {
        let request = try ControlRequest.make(
            connection: connection,
            method: "POST",
            percentEncodedPath: ControlRequest.cancelRunPath(
                namespace: namespace,
                workflowId: workflowId
            ),
            // The run, not just the workflow: a workflow that has since been restarted under
            // the same identifier must not have its new run cancelled by a stale screen.
            query: [URLQueryItem(name: "runId", value: runId)]
        )
        _ = try await perform(request)
    }

    func workflowTypes(_ connection: ControlConnection) async throws -> [WorkflowType] {
        let request = try ControlRequest.make(
            connection: connection,
            method: "GET",
            percentEncodedPath: "/api/workflow-types"
        )
        let data = try await perform(request)
        let list: LossyList<WorkflowType> = try Self.decode(data, decoder)
        return list.items
    }

    private struct StartedWorkflow: Decodable {
        let workflowId: String
    }

    func startWorkflow(
        _ connection: ControlConnection,
        body: StartWorkflowBody
    ) async throws -> String {
        let payload: Data
        do {
            payload = try encoder.encode(body)
        } catch {
            throw ControlAPIError.decoding("request body could not be encoded")
        }
        let request = try ControlRequest.make(
            connection: connection,
            method: "POST",
            percentEncodedPath: "/api/workflows/start",
            body: payload
        )
        let data = try await perform(request)
        let started: StartedWorkflow = try Self.decode(data, decoder)
        return started.workflowId
    }

    private struct PushRegistration: Encodable {
        let token: String
    }

    func registerPushDevice(
        _ connection: ControlConnection,
        deviceId: String,
        token: String
    ) async throws {
        let payload: Data
        do {
            payload = try encoder.encode(PushRegistration(token: token))
        } catch {
            throw ControlAPIError.decoding("request body could not be encoded")
        }
        let request = try ControlRequest.make(
            connection: connection,
            method: "PUT",
            percentEncodedPath: ControlRequest.pushDevicePath(deviceId: deviceId),
            body: payload
        )
        _ = try await perform(request)
    }

    func unregisterPushDevice(_ connection: ControlConnection, deviceId: String) async throws {
        let request = try ControlRequest.make(
            connection: connection,
            method: "DELETE",
            percentEncodedPath: ControlRequest.pushDevicePath(deviceId: deviceId)
        )
        _ = try await perform(request)
    }

    // MARK: - Signing in

    private struct RegisterDeviceBody: Encodable {
        let enrollmentCode: String
        let deviceName: String?
    }

    func registerDevice(
        _ connection: ControlConnection,
        enrollmentCode: String,
        deviceName: String?
    ) async throws -> RegisteredDevice {
        let payload = try encode(
            RegisterDeviceBody(enrollmentCode: enrollmentCode, deviceName: deviceName)
        )
        let request = try ControlRequest.make(
            connection: connection,
            method: "POST",
            percentEncodedPath: ControlRequest.registerDevicePath,
            body: payload
        )
        let data = try await perform(request)
        return try Self.decode(data, decoder)
    }

    private struct MintTokenBody: Encodable {
        let deviceId: String
        let deviceSecret: String
    }

    func mintToken(
        _ connection: ControlConnection,
        deviceId: String,
        deviceSecret: String
    ) async throws -> MintTokenResponse {
        let payload = try encode(MintTokenBody(deviceId: deviceId, deviceSecret: deviceSecret))
        let request = try ControlRequest.make(
            connection: connection,
            method: "POST",
            percentEncodedPath: ControlRequest.mintTokenPath,
            body: payload
        )
        let data = try await perform(request)
        return try Self.decode(data, decoder)
    }

    func revokeDevice(_ connection: ControlConnection, deviceId: String) async throws {
        let request = try ControlRequest.make(
            connection: connection,
            method: "POST",
            percentEncodedPath: ControlRequest.revokeDevicePath(deviceId: deviceId)
        )
        _ = try await perform(request)
    }

    // MARK: - Chat

    func chatAgents(_ connection: ControlConnection) async throws -> ChatAgentList {
        let request = try ControlRequest.make(
            connection: connection,
            method: "GET",
            percentEncodedPath: ControlRequest.chatAgentsPath
        )
        let data = try await perform(request)
        return try Self.decode(data, decoder)
    }

    // MARK: - Plumbing

    private func encode<Body: Encodable>(_ body: Body) throws -> Data {
        do {
            return try encoder.encode(body)
        } catch {
            throw ControlAPIError.decoding("request body could not be encoded")
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ControlAPIError.transport(String(describing: type(of: error)))
        }

        guard let http = response as? HTTPURLResponse else {
            throw ControlAPIError.transport("non-HTTP response")
        }
        if let failure = Self.failure(status: http.statusCode, body: data) {
            throw failure
        }
        return data
    }

    /// Maps a status to a failure, or `nil` for a success.
    ///
    /// Static so the mapping is assertable without a network. The two that must not be confused:
    /// a redirect or a `403` means the proxy in front refused the caller, while a `401` means
    /// the orchestrator refused this phone's sign-in. They are fixed in different places.
    static func failure(status: Int, body: Data) -> ControlAPIError? {
        switch status {
        case 200..<300:
            return nil
        case 300..<400, 403:
            return .accessDenied
        case 401:
            return .unauthorized
        case 409:
            return .gateChanged(serverMessage(in: body))
        default:
            return .refused(status: status, message: serverMessage(in: body))
        }
    }

    private struct ErrorBody: Decodable {
        let error: String?
        /// Some routes answer with a problem document instead, whose message is `detail`.
        let detail: String?
    }

    /// The orchestrator's `{ "error": … }`, when the body is one. Never the raw body: an error
    /// page from something else on the path is not a message to show a person.
    static func serverMessage(in body: Data) -> String? {
        guard
            let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body),
            let message = decoded.error ?? decoded.detail,
            !message.isEmpty
        else { return nil }
        return message
    }

    static func decode<Value: Decodable>(_ data: Data, _ decoder: JSONDecoder) throws -> Value {
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw ControlAPIError.decoding(String(describing: Value.self))
        }
    }
}
