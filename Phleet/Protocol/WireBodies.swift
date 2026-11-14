import Foundation

// MARK: - Requests
//
// Every request type below declares `protocol` as a `let` with a fixed value, which keeps it out
// of the memberwise initializer. No call site can omit it and none can override it, so "every
// body carries the protocol field" is enforced by the type rather than remembered at each call
// site. The server checks the field ordinally, immediately after deserialization and before any
// other validation, on every chat route.

/// The one thread a person has with an agent.
enum ChatThread {
    /// Client-chosen, and what makes open idempotent across reinstall, signing in again, and
    /// the dashboard: a conversation is found again by the person, the agent and this reference.
    /// Everything this app sends — the thread's own screen, a shortcut, the share sheet — uses
    /// the same one, so it all lands in the same conversation.
    static let externalRef = "main"
}

/// `POST /v1/conversations`
///
/// `agent` is required: a conversation is with one agent for life, and the same `externalRef`
/// with another agent is another conversation.
///
/// `clientInstanceId` is optional on this route, and the client always sends it anyway so that
/// cursor bookkeeping is established at open rather than at the first cursor write.
struct OpenConversationBody: Equatable, Sendable, Encodable {
    let protocolVersion = ProtocolVersion.current
    let externalRef: String
    let agent: String
    let clientInstanceId: String

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case externalRef
        case agent
        case clientInstanceId
    }
}

/// One attachment a submission carries: an identifier the reserve route issued, already sealed.
struct SubmissionAttachmentRef: Equatable, Sendable, Encodable {
    let attachmentId: String
    let kind: String

    init(attachmentId: String, kind: String = "image") {
        self.attachmentId = attachmentId
        self.kind = kind
    }
}

/// `POST /v1/conversations/{id}/submissions`
///
/// `attachments` is absent rather than sent empty for a message that is only words: the server
/// reads the two the same, and a text-only body then stays byte for byte what it always was.
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
    /// `nil` for a message with nothing attached, which leaves the key out of the body.
    var attachments: [SubmissionAttachmentRef]?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case type
        case submissionId
        case idempotencyKey
        case text
        case attachments
    }
}

/// `POST /v1/conversations/{id}:cancel`
struct CancelBody: Equatable, Sendable, Encodable {
    /// `current` stops the turn that is running. `all` also drops what is queued behind it.
    enum Scope: String, Equatable, Sendable, Encodable {
        case current
        case all
    }

    let protocolVersion = ProtocolVersion.current
    let scope: Scope

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case scope
    }
}

/// `POST /v1/conversations/{id}/attachments` — reserves a slot before any byte moves.
///
/// Every field is a claim about bytes the server has not seen yet. It records the size and the
/// digest, and refuses the upload if what arrives does not match them.
struct ReserveAttachmentBody: Equatable, Sendable, Encodable {
    let protocolVersion = ProtocolVersion.current
    let kind: String
    let contentType: String
    let byteSize: Int
    /// 64 lowercase hex characters.
    let sha256: String
    /// A label. Never a path.
    let fileName: String

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case kind
        case contentType
        case byteSize
        case sha256
        case fileName
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

/// `POST /api/auth/token` on the orchestrator: what `AccessTokenHolder` keeps in memory.
///
/// Not a chat-protocol body — the orchestrator owns sign-in and its answers carry no `protocol`
/// field — but kept here with the token's other shapes. `protocolVersion` stays optional so a
/// test double can still say which build it imitates.
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

    /// The values the contract documents, used until `GET /v1/session` has answered and when it
    /// does not: a failed read of the limits is no reason to keep a person from chatting.
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

/// `GET /v1/session`: who the chat service takes this phone to be, and the limits it enforces.
struct SessionResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let principalId: String
    let limits: SessionLimits

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case principalId
        case limits
    }

    init(
        principalId: String,
        limits: SessionLimits,
        protocolVersion: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.principalId = principalId
        self.limits = limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion)
        principalId = try container.decode(String.self, forKey: .principalId)
        limits = try container.decodeIfPresent(SessionLimits.self, forKey: .limits)
            ?? SessionLimits.documentedDefaults
    }
}

