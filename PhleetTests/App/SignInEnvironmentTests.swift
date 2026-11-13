import XCTest
@testable import Phleet

/// One sign-in in the composition root: what a launch restores, what setup adopts, and the three
/// ways it ends — revoked from the dashboard, signed out here, and a credential that cannot be
/// read.
@MainActor
final class SignInEnvironmentTests: XCTestCase {

    private final class UnreadableStore: CredentialStore {
        private(set) var deleteCount = 0
        func load() throws -> DeviceCredential? {
            throw CredentialStoreError.unavailable(status: -25308)
        }
        func save(_ credential: DeviceCredential) throws {}
        func delete() throws { deleteCount += 1 }
    }

    private func makeEnvironment(
        store: CredentialStore = InMemoryCredentialStore(),
        legacy: LegacyCredentialStore = InMemoryLegacyCredentialStore(),
        control: FakeControlAPI = FakeControlAPI(),
        push: FakePushSystem? = nil,
        chat: FakeFleetAPI = FakeFleetAPI()
    ) -> AppEnvironment {
        AppEnvironment(
            credentialStore: store,
            legacyCredentialStore: legacy,
            api: chat,
            stream: FakeConversationStream(),
            controlAPI: control,
            controlStream: FakeControlLiveStream(),
            controlLogStream: FakeAgentLogStream(),
            pushSystem: push ?? FakePushSystem(),
            launchArguments: [],
            launchEnvironment: [:]
        )
    }

    private func outcome(
        _ credential: DeviceCredential,
        store: InMemoryCredentialStore
    ) -> SetupOutcome {
        try? store.save(credential)
        return SetupOutcome(
            credential: credential,
            tokens: AccessTokenHolder(credentialStore: store, clock: TestClock()) { _ in
                MintTokenResponse(accessToken: "access-token-1", expiresInSeconds: 900)
            }
        )
    }

    // MARK: - Launching

    func testAFreshInstallIsSignedOutWithNothingToSay() {
        let environment = makeEnvironment()

        XCTAssertFalse(environment.isSignedIn)
        XCTAssertNil(environment.controlPlane)
        XCTAssertNil(environment.runs)
        XCTAssertNil(environment.chat)
        XCTAssertNil(environment.pushNotifications)
        XCTAssertNil(environment.signedOutNotice)
    }

    func testAStoredSignInRestoresFleetRunsAndChatTogether() {
        let environment = makeEnvironment(store: InMemoryCredentialStore(credential: .fixture))

        XCTAssertTrue(environment.isSignedIn)
        XCTAssertEqual(environment.credential, .fixture)
        XCTAssertNotNil(environment.controlPlane)
        XCTAssertNotNil(environment.runs)
        XCTAssertNotNil(environment.chat)
        XCTAssertNotNil(environment.pushNotifications)
        XCTAssertEqual(environment.serverProfile?.displayName, "fleet.example.invalid")
    }

