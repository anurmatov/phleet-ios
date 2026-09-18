import Foundation
@testable import Phleet

/// A scripted HTTPS double.
///
/// Records every call in order, so request *ordering* — the thing the attach sequence is built
/// around — is assertable without a network. Every test in this suite is hermetic: nothing here
/// opens a socket, and the suite passes with the runner offline.
final class FakeFleetAPI: FleetAPIClient {

    enum Call: Equatable {
        case registerDevice(code: String)
        case mintToken(deviceId: String, deviceSecret: String)
        case session
        case openConversation(externalRef: String, clientInstanceId: String)
        case catchUp(conversationId: String, afterSeq: Int, limit: Int)
        case submit(
            conversationId: String,
            submissionId: String,
            idempotencyKey: String,
            text: String
        )
        case cursor(conversationId: String, deliveredSeq: Int, readSeq: Int?)
    }

    private(set) var calls: [Call] = []
    private(set) var accessTokensPresented: [String] = []

    /// Runs when a catch-up request is made, before its result is produced. Lets a test act in
    /// the middle of the attach sequence.
    var onCatchUp: ((Int) -> Void)?

    /// How many times a catch-up suspends before answering.
    ///
    /// A catch-up that returns without ever suspending completes before the frame loop reads its
    /// next frame, so live frames are applied directly and the buffer is never exercised. A test
    /// that needs frames to *queue* during catch-up sets this.
    var catchUpSuspensions = 0

    var registerResults: [Result<RegisterDeviceResponse, Error>] = [
        .success(RegisterDeviceResponse(
            deviceId: "device-1",
            deviceSecret: "secret-1",
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var mintResults: [Result<MintTokenResponse, Error>] = [
        .success(MintTokenResponse(
            accessToken: "token-1",
            expiresInSeconds: 900,
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var sessionResults: [Result<SessionResponse, Error>] = [
        .success(SessionResponse(
            principalId: "principal-1",
            agentLabel: "Agent",
            limits: .documentedDefaults,
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var openResults: [Result<OpenConversationResponse, Error>] = [
        .success(OpenConversationResponse(
            conversationId: "conversation-1",
            nextSeq: 41,
            retainedFloorSeq: 12,
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var catchUpResults: [Result<CatchUpResponse, Error>] = [
        .success(CatchUpResponse(
            events: [],
            nextAfterSeq: 0,
            hasMore: false,
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var submitResults: [Result<SubmissionAcceptedResponse, Error>] = [
        .success(SubmissionAcceptedResponse(
            submissionId: "submission-1",
            acceptedSeq: 41,
            protocolVersion: ProtocolVersion.current
        ))
    ]
    var cursorResults: [Result<CursorAcceptedResponse, Error>] = [
        .success(CursorAcceptedResponse(protocolVersion: ProtocolVersion.current))
    ]

    // MARK: - Convenience readers

    var catchUpCursors: [Int] {
        calls.compactMap {
            if case .catchUp(_, let afterSeq, _) = $0 { return afterSeq }
            return nil
        }
    }

    var catchUpLimits: [Int] {
        calls.compactMap {
            if case .catchUp(_, _, let limit) = $0 { return limit }
            return nil
        }
    }

    var submissions: [(submissionId: String, idempotencyKey: String, text: String)] {
        calls.compactMap {
            if case .submit(_, let submissionId, let key, let text) = $0 {
                return (submissionId, key, text)
            }
            return nil
        }
    }

    var mintCallCount: Int {
        calls.filter { if case .mintToken = $0 { return true } else { return false } }.count
    }

    // MARK: - FleetAPIClient

    func registerDevice(
        origin: URL,
        enrollmentCode: String
    ) async throws -> RegisterDeviceResponse {
        calls.append(.registerDevice(code: enrollmentCode))
        return try Self.next(&registerResults)
    }

    func mintToken(
        origin: URL,
        deviceId: String,
        deviceSecret: String
    ) async throws -> MintTokenResponse {
        calls.append(.mintToken(deviceId: deviceId, deviceSecret: deviceSecret))
        return try Self.next(&mintResults)
    }

    func session(origin: URL, accessToken: String) async throws -> SessionResponse {
        calls.append(.session)
        accessTokensPresented.append(accessToken)
        return try Self.next(&sessionResults)
    }

    func openConversation(
        origin: URL,
        accessToken: String,
        externalRef: String,
        clientInstanceId: String
    ) async throws -> OpenConversationResponse {
        calls.append(
            .openConversation(externalRef: externalRef, clientInstanceId: clientInstanceId)
        )
        accessTokensPresented.append(accessToken)
        return try Self.next(&openResults)
    }

    func catchUp(
        origin: URL,
        accessToken: String,
        conversationId: String,
        afterSeq: Int,
        limit: Int
    ) async throws -> CatchUpResponse {
        calls.append(
            .catchUp(conversationId: conversationId, afterSeq: afterSeq, limit: limit)
        )
        accessTokensPresented.append(accessToken)
        onCatchUp?(afterSeq)
        for _ in 0..<catchUpSuspensions {
            await Task.yield()
        }
        return try Self.next(&catchUpResults)
    }

    func submit(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: SubmissionBody
    ) async throws -> SubmissionAcceptedResponse {
        calls.append(
            .submit(
                conversationId: conversationId,
                submissionId: body.submissionId,
                idempotencyKey: body.idempotencyKey,
                text: body.text
            )
        )
        accessTokensPresented.append(accessToken)
        return try Self.next(&submitResults)
    }

    func advanceCursor(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: CursorBody
    ) async throws -> CursorAcceptedResponse {
        calls.append(
            .cursor(
                conversationId: conversationId,
                deliveredSeq: body.deliveredSeq,
                readSeq: body.readSeq
            )
        )
        accessTokensPresented.append(accessToken)
        return try Self.next(&cursorResults)
    }

    /// Consumes the next scripted result, repeating the last one forever.
    private static func next<T>(_ queue: inout [Result<T, Error>]) throws -> T {
        guard let first = queue.first else {
            throw FleetAPIError.transport("no scripted result")
        }
        if queue.count > 1 {
            queue.removeFirst()
        }
        return try first.get()
    }
}

/// A monotonic clock a test drives by hand.
final class TestClock: MonotonicClock {
    var uptimeSeconds: Double = 0

    func advance(_ seconds: Double) {
        uptimeSeconds += seconds
    }
}
