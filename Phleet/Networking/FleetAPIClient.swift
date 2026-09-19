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

    /// `409 device_limit` — another device is already active.
    var isDeviceLimit: Bool {
        if case .refused(.deviceLimit, _, _) = self { return true }
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

/// The seven HTTPS routes this slice uses.
///
/// `origin` is a parameter rather than state because enrollment happens **before** there is a
/// stored profile: the person has typed an address that nothing has accepted yet.
///
/// The access token is a parameter too, and it is never placed in a URL on any of these — header
/// only. URLs are retained by intermediaries, access logs and crash reports.
protocol FleetAPIClient {

    /// `POST /v1/auth/devices`
    func registerDevice(
        origin: URL,
        enrollmentCode: String
    ) async throws -> RegisterDeviceResponse

    /// `POST /v1/auth/token`
    func mintToken(
        origin: URL,
        deviceId: String,
        deviceSecret: String
    ) async throws -> MintTokenResponse

    /// `GET /v1/session`
    func session(
        origin: URL,
        accessToken: String
    ) async throws -> SessionResponse

    /// `POST /v1/conversations`
    func openConversation(
        origin: URL,
        accessToken: String,
        externalRef: String,
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
