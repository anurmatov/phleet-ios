import XCTest
@testable import Phleet

/// Notifications for a connection: the three steps that turn them on, and every way each stops.
@MainActor
final class PushNotificationsTests: XCTestCase {

    private static let token = String(repeating: "ab", count: 32)

    private final class Stored {
        var deviceId: String?
        var writes = 0
    }

    private func makeModel(
        api: FakeControlAPI = FakeControlAPI(),
        system: FakePushSystem? = nil,
        connection: ControlConnection = .fixture,
        deviceId: String? = nil,
        stored: Stored = Stored(),
        newDeviceId: @escaping () -> String = { "device-0001" }
    ) -> PushNotificationsModel {
        stored.deviceId = deviceId
        return PushNotificationsModel(
            api: api,
            system: system ?? FakePushSystem(),
            connection: connection,
            deviceId: deviceId,
            persist: { id in
                stored.deviceId = id
                stored.writes += 1
            },
            newDeviceId: newDeviceId
        )
    }

    // MARK: - Turning on

    func testTurningOnAsksThePersonThenAppleThenTheOrchestrator() async {
        let api = FakeControlAPI()
        let system = FakePushSystem()
        let stored = Stored()
        let model = makeModel(api: api, system: system, stored: stored)
        XCTAssertEqual(model.state, .off)

        await model.turnOn()

        XCTAssertEqual(system.permissionRequests, 1)
        XCTAssertEqual(system.registerCalls, 1)
        XCTAssertEqual(model.state, .registering, "Apple's token has not arrived yet")
        // The wish is recorded before the token arrives, so it survives a launch in which
        // Apple or the orchestrator could not be reached.
        XCTAssertEqual(stored.deviceId, "device-0001")
        XCTAssertTrue(api.calls.isEmpty)

        await model.handleDeviceToken(Self.token)

        XCTAssertEqual(api.calls, [.registerPush(deviceId: "device-0001", token: Self.token)])
        XCTAssertEqual(model.state, .on)
        XCTAssertTrue(model.offersTurnOff)
    }

    func testARefusalAtThePromptStopsThereAndAsksNobodyElse() async {
        let api = FakeControlAPI()
        let system = FakePushSystem()
        system.permission = .denied
        let stored = Stored()
        let model = makeModel(api: api, system: system, stored: stored)

        await model.turnOn()

        XCTAssertEqual(model.state, .denied)
        XCTAssertEqual(system.registerCalls, 0)
        XCTAssertNil(stored.deviceId)
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertFalse(model.state.offersTurnOn, "a refusal is changed in Settings, not by asking again")
    }

    func testAReadOnlyConnectionIsToldSoBeforeThePersonIsAsked() async {
        let system = FakePushSystem()
        let model = makeModel(system: system, connection: .readOnlyFixture)

        await model.turnOn()

        // Asking for permission that could never be used would be a prompt for nothing.
        XCTAssertEqual(model.state, .readOnly)
        XCTAssertEqual(system.permissionRequests, 0)
    }

    // MARK: - The orchestrator's answer

    func testAnOrchestratorWithNotificationsOffIsNotReportedAsOn() async {
        let api = FakeControlAPI()
        api.registerPushResult = .failure(ControlAPIError.refused(status: 503, message: "push_disabled"))
        let system = FakePushSystem()
        let stored = Stored()
        let model = makeModel(api: api, system: system, stored: stored)
        await model.turnOn()

        await model.handleDeviceToken(Self.token)

        XCTAssertEqual(model.state, .disabledOnServer)
        XCTAssertNil(stored.deviceId, "nothing will be sent, so the wish is not left recorded as met")
        XCTAssertEqual(system.unregisterCalls, 1)
        XCTAssertTrue(model.state.offersTurnOn)
    }

    func testAnOrchestratorOlderThanNotificationsSaysSo() async {
        let api = FakeControlAPI()
        api.registerPushResult = .failure(ControlAPIError.refused(status: 404, message: nil))
        let model = makeModel(api: api)
        await model.turnOn()

        await model.handleDeviceToken(Self.token)

        XCTAssertEqual(model.state, .unsupportedServer)
        XCTAssertFalse(model.isWanted)
    }

