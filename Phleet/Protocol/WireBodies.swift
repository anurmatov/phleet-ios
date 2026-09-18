import Foundation

// MARK: - Requests
//
// Every request type below declares `protocol` as a `let` with a fixed value, which keeps it out
// of the memberwise initializer. No call site can omit it and none can override it, so "every
// body carries the protocol field" is enforced by the type rather than remembered at each of the
// five call sites. The server checks the field ordinally, immediately after deserialization and
// before any other validation, on every route including enrollment.

/// `POST /v1/auth/devices`
struct RegisterDeviceBody: Equatable, Sendable, Encodable {
    let protocolVersion = ProtocolVersion.current
    let enrollmentCode: String

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case enrollmentCode
    }
}

/// `POST /v1/auth/token`
struct MintTokenBody: Equatable, Sendable, Encodable {
    let protocolVersion = ProtocolVersion.current
    let deviceId: String
    let deviceSecret: String

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case deviceId
        case deviceSecret
    }
}

/// `POST /v1/conversations`
///
/// `clientInstanceId` is optional on this route, and the client always sends it anyway so that
/// cursor bookkeeping is established at open rather than at the first cursor write.
struct OpenConversationBody: Equatable, Sendable, Encodable {
    let protocolVersion = ProtocolVersion.current
    let externalRef: String
    let clientInstanceId: String

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case externalRef
        case clientInstanceId
    }
}

/// `POST /v1/conversations/{id}/submissions`
///
/// `attachments` is deliberately absent rather than sent empty: a non-empty array is
/// `400 unsupported_attachments`, and this slice has nothing to attach.
struct SubmissionBody: Equatable, Sendable, Encodable {
    /// `create` or `steer`. This slice only ever sends `create`; `steer` exists so the type does
    /// not have to change when the steer route is surfaced.
    enum SubmissionType: String, Equatable, Sendable, Encodable {
        case create
        case steer
    }

    let protocolVersion = ProtocolVersion.current
    let type: SubmissionType
    let submissionId: String
    let idempotencyKey: String
    let text: String

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case type
        case submissionId
        case idempotencyKey
        case text
    }
}

/// `POST /v1/conversations/{id}/cursor`
///
/// **Flat.** `conversation.ack` is the protocol kind the server records, not a wrapper object on
/// the wire. Nesting these fields under one produces `400 invalid_cursor` — `clientInstanceId`
/// and `deliveredSeq` arrive absent — with no symptom beyond a cursor that never advances.
struct CursorBody: Equatable, Sendable, Encodable {
    let protocolVersion = ProtocolVersion.current
    let clientInstanceId: String
    let deliveredSeq: Int
    /// Never above `deliveredSeq`: the server refuses that with `invalid_cursor` and writes
    /// nothing.
    let readSeq: Int?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case clientInstanceId
        case deliveredSeq
        case readSeq
    }
}

// MARK: - Responses

struct RegisterDeviceResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let deviceId: String
    let deviceSecret: String

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case deviceId
        case deviceSecret
    }

    init(deviceId: String, deviceSecret: String, protocolVersion: String? = nil) {
        self.protocolVersion = protocolVersion
        self.deviceId = deviceId
        self.deviceSecret = deviceSecret
    }
}

struct MintTokenResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let accessToken: String
    let expiresInSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case accessToken
        case expiresInSeconds
    }

    init(accessToken: String, expiresInSeconds: Int, protocolVersion: String? = nil) {
        self.protocolVersion = protocolVersion
        self.accessToken = accessToken
        self.expiresInSeconds = expiresInSeconds
    }
}

/// The server-reported bounds this client reads rather than hardcodes.
struct SessionLimits: Equatable, Sendable, Decodable {
    let inboundTextBytes: Int
    let catchUpLimitDefault: Int
    let catchUpLimitMax: Int
    let identifierMaxLength: Int
    let outboundBufferEvents: Int

    private enum CodingKeys: String, CodingKey {
        case inboundTextBytes
        case catchUpLimitDefault
        case catchUpLimitMax
        case identifierMaxLength
        case outboundBufferEvents
    }

    /// The values the contract documents, used when `GET /v1/session` fails.
    ///
    /// A failed session read does not fail enrollment — the credential is what matters — so the
    /// app needs somewhere to stand while it retries on the next foreground.
    static let documentedDefaults = SessionLimits(
        inboundTextBytes: 32768,
        catchUpLimitDefault: 200,
        catchUpLimitMax: 1000,
        identifierMaxLength: ClientIdentifier.maximumLength,
        outboundBufferEvents: 256
    )

