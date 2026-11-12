import XCTest
@testable import Phleet

/// The suspensions are intentional: replacement happens while old work ignores cancellation.
@MainActor
final class SessionIsolationTests: XCTestCase {
    private let first = DeviceCredential(origin: "https://first.example.invalid", deviceId: "first-device",
                                         deviceSecret: "first-secret", clientInstanceId: "first-client")
    private let second = DeviceCredential(origin: "https://second.example.invalid", deviceId: "second-device",
                                          deviceSecret: "second-secret", clientInstanceId: "second-client")

    @MainActor
    private final class Gate<Value> {
        var continuation: CheckedContinuation<Value, Error>?
        func wait() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    private func held<Value>(_ gate: Gate<Value>) async throws -> CheckedContinuation<Value, Error> {
        for _ in 0..<FakeFleetAPI.maxGateYields where gate.continuation == nil { await Task.yield() }
        return try XCTUnwrap(gate.continuation)
    }

    private func response(_ token: String = "first-token") -> MintTokenResponse {
        MintTokenResponse(accessToken: token, expiresInSeconds: 900)
    }

    private final class RecordingStore: CredentialStore {
        var value: DeviceCredential?
        var loads = 0
        init(_ value: DeviceCredential) { self.value = value }
        func load() throws -> DeviceCredential? { loads += 1; return value }
        func save(_ credential: DeviceCredential) throws { value = credential }
        func delete() throws { value = nil }
    }

    func testHolderNeverReadsReplacementCredentialToMint() async throws {
        let store = RecordingStore(first)
        var minted: [DeviceCredential] = []
        let holder = AccessTokenHolder(credentialStore: store) { credential in
            minted.append(credential)
            return self.response()
        }
        try store.save(second)
        _ = try await holder.accessToken()
        XCTAssertEqual(minted, [first])
        XCTAssertEqual(store.loads, 1, "only the immutable construction-time credential is read")
    }

    func testRetiredHolderRejectsLateSuccessfulMintAndCachedToken() async throws {
        let store = InMemoryCredentialStore(credential: first)
        let gate = Gate<MintTokenResponse>()
        let holder = AccessTokenHolder(credentialStore: store) { _ in try await gate.wait() }
        let task = Task { try await holder.accessToken() }
        let pending = try await held(gate)
        holder.invalidateSession()
        try store.save(second)
        pending.resume(returning: response())
        do { _ = try await task.value; XCTFail("late mint must not return a token") }
        catch { XCTAssertEqual(error as? AccessTokenHolder.Failure, .sessionEnded) }
        XCTAssertEqual(holder.mintCount, 0)
        do { _ = try await holder.accessToken(); XCTFail("retired holder must stay retired") }
        catch { XCTAssertEqual(error as? AccessTokenHolder.Failure, .sessionEnded) }
        XCTAssertEqual(try store.load(), second)
    }

    func testLateMintRefusalCannotDeleteOrRevokeReplacement() async throws {
        for retire in [false, true] {
            let store = InMemoryCredentialStore(credential: first)
            let gate = Gate<MintTokenResponse>()
            let holder = AccessTokenHolder(credentialStore: store) { _ in try await gate.wait() }
            var callbacks = 0
            holder.onDeviceRevoked = { callbacks += 1 }
            let task = Task { try await holder.accessToken() }
            let pending = try await held(gate)
            if retire { holder.invalidateSession() }
            try store.save(second)
            pending.resume(throwing: ControlAPIError.unauthorized)
            do { _ = try await task.value; XCTFail("old mint must fail") }
            catch { XCTAssertEqual(error as? AccessTokenHolder.Failure, .sessionEnded) }
            XCTAssertEqual(store.deleteCount, 0)
            XCTAssertEqual(try store.load(), second)
            XCTAssertEqual(callbacks, 0)
        }
    }

    private func environment(_ store: InMemoryCredentialStore, api: FakeControlAPI) -> AppEnvironment {
        AppEnvironment(credentialStore: store, legacyCredentialStore: InMemoryLegacyCredentialStore(),
                       api: FakeFleetAPI(), stream: FakeConversationStream(), controlAPI: api,
                       controlStream: FakeControlLiveStream(), controlLogStream: FakeAgentLogStream(),
                       pushSystem: FakePushSystem(), launchArguments: [], launchEnvironment: [:])
    }

    private func replace(_ environment: AppEnvironment, store: InMemoryCredentialStore) throws {
        try store.save(second)
        environment.finishSetup(SetupOutcome(credential: second,
            tokens: AccessTokenHolder(credentialStore: store) { _ in self.response("second-token") }))
    }