    func testAnOrchestratorThatCouldNotBeReachedKeepsTheWishAndSaysWhy() async {
        let api = FakeControlAPI()
        api.registerPushResult = .failure(ControlAPIError.transport("offline"))
        let stored = Stored()
        let model = makeModel(api: api, stored: stored)
        await model.turnOn()

        await model.handleDeviceToken(Self.token)

        XCTAssertEqual(model.state, .failed(.outcomeUnknown))
        // Still wanted: the next launch asks Apple again and tries the orchestrator again.
        XCTAssertEqual(stored.deviceId, "device-0001")
        XCTAssertTrue(model.offersTurnOff)
    }

    func testARejectedOperatorTokenIsNamedAsThat() async {
        let api = FakeControlAPI()
        api.registerPushResult = .failure(ControlAPIError.unauthorized)
        let model = makeModel(api: api)
        await model.turnOn()

        await model.handleDeviceToken(Self.token)

        XCTAssertEqual(model.state, .failed(.tokenRejected))
    }

    func testNoTokenFromAppleIsItsOwnState() async {
        let model = makeModel()
        await model.turnOn()

        model.handleRegistrationFailed()

        XCTAssertEqual(model.state, .tokenUnavailable)
        XCTAssertTrue(model.isWanted)
    }

    // MARK: - Across launches

    func testAConnectionWithNotificationsOnAsksAppleAgainAtLaunch() async {
        let api = FakeControlAPI()
        let system = FakePushSystem()
        let model = makeModel(api: api, system: system, deviceId: "device-0001")

        model.resume()

        // The token can change between launches, and the orchestrator must hear the new one.
        XCTAssertEqual(system.registerCalls, 1)
        XCTAssertEqual(system.permissionRequests, 0, "the person is not asked again")
        XCTAssertEqual(model.state, .registering)

        await model.handleDeviceToken(Self.token)
        XCTAssertEqual(api.calls, [.registerPush(deviceId: "device-0001", token: Self.token)])
        XCTAssertEqual(model.state, .on)
    }

    func testAConnectionWithNotificationsOffAsksNothingAtLaunch() async {
        let api = FakeControlAPI()
        let system = FakePushSystem()
        let model = makeModel(api: api, system: system)

        model.resume()
        await model.handleDeviceToken(Self.token)

        XCTAssertEqual(system.registerCalls, 0)
        XCTAssertTrue(api.calls.isEmpty, "a token that arrives unasked is not sent anywhere")
        XCTAssertEqual(model.state, .off)
    }

    // MARK: - Turning off

    func testTurningOffStopsThePhoneAndTellsTheOrchestrator() async {
        let api = FakeControlAPI()
        let system = FakePushSystem()
        let stored = Stored()
        let model = makeModel(api: api, system: system, deviceId: "device-0001", stored: stored)

        await model.turnOff()

        XCTAssertEqual(system.unregisterCalls, 1)
        XCTAssertEqual(api.calls, [.unregisterPush(deviceId: "device-0001")])
        XCTAssertNil(stored.deviceId)
        XCTAssertEqual(model.state, .off)
    }

    func testTurningOffStillStopsThePhoneWhenTheOrchestratorCannotBeTold() async {
        let api = FakeControlAPI()
        api.unregisterPushResult = .failure(ControlAPIError.transport("offline"))
        let system = FakePushSystem()
        let stored = Stored()
        let model = makeModel(api: api, system: system, deviceId: "device-0001", stored: stored)

        await model.turnOff()

        // The phone no longer receives, whatever the orchestrator still has on its list.
        XCTAssertEqual(system.unregisterCalls, 1)
        XCTAssertNil(stored.deviceId)
        XCTAssertEqual(model.state, .off)
    }

    // MARK: - A registration that finishes late

    private static let newerToken = String(repeating: "cd", count: 32)

