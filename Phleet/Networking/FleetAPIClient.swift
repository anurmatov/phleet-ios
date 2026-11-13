import Foundation

/// Why an HTTPS call failed.
///
/// `unauthorized` is deliberately one case with nothing in it. Every auth failure is
/// indistinguishable by contract — expired code, already-burned code, unknown code, wrong
/// secret — and a richer type here would invite a UI that guesses which.
enum FleetAPIError: Error, Equatable, Sendable {
    /// Any `401`, from any route.
    case unauthorized
    /// A typed refusal the server named.
    case refused(ProtocolErrorCode, status: Int, message: String?)
    /// `429`, with the delay the server asked for.
    case rateLimited(retryAfterSeconds: Int)
    /// A status with no interpretable body.
    case unexpectedStatus(Int)
    /// The response's own `protocol` field was absent or not this version.
    case protocolMismatch(String?)
    /// The request never completed.
    case transport(String)
    /// The response completed and could not be read.
    case decoding(String)

    /// `409 agent_unavailable` — the agent this conversation is with does not accept chat now.
    var isAgentUnavailable: Bool {
        if case .refused(.agentUnavailable, _, _) = self { return true }
        return false
    }

    /// What to do about it.
    var treatment: FailureTreatment {
        switch self {
        case .unauthorized:
            return .reauthenticate
        case .refused(let code, let status, _):
            return ProtocolErrorCode.treatment(code: code, status: status)
        case .rateLimited:
            return .afterRetryAfter
        case .unexpectedStatus(let status):
            return status >= 500 ? .backoff : .clientDefect
        case .protocolMismatch, .decoding:
            return .clientDefect
        case .transport:
            return .backoff
        }
    }
}

/// The chat service's HTTPS routes this app uses.
///
/// Signing in is not here: the orchestrator owns it (`ControlAPIClient.registerDevice`,
/// `mintToken`), and the token it issues is the one these routes take.
///
/// The access token is a parameter, and it is never placed in a URL on any of these — header
/// only. URLs are retained by intermediaries, access logs and crash reports. The access-proxy
/// service token, when there is one, is the implementation's: it belongs to the address, not to
/// the request.
protocol FleetAPIClient {

    /// `GET /v1/session`
    func session(
        origin: URL,
        accessToken: String
    ) async throws -> SessionResponse

    /// `POST /v1/conversations` — opens, or finds again, the conversation with `agent` that this
    /// person calls `externalRef`.
    func openConversation(
        origin: URL,
        accessToken: String,
        externalRef: String,
        agent: String,
        clientInstanceId: String
    ) async throws -> OpenConversationResponse

    /// `GET /v1/conversations/{id}/events`
    func catchUp(
        origin: URL,
        accessToken: String,
        conversationId: String,
        afterSeq: Int,
        limit: Int
    ) async throws -> CatchUpResponse

    /// `POST /v1/conversations/{id}/submissions`
    func submit(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: SubmissionBody
    ) async throws -> SubmissionAcceptedResponse

    /// `POST /v1/conversations/{id}/cursor`
    func advanceCursor(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: CursorBody
    ) async throws -> CursorAcceptedResponse
}
