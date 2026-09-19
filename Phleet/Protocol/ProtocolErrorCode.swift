import Foundation

/// The error codes the boundary returns, and what each means for the status that carries it.
///
/// Unknown codes decode rather than throw, for the same reason event kinds do: the vocabulary is
/// append-only, and a client that cannot parse an error it has not seen reports a decode failure
/// where the server sent a perfectly clear refusal.
enum ProtocolErrorCode: Hashable, Sendable {
    case unsupportedProtocol
    case unsupportedKind
    case unsupportedAttachments
    case invalidCursor
    case unauthorized
    case deviceLimit
    case idempotencyConflict
    case payloadTooLarge
    case conversationNotFound
    case rateLimited
    case runtimeBusy
    /// Spelled `internalError` because `internal` is a Swift keyword; the wire value is
    /// `"internal"`.
    case internalError
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "unsupported_protocol": self = .unsupportedProtocol
        case "unsupported_kind": self = .unsupportedKind
        case "unsupported_attachments": self = .unsupportedAttachments
        case "invalid_cursor": self = .invalidCursor
        case "unauthorized": self = .unauthorized
        case "device_limit": self = .deviceLimit
        case "idempotency_conflict": self = .idempotencyConflict
        case "payload_too_large": self = .payloadTooLarge
        case "conversation_not_found": self = .conversationNotFound
        case "rate_limited": self = .rateLimited
        case "runtime_busy": self = .runtimeBusy
        case "internal": self = .internalError
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .unsupportedProtocol: return "unsupported_protocol"
        case .unsupportedKind: return "unsupported_kind"
        case .unsupportedAttachments: return "unsupported_attachments"
        case .invalidCursor: return "invalid_cursor"
        case .unauthorized: return "unauthorized"
        case .deviceLimit: return "device_limit"
        case .idempotencyConflict: return "idempotency_conflict"
        case .payloadTooLarge: return "payload_too_large"
        case .conversationNotFound: return "conversation_not_found"
        case .rateLimited: return "rate_limited"
        case .runtimeBusy: return "runtime_busy"
        case .internalError: return "internal"
        case .unknown(let raw): return raw
        }
    }

    /// The HTTP statuses this code is carried by.
    ///
    /// `internal` is the only code with two, and the pair is the point: the same code arrives on
    /// a `500` the client must not hammer and on a `503` it should back off and retry. Anything
    /// that keys on the code alone treats those identically and either gives up on a restart or
    /// retries a genuine fault forever.
    var expectedStatuses: Set<Int> {
        switch self {
        case .unsupportedProtocol, .unsupportedKind, .unsupportedAttachments, .invalidCursor:
            return [400]
        case .unauthorized:
            return [401]
        case .conversationNotFound:
            return [404]
        case .deviceLimit, .idempotencyConflict:
            return [409]
        case .payloadTooLarge:
            return [413]
        case .rateLimited:
            return [429]
        case .runtimeBusy:
            return [503]
        case .internalError:
            return [500, 503]
        case .unknown:
            return []
        }
    }

    /// How a failure carrying this code on `status` should be treated.
    static func treatment(code: ProtocolErrorCode, status: Int) -> FailureTreatment {
        switch code {
        case .unsupportedProtocol, .unsupportedKind, .unsupportedAttachments, .invalidCursor,
             .idempotencyConflict, .payloadTooLarge:
            // Every one of these is a defect in what this client sent. Retrying the identical
            // request is a loop; it is surfaced instead.
            return .clientDefect
        case .unauthorized:
            return .reauthenticate
        case .deviceLimit, .conversationNotFound:
            return .terminal
        case .rateLimited:
            return .afterRetryAfter
        case .runtimeBusy:
            return .backoff
        case .internalError:
            // The split. 503 is "come back shortly"; 500 is a fault this client cannot fix by
            // asking again, so it is reported and retried only if a person asks.
            return status == 503 ? .backoff : .manualRetry
        case .unknown:
            return status >= 500 ? .backoff : .clientDefect
        }
    }
}

/// What to do about a failed request.
enum FailureTreatment: Hashable, Sendable {
    /// Malformed or out-of-contract request. Surface it; do not re-send it unchanged.
    case clientDefect
    /// Mint a token and replay once.
    case reauthenticate
    /// Retry automatically with backoff.
    case backoff
    /// Retry only after the `Retry-After` delay.
    case afterRetryAfter
    /// Report it, and retry only on an explicit action.
    case manualRetry
    /// Not retryable at all.
    case terminal
}

/// The body every refusal carries.
struct ProtocolErrorBody: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let code: ProtocolErrorCode
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case code
        case message
    }

    init(code: ProtocolErrorCode, message: String? = nil, protocolVersion: String? = nil) {
        self.protocolVersion = protocolVersion
        self.code = code
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion)
        code = ProtocolErrorCode(rawValue: try container.decode(String.self, forKey: .code))
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}