    func testAnUnreadableSignInIsReportedAndNeverDeleted() {
        // A read that fails while the phone is locked must not destroy a working sign-in.
        let store = UnreadableStore()
        let environment = makeEnvironment(store: store)

        XCTAssertEqual(environment.signedOutNotice, .credentialUnavailable)
        XCTAssertFalse(environment.isSignedIn)
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testWhatAnEarlierBuildLeftBehindIsTakenOnceAtLaunch() {
        let legacy = InMemoryLegacyCredentialStore()
        _ = makeEnvironment(legacy: legacy)
        XCTAssertEqual(legacy.takeCount, 1)
    }

    // MARK: - Signing in

    func testFinishingSetupSignsEverythingIn() {
        let store = InMemoryCredentialStore()
        let environment = makeEnvironment(store: store)

        environment.finishSetup(outcome(.fixture, store: store))

        XCTAssertTrue(environment.isSignedIn)
        XCTAssertNotNil(environment.controlPlane)
        XCTAssertNotNil(environment.chat)
        XCTAssertNil(environment.signedOutNotice)
    }

    func testTheFleetIsReadSignedInWithTheOneToken() async throws {
        let control = FakeControlAPI()
        let environment = makeEnvironment(
            store: InMemoryCredentialStore(credential: .fixture),
            control: control
        )

        try await XCTUnwrap(environment.chat).load()

        XCTAssertEqual(control.count(of: .chatAgents), 1)
        XCTAssertEqual(control.connections.last?.accessToken, "access-token-1")
        XCTAssertEqual(
            control.connections.last?.serviceToken,
            DeviceCredential.fixture.serviceToken,
            "the proxy's service token, from the same credential"
        )
    }

    func testNotificationsThatWereOnUnderAnEarlierBuildCarryOverToTheSameServer() throws {
        let store = InMemoryCredentialStore()
        let environment = makeEnvironment(
            store: store,
            legacy: InMemoryLegacyCredentialStore(
                // The same address, written with a trailing slash and an upper-case host.
                wish: LegacyNotificationWish(
                    origin: "https://FLEET.example.invalid/",
                    pushDeviceId: "push-0001"
                )
            )
        )

        environment.finishSetup(outcome(.fixture, store: store))

        XCTAssertEqual(environment.credential?.pushDeviceId, "push-0001")
        XCTAssertEqual(try store.load()?.pushDeviceId, "push-0001")
        XCTAssertEqual(environment.pushNotifications?.deviceId, "push-0001")
    }

    func testNotificationsUnderAnEarlierBuildDoNotFollowThePhoneToAnotherServer() {
        let store = InMemoryCredentialStore()
        let environment = makeEnvironment(
            store: store,
            legacy: InMemoryLegacyCredentialStore(
                wish: LegacyNotificationWish(
                    origin: "https://another.example.invalid",
                    pushDeviceId: "push-0001"
                )
            )
        )

        environment.finishSetup(outcome(.fixture, store: store))

        XCTAssertNil(environment.credential?.pushDeviceId)
    }

    // MARK: - Revoked from the dashboard

    func testARevokedPhoneIsSignedOutAndToldWhy() async throws {
        let control = FakeControlAPI()
        control.mintResults = [.failure(ControlAPIError.unauthorized)]
        let push = FakePushSystem()
        let store = InMemoryCredentialStore(
            credential: DeviceCredential.fixture.withPushDeviceId("push-0001")
        )
        let environment = makeEnvironment(store: store, control: control, push: push)
        let unregisteredAtLaunch = push.unregisterCalls

        try await XCTUnwrap(environment.chat).load()

        XCTAssertFalse(environment.isSignedIn)
        XCTAssertEqual(environment.signedOutNotice, .revoked)
        XCTAssertNil(environment.controlPlane)
        XCTAssertNil(environment.chat)
        XCTAssertNil(try store.load(), "deleted by the one place allowed to on this path")
        XCTAssertEqual(
            push.unregisterCalls,
            unregisteredAtLaunch + 1,
            "the phone stops receiving; the orchestrator cannot be told any more"
        )
    }

    // MARK: - Restored history stays in its scope

    func testRestoredHistoryStaysWithItsAgentAndItsSignIn() async throws {
        let chat = FakeFleetAPI()
        chat.catchUpResults = [
            .success(CatchUpResponse(
                events: [
                    TestEvent.text("durable-1", seq: 1, text: "for the builder"),
                    TestEvent.final("durable-1", seq: 2, merged: ["durable-1"])
                ],
                nextAfterSeq: 2,
                hasMore: false,
                protocolVersion: ProtocolVersion.current
            )),
            .success(CatchUpResponse(
                events: [],
                nextAfterSeq: 0,
                hasMore: false,
                protocolVersion: ProtocolVersion.current
            ))
        ]
        let store = InMemoryCredentialStore(credential: .fixture)
        let environment = makeEnvironment(store: store, chat: chat)
        let builder = ChatAgent(agentName: "builder", displayName: "Builder")
        let reviewer = ChatAgent(agentName: "reviewer", displayName: "Reviewer")

        let builderThread = try XCTUnwrap(environment.chat).conversation(for: builder)
        _ = await builderThread.runOnce()
        XCTAssertEqual(builderThread.machine.orderedRecords.map(\.text), ["for the builder"])

        // Another agent is another conversation, opened under its own name and read on its own.
        let reviewerThread = try XCTUnwrap(environment.chat).conversation(for: reviewer)
        XCTAssertTrue(reviewerThread.machine.orderedRecords.isEmpty)
        _ = await reviewerThread.runOnce()
        XCTAssertTrue(reviewerThread.machine.orderedRecords.isEmpty, "no rows borrowed")
        XCTAssertTrue(chat.calls.contains(.openConversation(
            externalRef: "main",
            agent: "reviewer",
            clientInstanceId: DeviceCredential.fixture.clientInstanceId
        )))

        // A replaced sign-in starts from what its own reads return, never from the old rows.
        let second = DeviceCredential(
            origin: "https://second.example.invalid",
            deviceId: "second-device",
            deviceSecret: "second-secret",
            clientInstanceId: "second-instance"
        )
        environment.finishSetup(outcome(second, store: store))
        let replaced = try XCTUnwrap(environment.chat).conversation(for: builder)
        XCTAssertFalse(replaced === builderThread)
        XCTAssertTrue(replaced.machine.orderedRecords.isEmpty, "nothing carried across a sign-in")

        XCTAssertTrue(chat.submissions.isEmpty, "reading history sent nothing")
    }

    // MARK: - Signing out

    func testSigningOutRevokesThisPhoneAndDeletesItsSignIn() async throws {
        let control = FakeControlAPI()
        let store = InMemoryCredentialStore(credential: .fixture)
        let environment = makeEnvironment(store: store, control: control)

        await environment.signOut()

        XCTAssertEqual(control.count(of: .revokeDevice(deviceId: "device-1")), 1)
        // Revoking itself is the one device route a phone's own token may use.
        XCTAssertEqual(control.connections.last?.accessToken, "access-token-1")
        XCTAssertFalse(environment.isSignedIn)
        XCTAssertNil(try store.load())
        XCTAssertNil(environment.controlPlane)
        XCTAssertNil(environment.runs)
        XCTAssertNil(environment.chat)
        XCTAssertNil(environment.signedOutNotice)
        XCTAssertFalse(environment.isSigningOut)
    }

    func testAServerThatCannotBeToldStillSignsThisPhoneOutAndSaysSo() async throws {
        let control = FakeControlAPI()
        control.revokeResult = .failure(ControlAPIError.transport("offline"))
        let store = InMemoryCredentialStore(credential: .fixture)
        let environment = makeEnvironment(store: store, control: control)

        await environment.signOut()

        XCTAssertFalse(environment.isSignedIn)
        XCTAssertNil(try store.load(), "the person asked to be signed out of this phone")
        XCTAssertEqual(
            environment.signedOutNotice,
            .serverNotTold,
            "the phone stays on the dashboard's device list until it is revoked there"
        )
    }

    func testADeviceTheServerNoLongerHasCountsAsTold() async {
        let control = FakeControlAPI()
        control.revokeResult = .failure(ControlAPIError.refused(status: 404, message: "device_not_found"))
        let environment = makeEnvironment(
            store: InMemoryCredentialStore(credential: .fixture),
            control: control
        )

        await environment.signOut()

        XCTAssertNil(environment.signedOutNotice)
    }

    func testSigningOutKeepsWhatWasTypedAndEachAgentKeepsItsOwnDraft() async {
        let environment = makeEnvironment(store: InMemoryCredentialStore(credential: .fixture))
        environment.setDraft("for the builder", for: "builder")
        environment.setDraft("for the reviewer", for: "reviewer")

        await environment.signOut()

        XCTAssertEqual(environment.draft(for: "builder"), "for the builder")
        XCTAssertEqual(environment.draft(for: "reviewer"), "for the reviewer")
        XCTAssertEqual(environment.draft(for: "planner"), "", "never another agent's draft")
    }

    // MARK: - The scripted backend

    func testTheScriptedBackendNeverTouchesTheKeychain() {
        let environment = AppEnvironment(
            launchArguments: [LaunchArguments.scriptedBackend],
            launchEnvironment: [:]
        )
        XCTAssertTrue(environment.credentialStore is InMemoryCredentialStore)
        XCTAssertTrue(environment.legacyCredentialStore is InMemoryLegacyCredentialStore)
        XCTAssertTrue(environment.controlAPI is ScriptedControlBackend)
        XCTAssertFalse(environment.isSignedIn)
    }

    func testOnlyTheScriptedBackendStandsInForTheCamera() {
        XCTAssertNil(makeEnvironment().scriptedSetupCode, "a real launch opens the scanner")

        let scripted = AppEnvironment(
            launchArguments: [LaunchArguments.scriptedBackend],
            launchEnvironment: [:]
        )
        XCTAssertEqual(scripted.scriptedSetupCode, LaunchDouble.scriptedSetupCode)

        let older = AppEnvironment(
            launchArguments: [LaunchArguments.scriptedBackend, LaunchArguments.olderSetupCode],
            launchEnvironment: [:]
        )
        XCTAssertEqual(older.scriptedSetupCode, LaunchDouble.olderSetupCode)

        let unreadable = AppEnvironment(
            launchArguments: [LaunchArguments.scriptedBackend, LaunchArguments.unreadableSetupCode],
            launchEnvironment: [:]
        )
        XCTAssertEqual(unreadable.scriptedSetupCode, "not a setup code")
    }
}
