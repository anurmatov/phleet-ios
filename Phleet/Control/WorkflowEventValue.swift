import Foundation

/// A stored field of one history event that can be read in full.
///
/// The raw value is the orchestrator's `field` query value.
enum EventValueField: String, CaseIterable, Hashable, Sendable {
    case input
    case output
    case failure
}

/// One field of one event of one exact run.
///
/// Every part is required, and none of them is ever guessed: the same workflow identifier and
/// the same event number recur across runs and namespaces, so a read that dropped the run would
/// show another execution's text under this one's row.
struct EventValueRequest: Hashable, Sendable {
    let namespace: String
    let workflowId: String
    let runId: String
    let eventId: Int
    let field: EventValueField

    init(run: WorkflowRun, event: WorkflowEvent, field: EventValueField) {
        self.init(
            namespace: run.namespace,
            workflowId: run.workflowId,
            runId: run.runId,
            eventId: event.eventId,
            field: field
        )
    }

    init(namespace: String, workflowId: String, runId: String, eventId: Int, field: EventValueField) {
        self.namespace = namespace
        self.workflowId = workflowId
        self.runId = runId
        self.eventId = eventId
        self.field = field
    }

    /// The fields the server reads for an event of this kind, as the history names the kind.
    ///
    /// The contract's field mapping, and nothing more: a cancelled workflow has no value to read
    /// and an event this build does not recognise is not offered. Offered whether or not the
    /// history preview has text, because the preview leaves out values it cannot show — plain
    /// text among them — and the complete read is what says what is there.
    static func fields(for event: WorkflowEvent) -> [EventValueField] {
        switch event.eventType {
        case "WorkflowStarted", "ActivityScheduled", "SignalReceived": return [.input]
        case "WorkflowCompleted": return [.output]
        case "ActivityCompleted": return [.input, .output]
        case "WorkflowFailed", "ActivityFailed": return [.failure]
        default: return []
        }
    }
}

extension WorkflowEvent {

    /// The history's own short preview of one field. A preview, never the value: the history
    /// cuts long text and joins several payloads into one.
    func preview(of field: EventValueField) -> String? {
        switch field {
        case .input: return inputSummary
        case .output: return outputSummary
        case .failure: return failureMessage
        }
    }
}

/// One stored payload as text: exactly what the server decoded, in the order it was stored.
struct EventPayloadText: Equatable, Sendable {
    /// The payload's encoding, as stored: `json/plain`, `json/protobuf` or `text/plain`.
    let encoding: String
    /// Never parsed, unquoted, reformatted or normalised on the way here.
    let text: String

    /// Whether the encoding says the text is JSON. Text that merely looks like JSON is not.
    var isJSONEncoded: Bool {
        encoding == "json/plain" || encoding == "json/protobuf"
    }
}

/// Why the server read a field and gave no text for it.
enum EventValueUnsupportedReason: String, Equatable, Sendable {
    /// Binary, compressed, encrypted, missing or unknown encoding.
    case encoding
    case invalidUTF8 = "invalid_utf8"
    /// The server does not read values for this kind of event.
    case eventType = "event_type"
    /// The failure's attributes are encoded, so its message is not available as text.
    case encodedFailure = "encoded_failure"
}

/// What the server answered for one requested field, once checked against the request.
enum EventValueResult: Equatable, Sendable {
    /// Every value of the field, whole. A completed activity's input is read from the event
    /// that scheduled it, which is the source here.
    case complete(values: [EventPayloadText], sourceEventId: Int)
    /// The event has no such value. Different from a value that is empty text.
    case absent
    case unsupported(EventValueUnsupportedReason)
    /// More than the server sends. Nothing is sent, not even a prefix.
    case tooLarge(limitBytes: Int)
}

/// Why an answer was refused although it decoded.
enum EventValueAnswerError: Error, Equatable, Sendable {
    /// It names a different namespace, workflow, run, event or field than was asked for.
    case identityMismatch
    /// Its status, values, reason and source do not agree with each other.
    case inconsistent
    /// A status or reason this build does not know.
    case unrecognized
}

/// The orchestrator's answer to `GET /api/workflows/{ns}/event-value/{workflowId}`, as it arrives.
struct EventValueEnvelope: Decodable, Equatable, Sendable {

    struct Value: Decodable, Equatable, Sendable {
        let encoding: String
        let text: String
    }

    let namespace: String
    let workflowId: String
    let runId: String
    let eventId: Int
    let field: String
    let sourceEventId: Int?
    let status: String
    let values: [Value]
    let reason: String?
    let limitBytes: Int

    /// Checks the answer against what was asked and against itself.
    ///
    /// Identity is compared scalar by scalar: Swift's `==` treats canonically equivalent strings
    /// as equal, and two identifiers that differ only in normalisation are two identifiers.
    /// An answer that fails any check is refused whole; nothing from it is shown.
    func checked(against request: EventValueRequest) throws -> EventValueResult {
        guard
            Self.identical(namespace, request.namespace),
            Self.identical(workflowId, request.workflowId),
            Self.identical(runId, request.runId),
            eventId == request.eventId,
            field == request.field.rawValue
        else { throw EventValueAnswerError.identityMismatch }

        guard limitBytes > 0 else { throw EventValueAnswerError.inconsistent }

        switch status {
        case "complete":
            guard
                !values.isEmpty,
                reason == nil,
                let sourceEventId,
                sourceEventId > 0,
                sourceEventId <= eventId,
                values.reduce(0, { $0 + $1.text.utf8.count }) <= limitBytes
            else { throw EventValueAnswerError.inconsistent }
            return .complete(
                values: values.map { EventPayloadText(encoding: $0.encoding, text: $0.text) },
                sourceEventId: sourceEventId
            )

        case "absent":
            try requireNoValue()
            guard let reason else { throw EventValueAnswerError.inconsistent }
            guard reason == "no_value" else { throw EventValueAnswerError.unrecognized }
            return .absent

        case "unsupported":
            try requireNoValue()
            guard let reason else { throw EventValueAnswerError.inconsistent }
            guard let known = EventValueUnsupportedReason(rawValue: reason) else {
                throw EventValueAnswerError.unrecognized
            }
            return .unsupported(known)

        case "too_large":
            try requireNoValue()
            guard let reason else { throw EventValueAnswerError.inconsistent }
            guard reason == "value_size" else { throw EventValueAnswerError.unrecognized }
            return .tooLarge(limitBytes: limitBytes)

        default:
            throw EventValueAnswerError.unrecognized
        }
    }

    /// Every status but `complete` carries no values and no source.
    private func requireNoValue() throws {
        guard values.isEmpty, sourceEventId == nil else {
            throw EventValueAnswerError.inconsistent
        }
    }

    static func identical(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }
}
