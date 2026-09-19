import Foundation

/// The `URLSessionWebSocketTask` implementation of the stream.
///
/// The socket is **receive-mostly**: the only thing this client ever sends over it is
/// `{"kind":"pong"}`. Submissions, steers, cancels and cursor advances are HTTPS, so there is
/// one mutation path and one set of idempotency semantics — and an unrecognised client frame
/// cancels the connection server-side, which then closes as `4409` and reads as a supersede that
/// never happened.
final class URLSessionConversationStream: ConversationStream {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func frames(
        origin: URL,
        accessToken: String,
        conversationId: String,
        clientInstanceId: String,
        afterSeq: Int
    ) -> AsyncStream<ConversationStreamEvent> {
        AsyncStream { continuation in
            guard
                let target = Self.streamURL(
                    origin: origin,
                    conversationId: conversationId,
                    clientInstanceId: clientInstanceId,
                    afterSeq: afterSeq
                )
            else {
                continuation.yield(.failed("malformed stream URL"))
                continuation.finish()
                return
            }

            var request = URLRequest(url: target)
            // Header only. The token appears in no query, path or fragment anywhere in this app.
            request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")

            let socket = SocketBox(task: session.webSocketTask(with: request))
            let pump = Task {
                await Self.pump(task: socket.task, continuation: continuation)
            }

            // `onTermination` is `@Sendable`, and `URLSessionWebSocketTask` is documented as
            // callable from any thread but is not annotated as `Sendable`. The box states that
            // narrowly and in one place, rather than leaving the socket un-cancelled when a
            // consumer stops iterating.
            continuation.onTermination = { _ in
                pump.cancel()
                socket.task.cancel(with: .goingAway, reason: nil)
            }

            socket.task.resume()
        }
    }

    /// Builds the upgrade URL.
    ///
    /// `clientInstanceId` is a **required** query parameter, validated before anything else; an
    /// absent or invalid one fails the upgrade. `afterSeq` is the live-tail floor — see
    /// `StreamAttachFloor` for why it is never a history cursor.
    static func streamURL(
        origin: URL,
        conversationId: String,
        clientInstanceId: String,
        afterSeq: Int
    ) -> URL? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }

        var base = components.path
        if base.hasSuffix("/") {
            base.removeLast()
        }
        components.path = base + "/v1/conversations/" + conversationId + "/stream"
        components.queryItems = [
            URLQueryItem(name: "clientInstanceId", value: clientInstanceId),
            URLQueryItem(name: "afterSeq", value: String(afterSeq))
        ]
        return components.url
    }

    /// See the note at the call site.
    private final class SocketBox: @unchecked Sendable {
        let task: URLSessionWebSocketTask
        init(task: URLSessionWebSocketTask) { self.task = task }
    }

    private static func pump(
        task: URLSessionWebSocketTask,
        continuation: AsyncStream<ConversationStreamEvent>.Continuation
    ) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let text: String?
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    text = String(data: data, encoding: .utf8)
                @unknown default:
                    text = nil
                }

                guard let text else {
                    continuation.yield(.undecodableFrame("non-text frame"))
                    continue
                }

                do {
                    switch try StreamFrame.decode(text: text) {
                    case .hello(let hello):
                        continuation.yield(.hello(hello))
                    case .ping:
                        // Answered here, never surfaced: nothing above this seam needs to know
                        // liveness exists.
                        try? await task.send(.string(StreamFrame.pongFrameText))
                    case .event(let event):
                        continuation.yield(.event(event))
                    }
                } catch {
                    // Dropped and reported, never a teardown. A frame whose `kind` is unknown is
                    // not even this case — it decodes as an ordinary forward-compatible event.
                    continuation.yield(.undecodableFrame("undecodable frame"))
                }
            } catch {
                let code = task.closeCode.rawValue
                if code != 0 {
                    let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
                    continuation.yield(.closed(code: code, reason: reason))
                } else {
                    continuation.yield(.failed("stream ended"))
                }
                continuation.finish()
                return
            }
        }
        continuation.finish()
    }
}