    /// Yields until `condition` holds, within the doubles' gate bound.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<FakeFleetAPI.maxGateYields where !condition() {
            await Task.yield()
        }
    }

    /// Turns on, sends the token with the orchestrator's answer held, then turns off and lets
    /// that answer arrive — after the removal was answered, or while it is still in flight.
    private func turnOffDuringRegistration(
        answer: Result<Void, Error>,
        registrationAnswersFirst: Bool
    ) async -> (PushNotificationsModel, FakeControlAPI, FakePushSystem, Stored) {
        let api = FakeControlAPI()
        let system = FakePushSystem()
        let stored = Stored()
        let model = makeModel(api: api, system: system, stored: stored)
        await model.turnOn()
        api.hold(registrationOf: Self.token)
        let registering = Task { await model.handleDeviceToken(Self.token) }
        await settle { api.count(of: .registerPush(deviceId: "device-0001", token: Self.token)) == 1 }

        if registrationAnswersFirst { api.hold(removalOf: "device-0001") }
        let turningOff = Task { await model.turnOff() }
        await settle { api.count(of: .unregisterPush(deviceId: "device-0001")) == 1 }
        XCTAssertEqual(model.state, .off, "the wish goes before the orchestrator answers")
        if !registrationAnswersFirst { await turningOff.value }

        api.registerPushResult = answer
        api.release(registrationOf: Self.token)
        if registrationAnswersFirst {
            if case .success = answer {
                // A late success is handled once it takes the registration back.
                await settle { api.count(of: .unregisterPush(deviceId: "device-0001")) == 2 }
            } else {
                await registering.value
            }
            api.release(removalOf: "device-0001")
        }
        await registering.value
        await turningOff.value
        return (model, api, system, stored)
    }

    private func assertStaysOff(
        _ model: PushNotificationsModel,
        _ system: FakePushSystem,
        _ stored: Stored,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(model.state, .off, file: file, line: line)
        XCTAssertNil(model.deviceId, file: file, line: line)
        XCTAssertNil(stored.deviceId, file: file, line: line)
        XCTAssertEqual(stored.writes, 2, "turning on, then off; nothing late", file: file, line: line)
        XCTAssertEqual(system.unregisterCalls, 1, "only turning off stops the phone", file: file, line: line)
        XCTAssertTrue(model.state.offersTurnOn, "the control still works", file: file, line: line)
    }

    func testALateSuccessAfterTurningOffKeepsItOffAndTakesTheRegistrationBack() async {
        for registrationAnswersFirst in [false, true] {
            let (model, api, system, stored) = await turnOffDuringRegistration(
                answer: .success(()),
                registrationAnswersFirst: registrationAnswersFirst
            )

            assertStaysOff(model, system, stored)
            // The removal may have reached the orchestrator before the registration did, so it
            // is told once more.
            XCTAssertEqual(api.calls, [
                .registerPush(deviceId: "device-0001", token: Self.token),
                .unregisterPush(deviceId: "device-0001"),
                .unregisterPush(deviceId: "device-0001"),
            ], "registration answered first: \(registrationAnswersFirst)")
        }
    }

    func testALateRefusalOrFailureAfterTurningOffChangesNothing() async {
        let answers: [Result<Void, Error>] = [
            .failure(ControlAPIError.refused(status: 503, message: "push_disabled")),
            .failure(ControlAPIError.transport("offline")),
        ]
        for answer in answers {
            for registrationAnswersFirst in [false, true] {
                let (model, api, system, stored) = await turnOffDuringRegistration(
                    answer: answer,
                    registrationAnswersFirst: registrationAnswersFirst
                )

                assertStaysOff(model, system, stored)
                XCTAssertEqual(api.calls, [
                    .registerPush(deviceId: "device-0001", token: Self.token),
                    .unregisterPush(deviceId: "device-0001"),
                ], "registration answered first: \(registrationAnswersFirst)")
            }
        }
    }

    func testATokenThatArrivesWhileTurningOffIsNotRegistered() async {
        let api = FakeControlAPI()
        let system = FakePushSystem()
        let stored = Stored()
        let model = makeModel(api: api, system: system, deviceId: "device-0001", stored: stored)
        api.hold(removalOf: "device-0001")
        let turningOff = Task { await model.turnOff() }
        await settle { api.count(of: .unregisterPush(deviceId: "device-0001")) == 1 }

        await model.handleDeviceToken(Self.token)
        api.release(removalOf: "device-0001")
        await turningOff.value

        XCTAssertEqual(api.calls, [.unregisterPush(deviceId: "device-0001")])
        XCTAssertEqual(model.state, .off)
        XCTAssertNil(stored.deviceId)
    }

    func testTurningOnAgainIsNotUndoneByTheOldRegistration() async {
        // A late registration of the old device is taken back; a refused one needs nothing more.
        let cases: [(answer: Result<Void, Error>, oldRemovals: Int)] = [
            (.success(()), 2),
            (.failure(ControlAPIError.refused(status: 503, message: "push_disabled")), 1),
        ]
        for (answer, oldRemovals) in cases {
            let api = FakeControlAPI()
            let system = FakePushSystem()
            let stored = Stored()
            var ids = ["device-0001", "device-0002"]
            let model = makeModel(api: api, system: system, stored: stored, newDeviceId: { ids.removeFirst() })
            await model.turnOn()
            api.hold(registrationOf: Self.token)
            let old = Task { await model.handleDeviceToken(Self.token) }
            await settle { api.count(of: .registerPush(deviceId: "device-0001", token: Self.token)) == 1 }

            await model.turnOff()
            await model.turnOn()
            await model.handleDeviceToken(Self.newerToken)
            XCTAssertEqual(model.state, .on)

            api.registerPushResult = answer
            api.release(registrationOf: Self.token)
            await old.value

            XCTAssertEqual(model.state, .on)
            XCTAssertEqual(model.deviceId, "device-0002")
            XCTAssertEqual(stored.deviceId, "device-0002")
            XCTAssertEqual(system.unregisterCalls, 1, "only turning off stops the phone")
            XCTAssertEqual(api.count(of: .unregisterPush(deviceId: "device-0002")), 0, "the newer wish is never removed")
            XCTAssertEqual(api.count(of: .unregisterPush(deviceId: "device-0001")), oldRemovals)
        }
    }

    func testAnOlderRegistrationOfTheSameDeviceCannotUndoANewerOne() async {
        let answers: [Result<Void, Error>] = [
            .success(()),
            .failure(ControlAPIError.refused(status: 503, message: "push_disabled")),
        ]
        for answer in answers {
            let api = FakeControlAPI()
            let system = FakePushSystem()
            let stored = Stored()
            let model = makeModel(api: api, system: system, deviceId: "device-0001", stored: stored)
            model.resume()
            api.hold(registrationOf: Self.token)
            let older = Task { await model.handleDeviceToken(Self.token) }
            await settle { api.count(of: .registerPush(deviceId: "device-0001", token: Self.token)) == 1 }

            // Apple issued a newer token, and the orchestrator took it.
            await model.handleDeviceToken(Self.newerToken)
            XCTAssertEqual(model.state, .on)

            api.registerPushResult = answer
            api.release(registrationOf: Self.token)
            await older.value

            XCTAssertEqual(model.state, .on)
            XCTAssertEqual(model.deviceId, "device-0001")
            XCTAssertEqual(stored.deviceId, "device-0001")
            XCTAssertEqual(system.unregisterCalls, 0)
            XCTAssertEqual(api.count(of: .unregisterPush(deviceId: "device-0001")), 0)
        }
    }

    // MARK: - Requests

    func testRegisteringAndRemovingAreWritesToThatDevicesRoute() throws {
        let register = try ControlRequest.make(
            connection: .fixture,
            method: "PUT",
            percentEncodedPath: ControlRequest.pushDevicePath(deviceId: "device-0001"),
            body: Data("{}".utf8)
        )
        XCTAssertEqual(
            register.url?.absoluteString,
            "https://fleet.example.invalid/api/push/devices/device-0001"
        )
        XCTAssertEqual(register.value(forHTTPHeaderField: "Authorization"), "Bearer operator-token-1")

        XCTAssertThrowsError(
            try ControlRequest.make(
                connection: .readOnlyFixture,
                method: "DELETE",
                percentEncodedPath: ControlRequest.pushDevicePath(deviceId: "device-0001")
            )
        ) { error in
            XCTAssertEqual(error as? ControlAPIError, .readOnly)
        }
    }

    func testAGeneratedDeviceIdentifierFitsWhatTheOrchestratorAccepts() {
        // The orchestrator takes 8 to 64 characters of [A-Za-z0-9_-].
        let id = ClientIdentifier.random()
        XCTAssertTrue((8...64).contains(id.count))
        XCTAssertTrue(ClientIdentifier.isValid(id))
    }

    // MARK: - A tapped notification

    func testATappedNotificationOpensTheTabThatShowsIt() {
        XCTAssertEqual(PushDestination.destination(forKind: "gate"), .fleet)
        XCTAssertEqual(PushDestination.destination(forKind: "agent"), .fleet)
        XCTAssertEqual(PushDestination.destination(forKind: "run"), .runs)
        // A kind this build does not know, or none: still somewhere, never nowhere.
        XCTAssertEqual(PushDestination.destination(forKind: "something-new"), .fleet)
        XCTAssertEqual(PushDestination.destination(forKind: nil), .fleet)
    }

    func testTheKindIsReadFromWhereTheOrchestratorPutsIt() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Workflow failed", "body": "example/project · PR #7"]],
            "phleet": ["kind": "run", "workflowId": "pr-7", "runId": "run-1", "namespace": "fleet"]
        ]
        XCTAssertEqual(PushDestination.kind(in: userInfo), "run")
        XCTAssertNil(PushDestination.kind(in: ["aps": ["alert": "x"]]))
        XCTAssertNil(PushDestination.kind(in: ["phleet": "not a dictionary"]))
    }

    // MARK: - In the composition root

    private func makeEnvironment(
        api: FakeControlAPI,
        system: FakePushSystem,
        store: InMemoryControlCredentialStore
    ) -> AppEnvironment {
        AppEnvironment(
            credentialStore: InMemoryCredentialStore(),
            api: FakeFleetAPI(),
            stream: FakeConversationStream(),
            controlCredentialStore: store,
            controlAPI: api,
            controlStream: FakeControlLiveStream(),
            controlLogStream: FakeAgentLogStream(),
            pushSystem: system,
            launchArguments: [],
            launchEnvironment: [:]
        )
    }

    private let credential = ControlCredential(
        origin: "https://fleet.example.invalid",
        accessClientId: "client-id-1",
        accessClientSecret: "client-secret-1",
        operatorToken: "operator-token-1"
    )

    func testTurningOnIsStoredWithTheConnectionAndATokenReachesTheOrchestrator() async throws {
        let api = FakeControlAPI()
        let system = FakePushSystem()
        let store = InMemoryControlCredentialStore(credential: credential)
        let environment = makeEnvironment(api: api, system: system, store: store)
        let push = try XCTUnwrap(environment.pushNotifications)
        XCTAssertEqual(system.registerCalls, 0, "nothing is asked of Apple while notifications are off")

        await push.turnOn()
        let deviceId = try XCTUnwrap(try store.load()?.pushDeviceId)
        XCTAssertEqual(environment.controlCredential?.pushDeviceId, deviceId)

        // The token arrives the way the system delivers it: through the handler.
        system.onDeviceToken?(Self.token)
        for _ in 0..<FakeFleetAPI.maxGateYields where push.state != .on {
            await Task.yield()
        }

        XCTAssertEqual(push.state, .on)
        XCTAssertEqual(api.calls, [.registerPush(deviceId: deviceId, token: Self.token)])
    }

    func testAStoredWishIsResumedAtLaunch() throws {
        let system = FakePushSystem()
        let store = InMemoryControlCredentialStore(
            credential: credential.withPushDeviceId("device-0001")
        )

        let environment = makeEnvironment(api: FakeControlAPI(), system: system, store: store)

        XCTAssertEqual(system.registerCalls, 1)
        XCTAssertEqual(environment.pushNotifications?.state, .registering)
    }

    func testACredentialStoredBeforeNotificationsExistedStillLoads() throws {
        // Written by a build that had no such field.
        let older = #"{"origin":"https://fleet.example.invalid","operatorToken":"operator-token-1"}"#
        let decoded = try JSONDecoder().decode(ControlCredential.self, from: Data(older.utf8))

        XCTAssertNil(decoded.pushDeviceId)
        XCTAssertEqual(decoded.operatorToken, "operator-token-1")
    }

    func testRemovingTheConnectionTellsTheOrchestratorToForgetThisPhone() async throws {
        let api = FakeControlAPI()
        let system = FakePushSystem()
        let store = InMemoryControlCredentialStore(
            credential: credential.withPushDeviceId("device-0001")
        )
        let environment = makeEnvironment(api: api, system: system, store: store)

        environment.removeControlConnection()
        for _ in 0..<FakeFleetAPI.maxGateYields where api.count(of: .unregisterPush(deviceId: "device-0001")) == 0 {
            await Task.yield()
        }

        XCTAssertEqual(api.count(of: .unregisterPush(deviceId: "device-0001")), 1)
        XCTAssertEqual(system.unregisterCalls, 1)
        XCTAssertNil(environment.pushNotifications)
        XCTAssertNil(try store.load())
    }

    func testATappedNotificationIsHandedToTheRootViewOnce() {
        let system = FakePushSystem()
        let environment = makeEnvironment(
            api: FakeControlAPI(),
            system: system,
            store: InMemoryControlCredentialStore()
        )
        XCTAssertNil(environment.requestedDestination)

        system.onOpened?(.runs)

        XCTAssertEqual(environment.requestedDestination, .runs)
    }
}
