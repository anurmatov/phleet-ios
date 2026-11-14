import Foundation

/// A response that carries the protocol field, so it can be verified rather than assumed.
protocol ProtocolVersionedResponse {
    var protocolVersion: String? { get }
}

extension SessionResponse: ProtocolVersionedResponse {}
extension OpenConversationResponse: ProtocolVersionedResponse {}
extension CatchUpResponse: ProtocolVersionedResponse {}
extension SubmissionAcceptedResponse: ProtocolVersionedResponse {}
extension CursorAcceptedResponse: ProtocolVersionedResponse {}
extension ConversationListResponse: ProtocolVersionedResponse {}
extension CancelAcceptedResponse: ProtocolVersionedResponse {}
extension ReserveAttachmentResponse: ProtocolVersionedResponse {}
extension SealedAttachmentResponse: ProtocolVersionedResponse {}

/// The `URLSession` implementation of the chat routes.
///
/// The access token is carried in `Authorization` and appears in no URL — query, path or
/// fragment — on any request here. URLs are retained by intermediaries, access logs and crash
/// reports; headers are not.
///
/// The chat service is reached through the same address as the orchestrator, so a request goes
/// through the same access proxy with the same service token, on a session that follows no
/// redirect and keeps no cookie (`ControlTransport.makeSession`).
final class URLSessionFleetAPIClient: FleetAPIClient {

