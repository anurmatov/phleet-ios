import XCTest
@testable import Phleet

/// The HTTPS double under concurrent callers.
///
/// A test double is not usually worth testing. This one earned it: its route methods run on pool
/// threads, the rendering suite starts several connection loops against a single instance, and
/// unguarded appends from two of them corrupted the heap. The process then died with a
/// segmentation fault a suite later, and the run reported a failure in a test that had done
/// nothing wrong.
///
/// These tests call one instance from many tasks at once. Without the lock they lose records or
/// crash outright; either way the run goes red here, in the test that names the cause.
final class FakeFleetAPIConcurrencyTests: XCTestCase {

    private static let callers = 400

    func testEveryConcurrentCallIsRecordedExactlyOnce() async throws {
        let api = FakeFleetAPI()
        let origin = try XCTUnwrap(URL(string: "https://server.invalid"))

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<Self.callers {
                group.addTask {
                    _ = try? await api.openConversation(
                        origin: origin,
                        accessToken: "token-\(index)",
                        externalRef: "ref-\(index)",
                        agent: "agent-1",
                        clientInstanceId: "instance"
                    )
                }
            }
        }

        XCTAssertEqual(api.calls.count, Self.callers)
        XCTAssertEqual(Set(api.accessTokensPresented).count, Self.callers)
    }

    func testAScriptedQueueIsConsumedOncePerCallerAndThenRepeatsItsLastResult() async throws {
        let api = FakeFleetAPI()
        let origin = try XCTUnwrap(URL(string: "https://server.invalid"))
        // Three distinct answers, then the last one forever.
        api.mintResults = (1...3).map { index in
            .success(MintTokenResponse(
                accessToken: "token-\(index)",
                expiresInSeconds: 900,
                protocolVersion: ProtocolVersion.current
            ))
        }

        let tokens = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for _ in 0..<Self.callers {
                group.addTask {
                    try? await api.mintToken(
                        origin: origin,
                        deviceId: "device",
                        deviceSecret: "secret"
                    ).accessToken
                }
            }
            var collected: [String] = []
            for await token in group {
                if let token { collected.append(token) }
            }
            return collected
        }

        XCTAssertEqual(tokens.count, Self.callers)
        XCTAssertEqual(tokens.filter { $0 == "token-1" }.count, 1, "the first result is handed out once")
        XCTAssertEqual(tokens.filter { $0 == "token-2" }.count, 1, "the second result is handed out once")
        XCTAssertEqual(tokens.filter { $0 == "token-3" }.count, Self.callers - 2)
        XCTAssertEqual(api.mintCallCount, Self.callers)
    }
}
