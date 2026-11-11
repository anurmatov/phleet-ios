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

/// The session every control-plane request and socket uses.
enum ControlTransport {

    /// No cookies, no cache, no redirects.
    ///
    /// Every request authenticates with its own headers, so nothing here depends on a cookie a
    /// proxy may hand back — and an ephemeral session writes neither secrets nor responses to
    /// disk.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
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

    // MARK: - Plumbing

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
    /// the orchestrator refused the operator token. They are fixed in different places.
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
    }

    /// The orchestrator's `{ "error": … }`, when the body is one. Never the raw body: an error
    /// page from something else on the path is not a message to show a person.
    static func serverMessage(in body: Data) -> String? {
        guard
            let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body),
            let message = decoded.error,
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
