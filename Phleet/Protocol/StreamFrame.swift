import Foundation

/// The first frame on every stream, sent before any event.
struct HelloFrame: Equatable, Sendable, Decodable {
    let protocolVersion: String?
    let conversationId: String?
    let nextSeq: Int?
    let retainedFloorSeq: Int?
    let limits: SessionLimits?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case conversationId
        case nextSeq
        case retainedFloorSeq
        case limits
    }

    init(
        conversationId: String?,
        nextSeq: Int?,
        retainedFloorSeq: Int?,
        limits: SessionLimits? = nil,
        protocolVersion: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.conversationId = conversationId
        self.nextSeq = nextSeq
        self.retainedFloorSeq = retainedFloorSeq
        self.limits = limits
    }
}

/// What arrives on the socket.
///
/// There are three shapes and **one** discriminator: the top-level `kind` field. `hello` and
/// `ping` are control frames; **every other value is a bare event envelope** whose `kind` is the
/// event's own kind. There is no `event` wrapper object and no `type` field — a client written
/// against the prose documentation's `type` fails to decode the first frame it ever receives.
enum StreamFrame: Equatable, Sendable {
    case hello(HelloFrame)
    case ping
    case event(ConversationEvent)

    /// The only client→server frame this app ever sends.
    ///
    /// Anything else cancels the connection server-side, which then surfaces as a `4409` —
    /// reading as a supersede that never happened. Submissions, steers, cancels and cursor
    /// advances are HTTPS only.
    static let pongFrameText = #"{"kind":"pong"}"#

    private struct Discriminator: Decodable {
        let kind: String
    }

    /// Decodes one frame, discriminating on `kind`.
    static func decode(from data: Data) throws -> StreamFrame {
        let decoder = JSONDecoder()
        let kind = try decoder.decode(Discriminator.self, from: data).kind

        switch kind {
        case "hello":
            return .hello(try decoder.decode(HelloFrame.self, from: data))
        case "ping":
            return .ping
        default:
            return .event(try decoder.decode(ConversationEvent.self, from: data))
        }
    }

    /// Decodes one frame from a text frame's payload.
    static func decode(text: String) throws -> StreamFrame {
        guard let data = text.data(using: .utf8) else {
            throw StreamFrameError.undecodableText
        }
        return try decode(from: data)
    }
}

enum StreamFrameError: Error, Equatable {
    /// A text frame that is not UTF-8. Dropped and logged, never a reason to tear the
    /// connection down.
    case undecodableText
}