struct OpenConversationResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let conversationId: String
    /// The agent the conversation is with, as the server recorded it.
    let agent: String?
    /// Where live begins. The stream's attach floor is derived from this and nothing else.
    let nextSeq: Int
    /// The oldest seq still retained. Below it, history is gone.
    let retainedFloorSeq: Int

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case conversationId
        case agent
        case nextSeq
        case retainedFloorSeq
    }

    init(
        conversationId: String,
        agent: String? = nil,
        nextSeq: Int,
        retainedFloorSeq: Int,
        protocolVersion: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.conversationId = conversationId
        self.agent = agent
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

/// `POST /v1/conversations/{id}:cancel` answered: the request was taken, and nothing more. Whether
/// anything was running arrives later as a `control.ack` event.
struct CancelAcceptedResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
    }

    init(protocolVersion: String? = nil) {
        self.protocolVersion = protocolVersion
    }
}

/// A reserved attachment slot.
///
/// `uploadToken` exists only in this answer: the server keeps its digest and nothing else. It is
/// used once, for the upload, and never stored. The answer also names an upload address; this
/// client builds that address itself from `attachmentId`, so nothing the answer says can send
/// the bytes or the token anywhere but the server it came from.
struct ReserveAttachmentResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let attachmentId: String
    let uploadToken: String
    let maxBytes: Int?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case attachmentId
        case uploadToken
        case maxBytes
    }

    init(
        attachmentId: String,
        uploadToken: String,
        maxBytes: Int? = nil,
        protocolVersion: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.attachmentId = attachmentId
        self.uploadToken = uploadToken
        self.maxBytes = maxBytes
    }
}

/// `PUT /v1/attachments/{attachmentId}/content` answered: the bytes matched what was reserved,
/// and the attachment can now be named by a submission.
struct SealedAttachmentResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let attachmentId: String

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case attachmentId
    }

    init(attachmentId: String, protocolVersion: String? = nil) {
        self.protocolVersion = protocolVersion
        self.attachmentId = attachmentId
    }
}

/// One of the caller's conversations, as `GET /v1/conversations` lists it.
struct ConversationSummary: Equatable, Sendable, Decodable {
    let conversationId: String
    let agent: String
    let externalRef: String
    /// The position the next event will take. One less is the newest there is.
    let nextSeq: Int
    let lastActivityAt: Date?

    private enum CodingKeys: String, CodingKey {
        case conversationId, agent, externalRef, nextSeq, lastActivityAt
    }

    init(
        conversationId: String,
        agent: String,
        externalRef: String,
        nextSeq: Int,
        lastActivityAt: Date? = nil
    ) {
        self.conversationId = conversationId
        self.agent = agent
        self.externalRef = externalRef
        self.nextSeq = nextSeq
        self.lastActivityAt = lastActivityAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            conversationId: try container.decode(String.self, forKey: .conversationId),
            agent: try container.decode(String.self, forKey: .agent),
            externalRef: try container.decode(String.self, forKey: .externalRef),
            nextSeq: (try? container.decodeIfPresent(Int.self, forKey: .nextSeq)) ?? 0,
            lastActivityAt: (try? container.decodeIfPresent(String.self, forKey: .lastActivityAt))
                .flatMap(ControlTimestamp.parse)
        )
    }
}

/// `GET /v1/conversations`: the caller's own conversations, most recently active first.
struct ConversationListResponse: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let conversations: [ConversationSummary]

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case conversations
    }

    init(conversations: [ConversationSummary], protocolVersion: String? = nil) {
        self.protocolVersion = protocolVersion
        self.conversations = conversations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion)
        conversations = (try? container.decodeIfPresent(
            LossyList<ConversationSummary>.self,
            forKey: .conversations
        ))?.items ?? []
    }
}
