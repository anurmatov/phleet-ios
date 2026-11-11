import Foundation

/// What one log connection publishes.
enum AgentLogEvent: Equatable, Sendable {
    /// One frame of log text. May hold several lines.
    case text(String)
    /// The connection ended, or never opened. Terminates the sequence.
    case ended
}

/// An agent's container log, as a sequence.
///
/// The orchestrator replays the last couple of hundred lines and then follows the log for as
/// long as the socket stays open.
protocol AgentLogStream {
    func log(_ connection: ControlConnection, agentName: String) -> AsyncStream<AgentLogEvent>
}

/// The `URLSessionWebSocketTask` implementation. Receive-only, like the fleet socket.
final class URLSessionAgentLogStream: AgentLogStream {

    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func log(_ connection: ControlConnection, agentName: String) -> AsyncStream<AgentLogEvent> {
        AsyncStream { continuation in
            guard let request = Self.upgradeRequest(connection, agentName: agentName) else {
                continuation.yield(.ended)
                continuation.finish()
                return
            }

            let socket = SocketBox(task: session.webSocketTask(with: request))
            let pump = Task {
                await Self.pump(task: socket.task, continuation: continuation)
            }

            continuation.onTermination = { _ in
                pump.cancel()
                socket.task.cancel(with: .goingAway, reason: nil)
            }

            socket.task.resume()
        }
    }

    /// Built as a read: the service token, and not the operator token. The orchestrator asks
    /// for no token on a socket.
    static func upgradeRequest(_ connection: ControlConnection, agentName: String) -> URLRequest? {
        guard
            var request = try? ControlRequest.make(
                connection: connection,
                method: "GET",
                percentEncodedPath: ControlRequest.agentLogsPath(agentName: agentName)
            ),
            let target = request.url,
            var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
        else { return nil }

        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        guard let socketURL = components.url else { return nil }
        request.url = socketURL
        return request
    }

    /// `URLSessionWebSocketTask` is callable from any thread and is not annotated `Sendable`.
    private final class SocketBox: @unchecked Sendable {
        let task: URLSessionWebSocketTask
        init(task: URLSessionWebSocketTask) { self.task = task }
    }

    private static func pump(
        task: URLSessionWebSocketTask,
        continuation: AsyncStream<AgentLogEvent>.Continuation
    ) async {
        while !Task.isCancelled {
            do {
                switch try await task.receive() {
                case .string(let value):
                    continuation.yield(.text(value))
                case .data(let data):
                    continuation.yield(.text(String(decoding: data, as: UTF8.self)))
                @unknown default:
                    break
                }
            } catch {
                continuation.yield(.ended)
                continuation.finish()
                return
            }
        }
        continuation.finish()
    }
}

/// The tail of a log: the newest lines, up to a fixed count.
///
/// A log is unbounded and a phone's memory is not. Older lines fall off the front; the count of
/// lines dropped is kept so the screen can say the top is not the beginning.
struct LogTail: Equatable, Sendable {

    static let defaultCapacity = 500

    let capacity: Int
    private(set) var lines: [Line] = []
    private(set) var droppedCount = 0
    private var nextNumber = 1

    struct Line: Equatable, Sendable, Identifiable {
        /// Position in everything received, so identity survives lines falling off the front.
        let number: Int
        let text: String
        var id: Int { number }
    }

    init(capacity: Int = LogTail.defaultCapacity) {
        self.capacity = max(capacity, 1)
    }

    /// Appends one frame, split into lines. A trailing newline does not add an empty line.
    mutating func append(_ frame: String) {
        var parts = frame.components(separatedBy: "\n")
        if parts.last == "" {
            parts.removeLast()
        }
        for part in parts {
            // A carriage return left over from CRLF would render as a stray glyph.
            let text = part.hasSuffix("\r") ? String(part.dropLast()) : part
            lines.append(Line(number: nextNumber, text: text))
            nextNumber += 1
        }
        if lines.count > capacity {
            let overflow = lines.count - capacity
            lines.removeFirst(overflow)
            droppedCount += overflow
        }
    }

    mutating func removeAll() {
        lines.removeAll()
        droppedCount = 0
        nextNumber = 1
    }
}
