import Foundation

/// One message from the orchestrator's live socket.
///
/// The socket carries two shapes and tells them apart by one field: a workflow list arrives in an
/// envelope with `type: "workflows"`, and an agent's state arrives bare, with no `type` at all.
enum ControlLiveFrame: Equatable, Sendable {
    case agent(FleetAgent)
    case workflows([WorkflowRun])

    private struct Probe: Decodable {
        let type: String?
    }

    private struct WorkflowsEnvelope: Decodable {
        let data: LossyList<WorkflowRun>
    }

    /// Reads one text frame.
    ///
    /// Returns `nil` for an envelope whose `type` this build does not know: that is a newer
    /// orchestrator saying something new, and it is skipped rather than treated as damage.
    static func decode(text: String) throws -> ControlLiveFrame? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()

        let probe = try decoder.decode(Probe.self, from: data)
        switch probe.type {
        case nil:
            return .agent(try decoder.decode(FleetAgent.self, from: data))
        case "workflows"?:
            return .workflows(try decoder.decode(WorkflowsEnvelope.self, from: data).data.items)
        default:
            return nil
        }
    }
}

/// What one live connection publishes.
enum ControlLiveEvent: Equatable, Sendable {
    case frame(ControlLiveFrame)
    /// A frame arrived and could not be read. Dropped; never a reason to tear the socket down.
    case undecodableFrame
    /// The connection ended, or never opened. Terminates the sequence.
    case ended
}

/// The orchestrator's live socket, expressed as a sequence.
///
/// The seam the tests drive. The control plane does not depend on it for correctness: every fact
/// it carries is also read over HTTPS on a timer, so a socket that cannot get through a proxy
/// costs freshness and nothing else.
protocol ControlLiveStream {
    func frames(_ connection: ControlConnection) -> AsyncStream<ControlLiveEvent>
}

/// The `URLSessionWebSocketTask` implementation.
///
/// Receive-only. This client sends nothing over the socket: every change it makes is an HTTPS
/// request, so there is one write path and one place the operator token is attached.
final class URLSessionControlLiveStream: ControlLiveStream {

    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func frames(_ connection: ControlConnection) -> AsyncStream<ControlLiveEvent> {
        AsyncStream { continuation in
            guard let request = Self.upgradeRequest(connection) else {
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

    /// Builds the upgrade request.
    ///
    /// Built as a read, so it carries the service token and **not** the operator token: the
    /// socket only ever delivers state, and the orchestrator does not ask for a token on it.
    static func upgradeRequest(_ connection: ControlConnection) -> URLRequest? {
        guard
            var request = try? ControlRequest.make(
                connection: connection,
                method: "GET",
                percentEncodedPath: "/ws"
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
        continuation: AsyncStream<ControlLiveEvent>.Continuation
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
                    continuation.yield(.undecodableFrame)
                    continue
                }
                do {
                    if let frame = try ControlLiveFrame.decode(text: text) {
                        continuation.yield(.frame(frame))
                    }
                } catch {
                    continuation.yield(.undecodableFrame)
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
