import XCTest
@testable import Phleet

/// Every orchestrator request signed in as this phone, and what a refused one leads to.
@MainActor
final class SignedInControlTests: XCTestCase {

    private func makeTokens(
        api: FakeControlAPI,
        store: InMemoryCredentialStore
    ) -> AccessTokenHolder {
        AccessTokenHolder(credentialStore: store, clock: TestClock()) { credential in
            guard let connection = credential.connection else {
                throw ControlAPIError.transport("malformed stored origin")
            }
            return try await api.mintToken(
                connection,
                deviceId: credential.deviceId,
                deviceSecret: credential.deviceSecret
            )
        }
    }

    /// The token each request carried, leaving out the mints that obtained them.
    private func signedTokens(_ api: FakeControlAPI) -> [String?] {
        var tokens: [String?] = []
        for (call, token) in zip(api.calls, api.accessTokens) {
            if case .mintToken = call { continue }
            tokens.append(token)
        }
        return tokens
    }

    private func token(_ value: String) -> Result<MintTokenResponse, Error> {
        .success(MintTokenResponse(accessToken: value, expiresInSeconds: 900))
    }

    func testEveryRequestCarriesTheCurrentTokenThoughTheModelsHoldNone() async throws {
        let base = FakeControlAPI()
        let store = InMemoryCredentialStore(credential: .fixture)
        let api = SignedInControlAPI(base: base, tokens: makeTokens(api: base, store: store))

        _ = try await api.agents(.unsignedFixture)
        _ = try await api.chatAgents(.unsignedFixture)
        try await api.performAgentAction(.unsignedFixture, agentName: "builder", action: .restart)

        XCTAssertEqual(
            signedTokens(base),
            ["access-token-1", "access-token-1", "access-token-1"]
        )
        XCTAssertEqual(base.mintCount(), 1, "one token, minted once, used until it is near its end")
        XCTAssertEqual(base.connections.last?.serviceToken, ControlConnection.fixture.serviceToken)
    }

    func testARefusedTokenIsMintedAgainAndTheRequestSentOnceMore() async throws {
        let base = FakeControlAPI()
        base.mintResults = [token("access-token-1"), token("access-token-2")]
        base.onSignedRequest = { token in
            token == "access-token-1" ? ControlAPIError.unauthorized : nil
        }
        let store = InMemoryCredentialStore(credential: .fixture)
        let api = SignedInControlAPI(base: base, tokens: makeTokens(api: base, store: store))

        _ = try await api.agents(.unsignedFixture)

        XCTAssertEqual(base.count(of: .agents), 2)
        XCTAssertEqual(base.mintCount(), 2)
        XCTAssertEqual(signedTokens(base), ["access-token-1", "access-token-2"])
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testASecondRefusalIsThatRequestsFailureAndNotASignOut() async {
        // The mint just succeeded, so the device credential is alive: whatever refused the
        // request, signing the phone out would not be the answer to it.
        let base = FakeControlAPI()
        base.mintResults = [token("access-token-1"), token("access-token-2")]
        base.onSignedRequest = { _ in ControlAPIError.unauthorized }
        let store = InMemoryCredentialStore(credential: .fixture)
        let tokens = makeTokens(api: base, store: store)
        var signedOut = false
        tokens.onDeviceRevoked = { signedOut = true }
        let api = SignedInControlAPI(base: base, tokens: tokens)

        do {
            _ = try await api.agents(.unsignedFixture)
            XCTFail("expected the second refusal to be reported")
        } catch {
            XCTAssertEqual(error as? ControlAPIError, .unauthorized)
        }

        XCTAssertEqual(base.count(of: .agents), 2, "replayed once, and only once")
        XCTAssertEqual(base.mintCount(), 2)
        XCTAssertFalse(signedOut)
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testAMintTheOrchestratorRefusesSignsThePhoneOut() async {
        let base = FakeControlAPI()
        base.mintResults = [.failure(ControlAPIError.unauthorized)]
        let store = InMemoryCredentialStore(credential: .fixture)
        let tokens = makeTokens(api: base, store: store)
        var signedOut = false
        tokens.onDeviceRevoked = { signedOut = true }
        let api = SignedInControlAPI(base: base, tokens: tokens)

        do {
            _ = try await api.agents(.unsignedFixture)
            XCTFail("expected the request to be refused")
        } catch {
            // Said to the model above as a refusal; the sign-in is torn down above it.
            XCTAssertEqual(error as? ControlAPIError, .unauthorized)
        }

        XCTAssertTrue(signedOut)
        XCTAssertNil(try store.load())
        XCTAssertEqual(base.count(of: .agents), 0, "nothing was sent without a token")
    }

    func testTheRoutesThatObtainATokenPassThroughWithout() async throws {
        let base = FakeControlAPI()
        let store = InMemoryCredentialStore()
        let api = SignedInControlAPI(base: base, tokens: makeTokens(api: base, store: store))

        _ = try await api.registerDevice(.unsignedFixture, enrollmentCode: "e.s", deviceName: nil)
        _ = try await api.mintToken(.unsignedFixture, deviceId: "device-1", deviceSecret: "secret-1")

        XCTAssertEqual(base.accessTokens, [nil, nil])
        XCTAssertEqual(base.mintCount(), 1, "only the one asked for")
    }

    func testTheLiveSocketIsOpenedSignedInAndRelaysWhatItCarries() async {
        let base = FakeControlLiveStream(scripts: [[.undecodableFrame, .ended]])
        let control = FakeControlAPI()
        let store = InMemoryCredentialStore(credential: .fixture)
        let stream = SignedInControlLiveStream(
            base: base,
            tokens: makeTokens(api: control, store: store)
        )

        var events: [ControlLiveEvent] = []
        for await event in stream.frames(.unsignedFixture) {
            events.append(event)
        }

        XCTAssertEqual(events, [.undecodableFrame, .ended])
        XCTAssertEqual(base.accessTokens, ["access-token-1"])
    }

    func testASocketWithNoTokenToBeHadEndsAtOnce() async {
        let base = FakeControlLiveStream(scripts: [[.undecodableFrame, .ended]])
        let control = FakeControlAPI()
        control.mintResults = [.failure(ControlAPIError.transport("offline"))]
        let store = InMemoryCredentialStore(credential: .fixture)
        let stream = SignedInControlLiveStream(
            base: base,
            tokens: makeTokens(api: control, store: store)
        )

        var events: [ControlLiveEvent] = []
        for await event in stream.frames(.unsignedFixture) {
            events.append(event)
        }

        XCTAssertEqual(events, [.ended])
        XCTAssertEqual(base.attachCount, 0, "no socket is opened unsigned")
    }
}
