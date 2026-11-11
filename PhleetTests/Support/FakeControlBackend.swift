import Foundation
@testable import Phleet

/// A scripted orchestrator.
///
/// Records every call in order and answers from values a test sets. Nothing here opens a socket.
final class FakeControlAPI: ControlAPIClient {

    enum Call: Equatable {
        case agents
        case workflows
        case signalRegistry
        case sendSignal(namespace: String, workflowId: String, body: SignalRequestBody)
    }

    private(set) var calls: [Call] = []
    private(set) var connections: [ControlConnection] = []

    var agentsResult: Result<[FleetAgent], Error> = .success([])
    var workflowsResult: Result<[WorkflowRun], Error> = .success([])
    var registryResult: Result<[String: [SignalDefinition]], Error> = .success([:])
    var signalResult: Result<Void, Error> = .success(())

    /// Runs when a signal is sent, before its result is produced. Lets a test change what the
    /// next read returns, the way a real decision moves a workflow out of its phase.
    var onSendSignal: (() -> Void)?

    var sentSignals: [SignalRequestBody] {
        calls.compactMap {
            if case .sendSignal(_, _, let body) = $0 { return body }
            return nil
        }
    }

    func count(of call: Call) -> Int {
        calls.filter { $0 == call }.count
    }

    func agents(_ connection: ControlConnection) async throws -> [FleetAgent] {
        calls.append(.agents)
        connections.append(connection)
        return try agentsResult.get()
    }

    func workflows(_ connection: ControlConnection) async throws -> [WorkflowRun] {
        calls.append(.workflows)
        connections.append(connection)
        return try workflowsResult.get()
    }

    func signalRegistry(
        _ connection: ControlConnection
    ) async throws -> [String: [SignalDefinition]] {
        calls.append(.signalRegistry)
        connections.append(connection)
        return try registryResult.get()
    }

    func sendSignal(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        body: SignalRequestBody
    ) async throws {
        calls.append(.sendSignal(namespace: namespace, workflowId: workflowId, body: body))
        connections.append(connection)
        onSendSignal?()
        try signalResult.get()
    }
}

/// A scripted live socket. Each attach replays its script and ends.
final class FakeControlLiveStream: ControlLiveStream {

    private(set) var attachCount = 0

    /// One script per attach, consumed in order. The last one repeats.
    var scripts: [[ControlLiveEvent]]

    init(scripts: [[ControlLiveEvent]] = [[.ended]]) {
        self.scripts = scripts
    }

    func frames(_ connection: ControlConnection) -> AsyncStream<ControlLiveEvent> {
        let index = min(attachCount, scripts.count - 1)
        attachCount += 1
        let script = scripts.isEmpty ? [.ended] : scripts[max(index, 0)]

        return AsyncStream { continuation in
            for event in script {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