    func testOldOriginDelayed401CannotRefreshOrReplayIntoReplacement() async throws {
        let store = InMemoryCredentialStore(credential: first)
        let api = FakeControlAPI()
        let gate = Gate<[FleetAgent]>()
        api.onAgents = { try await gate.wait() }
        let app = environment(store, api: api)
        let oldModel = try XCTUnwrap(app.controlPlane)
        let old = Task { await oldModel.refresh() }
        let pending = try await held(gate)
        try replace(app, store: store)
        pending.resume(throwing: ControlAPIError.unauthorized)
        await old.value
        XCTAssertEqual(api.mintCount(), 1)
        XCTAssertEqual(api.count(of: .agents), 1, "no late replay to the old origin")
        XCTAssertTrue(api.connections.allSatisfy { $0.origin == first.originURL })
        XCTAssertEqual(app.credential, second)
        XCTAssertEqual(try store.load(), second)
        XCTAssertNil(app.signedOutNotice)
        api.onAgents = nil
        await app.controlPlane?.refresh()
        XCTAssertEqual(api.connections.last?.origin, second.originURL)
        XCTAssertEqual(api.connections.last?.accessToken, "second-token")
    }

    func testDelayedSignOutCannotTearDownOrDeleteReplacement() async throws {
        let store = InMemoryCredentialStore(credential: first)
        let api = FakeControlAPI()
        let gate = Gate<Void>()
        api.onRevoke = { try await gate.wait() }
        let app = environment(store, api: api)
        let old = Task { await app.signOut() }
        let pending = try await held(gate)
        try replace(app, store: store)
        pending.resume(returning: ())
        await old.value
        XCTAssertEqual(app.credential, second)
        XCTAssertEqual(try store.load(), second)
        XCTAssertEqual(store.deleteCount, 0)
        XCTAssertFalse(app.isSigningOut)
        XCTAssertNil(app.signedOutNotice)
    }

    func testCapturedOldRevocationCallbackCannotSignOutReplacement() throws {
        let store = InMemoryCredentialStore(credential: first)
        let app = environment(store, api: FakeControlAPI())
        let oldTokens = AccessTokenHolder(credentialStore: store) { _ in self.response() }
        app.finishSetup(SetupOutcome(credential: first, tokens: oldTokens))
        let callback = try XCTUnwrap(oldTokens.onDeviceRevoked)
        try replace(app, store: store)
        callback()
        XCTAssertEqual(app.credential, second)
        XCTAssertEqual(try store.load(), second)
        XCTAssertNil(app.signedOutNotice)
    }

    func testRetiredCachedTokenCannotAuthorizeAnotherRequest() async throws {
        let store = InMemoryCredentialStore(credential: first)
        let holder = AccessTokenHolder(credentialStore: store) { _ in self.response() }
        _ = try await holder.accessToken()
        holder.invalidateSession()
        try store.save(second)
        let api = FakeControlAPI()
        let wrapper = SignedInControlAPI(base: api, tokens: holder)
        do { _ = try await wrapper.agents(try XCTUnwrap(first.connection)); XCTFail("retired cache must be refused") }
        catch { XCTAssertEqual(error as? ControlAPIError, .unauthorized) }
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(holder.mintCount, 1)
    }

    func testEnvironmentReplacementRejectsDelayedMintSuccessAndRefusal() async throws {
        for refused in [false, true] {
            let store = InMemoryCredentialStore(credential: first)
            let api = FakeControlAPI()
            let gate = Gate<MintTokenResponse>()
            api.onMint = { try await gate.wait() }
            let app = environment(store, api: api)
            let oldChat = try XCTUnwrap(app.chat)
            let old = Task { await oldChat.load() }
            let pending = try await held(gate)
            try replace(app, store: store)
            if refused { pending.resume(throwing: ControlAPIError.unauthorized) }
            else { pending.resume(returning: response()) }
            await old.value
            XCTAssertEqual(app.credential, second)
            XCTAssertEqual(try store.load(), second)
            XCTAssertEqual(store.deleteCount, 0)
            XCTAssertNil(app.signedOutNotice)
            XCTAssertEqual(api.count(of: .chatAgents), 0, "retired mint cannot start an old-session request")
        }
    }

    func testStaleSetupOutcomeCannotReplaceNewerSession() throws {
        let store = InMemoryCredentialStore(credential: first)
        let app = environment(store, api: FakeControlAPI())
        let stale = SetupOutcome(credential: first,
            tokens: AccessTokenHolder(credentialStore: store) { _ in self.response() })
        try replace(app, store: store)
        app.finishSetup(stale)
        XCTAssertEqual(app.credential, second)
        XCTAssertEqual(try store.load(), second)
        XCTAssertNil(app.signedOutNotice)
    }

    func testWrapperRefusesTokenForDifferentOriginEvenWhileSessionIsActive() async throws {
        let store = InMemoryCredentialStore(credential: first)
        let api = FakeControlAPI()
        let holder = AccessTokenHolder(credentialStore: store) { _ in self.response() }
        let wrapper = SignedInControlAPI(base: api, tokens: holder)
        do { _ = try await wrapper.agents(try XCTUnwrap(second.connection)); XCTFail("wrong origin must be refused") }
        catch { XCTAssertEqual(error as? ControlAPIError, .unauthorized) }
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(holder.mintCount, 0)
    }
}
