import Foundation

/// Who and what an event belongs to.
///
/// Every field is optional. The envelope's identity is opaque to this client — it correlates on
/// `submissionId` and never derives meaning from any other member — and a required field that
/// the server one day omits would turn a renderable event into a decode failure.
struct EventIdentity: Equatable, Sendable, Decodable {
    let principalId: String?
    let channel: String?
    let conversationId: String?
    let submissionId: String?
    let turnId: String?
    /// 1-based.
    let attempt: Int?

    init(
        principalId: String? = nil,
        channel: String? = nil,
        conversationId: String? = nil,
        submissionId: String? = nil,
        turnId: String? = nil,
        attempt: Int? = nil
    ) {
        self.principalId = principalId
        self.channel = channel
        self.conversationId = conversationId
        self.submissionId = submissionId
        self.turnId = turnId
        self.attempt = attempt
    }
}

/// One event, in the shape it arrives in on both transports.
///
/// A stream frame whose `kind` is not a control frame is this envelope, **bare** — byte
/// identical to the same event inside a catch-up response's `events` array. There is no
/// wrapper object, so there is one decoder and one shape.
struct ConversationEvent: Equatable, Sendable {

    /// The envelope's own `protocol` field, verified rather than assumed.
    let protocolVersion: String?

    /// The dedupe key. Deduping on `seq` would not work: `conversation.replay_gap` carries
    /// `seq: null`.
    let eventId: String

    /// Signed and nullable on the wire.
    let seq: Int?

    let emittedAt: String?
    let kind: EventKind
    let identity: EventIdentity
    let payload: EventPayload

    init(
        eventId: String,
        seq: Int?,
        kind: EventKind,
        identity: EventIdentity = EventIdentity(),
        payload: EventPayload = .none,
        emittedAt: String? = nil,
        protocolVersion: String? = ProtocolVersion.current
    ) {
        self.protocolVersion = protocolVersion
        self.eventId = eventId
        self.seq = seq
        self.emittedAt = emittedAt
        self.kind = kind
        self.identity = identity
        self.payload = payload
    }
}

extension ConversationEvent: Decodable {

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case eventId
        case seq
        case emittedAt
        case kind
        case identity
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion)
        eventId = try container.decode(String.self, forKey: .eventId)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        emittedAt = try container.decodeIfPresent(String.self, forKey: .emittedAt)

        let decodedKind = EventKind(rawValue: try container.decode(String.self, forKey: .kind))
        kind = decodedKind
        identity = try container.decodeIfPresent(EventIdentity.self, forKey: .identity)
            ?? EventIdentity()

        // An absent or non-object payload decodes to `.none` rather than throwing. Several
        // kinds carry no payload at all, and a kind this build has never seen may carry a shape
        // it has never seen either.
        let payloadContainer = try? container.nestedContainer(
            keyedBy: PayloadKey.self,
            forKey: .payload
        )
        payload = EventPayload(kind: decodedKind, container: payloadContainer)
    }

    /// Decodes one envelope from raw bytes.
    static func decode(from data: Data) throws -> ConversationEvent {
        try JSONDecoder().decode(ConversationEvent.self, from: data)
    }
}

// MARK: - Payload decoding

/// A string-keyed `CodingKey` so payload fields can be read by name without a struct per kind
/// that would then need its own tolerant-enum decoding.
private struct PayloadKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private typealias PayloadContainer = KeyedDecodingContainer<PayloadKey>

extension EventPayload {

    fileprivate init(kind: EventKind, container: PayloadContainer?) {
        switch kind {
        case .submissionAccepted:
            self = .submissionAccepted(
                SubmissionAcceptedPayload(
                    disposition: Disposition(
                        rawValue: EventPayload.string(container, "disposition") ?? ""
                    )
                )
            )

        case .turnStarted:
            self = .turnStarted(TurnStartedPayload())

        case .turnProgress:
            self = .turnProgress(
                TurnProgressPayload(
                    activity: ProgressActivity(
                        rawValue: EventPayload.string(container, "activity") ?? ""
                    ),
                    toolName: EventPayload.string(container, "toolName")
                )
            )

        case .turnNotice:
            self = .turnNotice(
                TurnNoticePayload(
                    text: EventPayload.string(container, "text") ?? "",
                    truncated: EventPayload.bool(container, "truncated")
                )
            )

        case .turnRecoveredAnswer:
            self = .turnRecoveredAnswer(
                TurnRecoveredAnswerPayload(
                    text: EventPayload.string(container, "text") ?? "",
                    truncated: EventPayload.bool(container, "truncated")
                )
            )

        case .turnFinal:
            self = .turnFinal(
                TurnFinalPayload(
                    // `completion: "idle"` legitimately carries empty text.
                    text: EventPayload.string(container, "text") ?? "",
                    completion: Completion(
                        rawValue: EventPayload.string(container, "completion") ?? ""
                    ),
                    isPartial: EventPayload.bool(container, "isPartial"),
                    truncated: EventPayload.bool(container, "truncated"),
                    mergedSubmissionIds: EventPayload.strings(container, "mergedSubmissionIds")
                )
            )

        case .turnError:
            self = .turnError(
                TurnErrorPayload(
                    code: EventPayload.string(container, "code") ?? "",
                    message: EventPayload.string(container, "message") ?? ""
                )
            )

        case .turnCanceled:
            self = .turnCanceled(
                TurnCanceledPayload(
                    reason: CancelReason(rawValue: EventPayload.string(container, "reason") ?? ""),
                    mergedSubmissionIds: EventPayload.strings(container, "mergedSubmissionIds")
                )
            )

        case .turnOutcomeUnknown:
            self = .turnOutcomeUnknown(
                TurnOutcomeUnknownPayload(
                    reason: OutcomeUnknownReason(
                        rawValue: EventPayload.string(container, "reason") ?? ""
                    )
                )
            )

        case .controlAck:
            self = .controlAck(
                ControlAckPayload(
                    target: EventPayload.string(container, "target"),
                    accepted: EventPayload.bool(container, "accepted"),
                    hadRunningTask: EventPayload.bool(container, "hadRunningTask")
                )
            )

        case .protocolRejected:
            self = .protocolRejected(
                ProtocolRejectedPayload(
                    code: EventPayload.string(container, "code") ?? "",
                    message: EventPayload.string(container, "message")
                )
            )

        case .conversationReplayGap:
            self = .replayGap(
                ReplayGapPayload(
                    fromSeq: EventPayload.int(container, "fromSeq"),
                    toSeq: EventPayload.int(container, "toSeq"),
                    retainedFloorSeq: EventPayload.int(container, "retainedFloorSeq")
                )
            )

        case .unknown:
            self = .none
        }
    }

    private static func string(_ container: PayloadContainer?, _ name: String) -> String? {
        guard let container, let key = PayloadKey(stringValue: name) else { return nil }
        return try? container.decodeIfPresent(String.self, forKey: key)
    }

    private static func bool(_ container: PayloadContainer?, _ name: String) -> Bool? {
        guard let container, let key = PayloadKey(stringValue: name) else { return nil }
        return try? container.decodeIfPresent(Bool.self, forKey: key)
    }

    private static func int(_ container: PayloadContainer?, _ name: String) -> Int? {
        guard let container, let key = PayloadKey(stringValue: name) else { return nil }
        return try? container.decodeIfPresent(Int.self, forKey: key)
    }

    private static func strings(_ container: PayloadContainer?, _ name: String) -> [String] {
        guard let container, let key = PayloadKey(stringValue: name) else { return [] }
        return (try? container.decodeIfPresent([String].self, forKey: key)) ?? []
    }
}
