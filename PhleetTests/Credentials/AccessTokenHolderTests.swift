import XCTest
@testable import Phleet

/// The token lifecycle, and the one condition that signs out.
@MainActor
final class AccessTokenHolderTests: XCTestCase {

    private let credential = DeviceCredential(
        origin: "https://server.invalid",
        deviceId: "device-1",
        deviceSecret: "secret-1",
        clientInstanceId: "instance-1"
    )

    private func makeHolder(
        store: InMemoryCredentialStore,
        clock: TestClock,
        mint: @escaping (DeviceCredential) async throws -> MintTokenResponse
    ) -> AccessTokenHolder {
        AccessTokenHolder(credentialStore: store, clock: clock, mint: mint)
    }

    private func token(_ value: String, expiresInSeconds: Int = 900) -> MintTokenResponse {
        MintTokenResponse(
            accessToken: value,
            expiresInSeconds: expiresInSeconds,
            protocolVersion: ProtocolVersion.current
        )
    }

    // MARK: - Deadlines

    func testRefreshIsProactiveSixtySecondsBeforeTheDeadline() async throws {
        let store = InMemoryCredentialStore(credential: credential)
        let clock = TestClock()
        var minted = 0

        let holder = makeHolder(store: store, clock: clock) { _ in
            minted += 1
            return self.token("token-\(minted)")
        }

        let first = try await holder.accessToken()
        XCTAssertEqual(first, "token-1")

        // 839 seconds after issue: one second short of the refresh point.
        clock.advance(839)
        let beforeRefreshPoint = try await holder.accessToken()
        XCTAssertEqual(beforeRefreshPoint, "token-1")
        XCTAssertEqual(minted, 1)

        clock.advance(1)
        let afterRefreshPoint = try await holder.accessToken()
        XCTAssertEqual(afterRefreshPoint, "token-2")
        XCTAssertEqual(minted, 2)
    }

    func testABackwardWallClockJumpDoesNotExtendTheDeadline() async throws {
        let store = InMemoryCredentialStore(credential: credential)
        let clock = TestClock()
        var minted = 0

        let holder = makeHolder(store: store, clock: clock) { _ in
            minted += 1
            return self.token("token-\(minted)")
        }
        _ = try await holder.accessToken()

        // The wall clock is deliberately not consulted anywhere in the holder, so moving it back
        // an hour is invisible to it: only the monotonic clock advances the deadline.
        clock.advance(840)
        let refreshed = try await holder.accessToken()
        XCTAssertEqual(refreshed, "token-2")
        XCTAssertEqual(minted, 2, "the deadline is measured on the monotonic clock alone")
    }

    // MARK: - Single flight

    func testThreeConcurrentCallersProduceExactlyOneMint() async throws {
        let store = InMemoryCredentialStore(credential: credential)
        let clock = TestClock()
        var minted = 0

        let holder = makeHolder(store: store, clock: clock) { _ in
            minted += 1
            // A real mint suspends; without that there is no window for the second and third
            // callers to arrive, and the test would pass with no single-flight at all.
            await Task.yield()
            return self.token("token-\(minted)")
        }

        async let first = holder.accessToken()
        async let second = holder.accessToken()
        async let third = holder.accessToken()
        let tokens = try await [first, second, third]

        XCTAssertEqual(minted, 1)
        XCTAssertEqual(Set(tokens), ["token-1"])
        XCTAssertEqual(holder.mintCount, 1)
    }

    // MARK: - 401 handling

    func testA401OnAnOrdinaryRouteMintsOnceAndReplaysOnce() async throws {
        let store = InMemoryCredentialStore(credential: credential)
        let clock = TestClock()
        var minted = 0
        var attempts = 0

        let holder = makeHolder(store: store, clock: clock) { _ in
            minted += 1
            return self.token("token-\(minted)")
        }

        let result = try await holder.authorized { token -> String in
            attempts += 1
            if attempts == 1 {
                XCTAssertEqual(token, "token-1")
                throw FleetAPIError.unauthorized
            }
            XCTAssertEqual(token, "token-2", "the replay must use the fresh token")
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 2, "exactly one replay")
        XCTAssertEqual(minted, 2, "exactly one extra mint")
        XCTAssertEqual(store.deleteCount, 0, "the credential store is unchanged")
    }

    func testASecondUnauthorizedAfterAFreshTokenIsSurfacedRatherThanSigningOut() async {
        let store = InMemoryCredentialStore(credential: credential)
        let clock = TestClock()
        var revoked = false

        let holder = makeHolder(store: store, clock: clock) { _ in self.token("token") }
        holder.onDeviceRevoked = { revoked = true }

        do {
            _ = try await holder.authorized { _ -> String in
                throw FleetAPIError.unauthorized
            }
            XCTFail("expected the second 401 to propagate")
        } catch {
            XCTAssertEqual(error as? FleetAPIError, .unauthorized)
        }

        // The mint succeeded, which proves the device credential is alive. Deleting it here
        // would turn an ordinary route-level failure into a re-enrollment.
        XCTAssertEqual(store.deleteCount, 0)
        XCTAssertFalse(revoked)
    }

    func testA401FromTheTokenMintIsTheOnlyPathThatDeletesTheCredential() async {
        let store = InMemoryCredentialStore(credential: credential)
        let clock = TestClock()
        var revoked = false

        let holder = makeHolder(store: store, clock: clock) { _ in
            throw FleetAPIError.unauthorized
        }
        holder.onDeviceRevoked = { revoked = true }

        do {
            _ = try await holder.accessToken()
            XCTFail("expected the mint to report the device revoked")
        } catch {
            XCTAssertEqual(error as? AccessTokenHolder.Failure, .deviceRevoked)
        }

        XCTAssertEqual(store.deleteCount, 1)
        XCTAssertNil(try? store.load() ?? nil)
        XCTAssertTrue(revoked)
    }

    func testANonAuthMintFailureRetainsTheCredential() async {
        let store = InMemoryCredentialStore(credential: credential)
        let clock = TestClock()

        let holder = makeHolder(store: store, clock: clock) { _ in
            throw FleetAPIError.unexpectedStatus(503)
        }

        do {
            _ = try await holder.accessToken()
            XCTFail("expected the mint failure to propagate")
        } catch {
            XCTAssertEqual(error as? FleetAPIError, .unexpectedStatus(503))
        }

        XCTAssertEqual(store.deleteCount, 0, "a 503 says nothing about the device record")
        XCTAssertNotNil(try? store.load() ?? nil)
    }

    func testAnEmptyStoreReportsNotEnrolledRatherThanRevoked() async {
        let store = InMemoryCredentialStore()
        let holder = makeHolder(store: store, clock: TestClock()) { _ in self.token("t") }

        do {
            _ = try await holder.accessToken()
            XCTFail("expected notEnrolled")
        } catch {
            XCTAssertEqual(error as? AccessTokenHolder.Failure, .notEnrolled)
        }
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testInvalidatingTheTokenLeavesTheCredentialAlone() async throws {
        let store = InMemoryCredentialStore(credential: credential)
        let clock = TestClock()
        var minted = 0

        let holder = makeHolder(store: store, clock: clock) { _ in
            minted += 1
            return self.token("token-\(minted)")
        }

        _ = try await holder.accessToken()
        holder.invalidateToken()
        _ = try await holder.accessToken()

        XCTAssertEqual(minted, 2)
        XCTAssertEqual(store.deleteCount, 0)
    }
}