    private let session: URLSession
    private let serviceToken: AccessServiceToken?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession, serviceToken: AccessServiceToken?) {
        self.session = session
        self.serviceToken = serviceToken
    }

    // MARK: - Routes

    func session(origin: URL, accessToken: String) async throws -> SessionResponse {
        let request = Self.request(
            url: try Self.routeURL(origin: origin, path: "/v1/session"),
            method: "GET",
            accessToken: accessToken,
            serviceToken: serviceToken
        )
        return try await perform(request)
    }

    func openConversation(
        origin: URL,
        accessToken: String,
        externalRef: String,
        agent: String,
        clientInstanceId: String
    ) async throws -> OpenConversationResponse {
        try await post(
            origin: origin,
            path: "/v1/conversations",
            accessToken: accessToken,
            body: OpenConversationBody(
                externalRef: externalRef,
                agent: agent,
                clientInstanceId: clientInstanceId
            )
        )
    }

    func catchUp(
        origin: URL,
        accessToken: String,
        conversationId: String,
        afterSeq: Int,
        limit: Int
    ) async throws -> CatchUpResponse {
        let target = try Self.routeURL(
            origin: origin,
            path: "/v1/conversations/" + escaped(conversationId) + "/events",
            query: [
                // Sent explicitly rather than omitted: the server parses an absent `afterSeq` to
                // the same value, and an explicit one makes the request self-describing in a log.
                URLQueryItem(name: "afterSeq", value: String(afterSeq)),
                URLQueryItem(name: "limit", value: String(limit))
            ]
        )
        let request = Self.request(
            url: target,
            method: "GET",
            accessToken: accessToken,
            serviceToken: serviceToken
        )
        return try await perform(request)
    }

    func submit(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: SubmissionBody
    ) async throws -> SubmissionAcceptedResponse {
        try await post(
            origin: origin,
            path: "/v1/conversations/" + escaped(conversationId) + "/submissions",
            accessToken: accessToken,
            body: body
        )
    }

    func advanceCursor(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: CursorBody
    ) async throws -> CursorAcceptedResponse {
        try await post(
            origin: origin,
            path: "/v1/conversations/" + escaped(conversationId) + "/cursor",
            accessToken: accessToken,
            body: body
        )
    }

    func conversations(origin: URL, accessToken: String) async throws -> ConversationListResponse {
        let request = Self.request(
            url: try Self.routeURL(origin: origin, path: "/v1/conversations"),
            method: "GET",
            accessToken: accessToken,
            serviceToken: serviceToken
        )
        return try await perform(request)
    }

    func cancel(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: CancelBody
    ) async throws -> CancelAcceptedResponse {
        try await post(
            origin: origin,
            // `:cancel` is a literal suffix on the identifier's own segment, not a segment.
            path: "/v1/conversations/" + escaped(conversationId) + ":cancel",
            accessToken: accessToken,
            body: body
        )
    }

    func reserveAttachment(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: ReserveAttachmentBody
    ) async throws -> ReserveAttachmentResponse {
        try await post(
            origin: origin,
            path: "/v1/conversations/" + escaped(conversationId) + "/attachments",
            accessToken: accessToken,
            body: body
        )
    }

    func uploadAttachment(
        origin: URL,
        uploadToken: String,
        attachmentId: String,
        contentType: String,
        data: Data
    ) async throws -> SealedAttachmentResponse {
        // The address is built here from the identifier, never taken from the reservation's
        // answer: the bytes and the token go to the server this phone is signed in to, whatever
        // that answer said. The token rides where a sign-in would, and no sign-in is sent.
        var request = Self.request(
            url: try Self.routeURL(origin: origin, path: Self.attachmentPath(attachmentId)),
            method: "PUT",
            accessToken: uploadToken,
            serviceToken: serviceToken
        )
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await session.upload(for: request, from: data)
        } catch {
            throw FleetAPIError.transport(String(describing: type(of: error)))
        }
        return try decoded(body, response)
    }

    func attachmentContent(
        origin: URL,
        accessToken: String,
        attachmentId: String
    ) async throws -> Data {
        let request = Self.request(
            url: try Self.routeURL(origin: origin, path: Self.attachmentPath(attachmentId)),
            method: "GET",
            accessToken: accessToken,
            serviceToken: serviceToken
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FleetAPIError.transport(String(describing: type(of: error)))
        }
        guard let http = response as? HTTPURLResponse else {
            throw FleetAPIError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, headers: http, data: data)
        }
        // Raw bytes: there is no body to carry a protocol field, and nothing here decodes them.
        return data
    }

    /// The one address an attachment's bytes move through, in either direction.
    static func attachmentPath(_ attachmentId: String) -> String {
        let escaped = attachmentId.addingPercentEncoding(withAllowedCharacters: identifierCharacters)
            ?? attachmentId
        return "/v1/attachments/" + escaped + "/content"
    }

    // MARK: - Plumbing

    private func post<Body: Encodable, Response: Decodable & ProtocolVersionedResponse>(
        origin: URL,
        path: String,
        accessToken: String,
        body: Body
    ) async throws -> Response {
        var request = Self.request(
            url: try Self.routeURL(origin: origin, path: path),
            method: "POST",
            accessToken: accessToken,
            serviceToken: serviceToken
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw FleetAPIError.decoding("request body could not be encoded")
        }
        return try await perform(request)
    }

    /// Builds a request with the credentials in headers and nowhere else.
    ///
    /// Static and reachable from the tests: where the secrets go is a property of this function.
    static func request(
        url: URL,
        method: String,
        accessToken: String,
        serviceToken: AccessServiceToken?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        if let serviceToken {
            request.setValue(
                serviceToken.clientId,
                forHTTPHeaderField: ControlRequest.accessClientIdHeader
            )
            request.setValue(
                serviceToken.clientSecret,
                forHTTPHeaderField: ControlRequest.accessClientSecretHeader
            )
        }
        return request
    }

    private func perform<Response: Decodable & ProtocolVersionedResponse>(
        _ request: URLRequest
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FleetAPIError.transport(String(describing: type(of: error)))
        }

        return try decoded(data, response)
    }

    private func decoded<Response: Decodable & ProtocolVersionedResponse>(
        _ data: Data,
        _ response: URLResponse
    ) throws -> Response {
        guard let http = response as? HTTPURLResponse else {
            throw FleetAPIError.transport("non-HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, headers: http, data: data)
        }

        let decoded: Response
        do {
            decoded = try decoder.decode(Response.self, from: data)
        } catch {
            throw FleetAPIError.decoding(String(describing: Response.self))
        }

        // Verified, not assumed. A body that does not name this protocol version is not a body
        // this build knows how to believe.
        guard ProtocolVersion.isSupported(decoded.protocolVersion) else {
            throw FleetAPIError.protocolMismatch(decoded.protocolVersion)
        }
        return decoded
    }

    private func failure(status: Int, headers: HTTPURLResponse, data: Data) -> FleetAPIError {
        if status == 401 {
            // One case, nothing in it. Every auth failure is indistinguishable by contract, and
            // a richer type here would invite a UI that guesses which.
            return .unauthorized
        }
        if status == 429 {
            let header = headers.value(forHTTPHeaderField: "Retry-After")
            return .rateLimited(retryAfterSeconds: RetryAfterParser.seconds(from: header))
        }
        if let body = try? decoder.decode(ProtocolErrorBody.self, from: data) {
            return .refused(body.code, status: status, message: body.message)
        }
        return .unexpectedStatus(status)
    }

    /// Builds a route URL.
    ///
    /// Static and reachable from the tests on purpose: "the access token never appears in a URL"
    /// is a property of this function, and asserting it on a double that is handed the token as a
    /// parameter would prove nothing.
    static func routeURL(origin: URL, path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw FleetAPIError.transport("malformed origin")
        }
        var base = components.path
        if base.hasSuffix("/") {
            base.removeLast()
        }
        components.path = base + path
        components.queryItems = query.isEmpty ? nil : query

        guard let built = components.url else {
            throw FleetAPIError.transport("malformed request URL")
        }
        return built
    }

    /// Identifiers are `[A-Za-z0-9_-]` by the shared rule, so this escapes nothing in practice —
    /// it is here so a value that somehow bypassed validation cannot reshape a path. The allowed
    /// set is exactly the identifier charset: escaping `-` or `_` would mangle a legitimate id.
    private func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: Self.identifierCharacters)
            ?? component
    }

    private static let identifierCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_")
        return set
    }()
}