    init(
        inboundTextBytes: Int,
        catchUpLimitDefault: Int,
        catchUpLimitMax: Int,
        identifierMaxLength: Int,
        outboundBufferEvents: Int
    ) {
        self.inboundTextBytes = inboundTextBytes
        self.catchUpLimitDefault = catchUpLimitDefault
        self.catchUpLimitMax = catchUpLimitMax
        self.identifierMaxLength = identifierMaxLength
        self.outboundBufferEvents = outboundBufferEvents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = SessionLimits.documentedDefaults
        inboundTextBytes = try container.decodeIfPresent(Int.self, forKey: .inboundTextBytes)
            ?? fallback.inboundTextBytes
        catchUpLimitDefault = try container.decodeIfPresent(Int.self, forKey: .catchUpLimitDefault)
            ?? fallback.catchUpLimitDefault
        catchUpLimitMax = try container.decodeIfPresent(Int.self, forKey: .catchUpLimitMax)
            ?? fallback.catchUpLimitMax
        identifierMaxLength = try container.decodeIfPresent(Int.self, forKey: .identifierMaxLength)
            ?? fallback.identifierMaxLength
        outboundBufferEvents = try container.decodeIfPresent(Int.self, forKey: .outboundBufferEvents)
            ?? fallback.outboundBufferEvents
    }
}

struct SessionResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let principalId: String
    /// Cosmetic and non-authoritative: a display string, and nothing routes on it.
    let agentLabel: String?
    let limits: SessionLimits

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case principalId
        case agentLabel
        case limits
    }

    init(
        principalId: String,
        agentLabel: String?,
        limits: SessionLimits,
        protocolVersion: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.principalId = principalId
        self.agentLabel = agentLabel
        self.limits = limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion)
        principalId = try container.decode(String.self, forKey: .principalId)
        agentLabel = try container.decodeIfPresent(String.self, forKey: .agentLabel)
        limits = try container.decodeIfPresent(SessionLimits.self, forKey: .limits)
            ?? SessionLimits.documentedDefaults
    }
}

struct OpenConversationResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let conversationId: String
    /// Where live begins. The stream's attach floor is derived from this and nothing else.
    let nextSeq: Int
    /// The oldest seq still retained. Below it, history is gone.
    let retainedFloorSeq: Int

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case conversationId
        case nextSeq
        case retainedFloorSeq
    }

    init(
        conversationId: String,
        nextSeq: Int,
        retainedFloorSeq: Int,
        protocolVersion: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.conversationId = conversationId
        self.nextSeq = nextSeq
        self.retainedFloorSeq = retainedFloorSeq
    }
}

/// Present only when history expired beneath the requested cursor, so its presence is the
/// signal and its absence needs no flag.
struct CatchUpGap: Equatable, Sendable, Decodable {
    let fromSeq: Int?
    let toSeq: Int?
    let retainedFloorSeq: Int?

    init(fromSeq: Int?, toSeq: Int?, retainedFloorSeq: Int?) {
        self.fromSeq = fromSeq
        self.toSeq = toSeq
        self.retainedFloorSeq = retainedFloorSeq
    }
}

struct CatchUpResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let gap: CatchUpGap?
    let events: [ConversationEvent]
    let nextAfterSeq: Int
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case gap
        case events
        case nextAfterSeq
        case hasMore
    }

    init(
        gap: CatchUpGap? = nil,
        events: [ConversationEvent],
        nextAfterSeq: Int,
        hasMore: Bool,
        protocolVersion: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.gap = gap
        self.events = events
        self.nextAfterSeq = nextAfterSeq
        self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion)
        gap = try container.decodeIfPresent(CatchUpGap.self, forKey: .gap)
        events = try container.decodeIfPresent([ConversationEvent].self, forKey: .events) ?? []
        nextAfterSeq = try container.decode(Int.self, forKey: .nextAfterSeq)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

/// `201` carries `acceptedSeq`; `202` does not, and that is a success, not a decode failure.
///
/// A first accept is never `202` — a `202` is always a same-key retry landing while the
/// disposition transaction is still outstanding.
struct SubmissionAcceptedResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let submissionId: String
    let acceptedSeq: Int?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case submissionId
        case acceptedSeq
    }

    init(submissionId: String, acceptedSeq: Int?, protocolVersion: String? = nil) {
        self.protocolVersion = protocolVersion
        self.submissionId = submissionId
        self.acceptedSeq = acceptedSeq
    }
}

struct CursorAcceptedResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
    }

    init(protocolVersion: String? = nil) {
        self.protocolVersion = protocolVersion
    }
}
