import XCTest
@testable import Phleet

/// Signing in: what a scan may do, what connecting sends and stores, and the ordering rule that
/// stops a dropped packet costing the person their sign-in.
@MainActor
final class SetupModelTests: XCTestCase {

    private let code = #"{"phleet":"setup","v":2,"origin":"https://fleet.example.invalid","#
        + #""accessClientId":"client-id-1","accessClientSecret":"client-secret-1","#
        + #""enrollmentCode":"enrollment-1.secret-value"}"#

    private func makeModel(
        api: FakeControlAPI,
        store: CredentialStore,
        newClientInstanceId: @escaping () -> String = { "instance-1" }
    ) -> SetupModel {
        SetupModel(
            api: api,
            credentialStore: store,
            deviceName: "iPhone",
            makeTokenHolder: { credentialStore in
                AccessTokenHolder(credentialStore: credentialStore, clock: TestClock()) { credential in
                    guard let connection = credential.connection else {
                        throw ControlAPIError.transport("malformed stored origin")
                    }
                    return try await api.mintToken(
                        connection,
                        deviceId: credential.deviceId,
                        deviceSecret: credential.deviceSecret
                    )
                }
            },
            newClientInstanceId: newClientInstanceId
        )
    }

    // MARK: - Scanning

    func testAScanShowsWhatTheCodeSaysAndContactsNobody() {
        let api = FakeControlAPI()
        let model = makeModel(api: api, store: InMemoryCredentialStore())

        XCTAssertTrue(model.apply(scanned: code))

        XCTAssertEqual(model.code?.displayName, "fleet.example.invalid")
        XCTAssertNil(model.message)
        // The address is on screen for a person to check. Connecting is a separate tap.
        XCTAssertTrue(api.calls.isEmpty, "scanning must never contact the scanned address")
    }

    func testEachUnusableScanIsNamedAndLeavesAnEarlierCodeReady() {
        let cases: [(String, SetupModel.Message)] = [
            ("not a code", .notASetupCode),
            (LaunchDouble.olderSetupCode, .olderDashboard),
            (#"{"phleet":"setup","v":9}"#, .newerFormat),
            (#"{"phleet":"setup","v":2,"origin":"https://fleet.example.invalid"}"#, .incomplete),
            (
                #"{"phleet":"setup","v":2,"origin":"http://fleet.example.invalid","enrollmentCode":"e.s"}"#,
                .insecureAddress
            )
        ]
        for (text, expected) in cases {
            let model = makeModel(api: FakeControlAPI(), store: InMemoryCredentialStore())
            model.apply(scanned: code)

            XCTAssertFalse(model.apply(scanned: text), text)

            XCTAssertEqual(model.message, expected, text)
            XCTAssertEqual(model.code?.enrollmentCode, "enrollment-1.secret-value", text)
        }
    }

    func testConnectingWithNothingScannedSendsNothing() async {
        let api = FakeControlAPI()
        let model = makeModel(api: api, store: InMemoryCredentialStore())

        let outcome = await model.connect()

        XCTAssertNil(outcome)
        XCTAssertTrue(api.calls.isEmpty)
    }

    // MARK: - Connecting

    func testConnectingRegistersStoresAndMintsWithExactlyWhatTheCodeCarried() async throws {
        let api = FakeControlAPI()
        let store = InMemoryCredentialStore()
        let model = makeModel(api: api, store: store)
        model.apply(scanned: code)

        let outcome = try await XCTUnwrapAsync(model.connect())

        XCTAssertEqual(
            api.calls,
            [
                .registerDevice(enrollmentCode: "enrollment-1.secret-value", deviceName: "iPhone"),
                .mintToken(deviceId: "device-1", deviceSecret: "secret-1")
            ]
        )
        // The proxy's service token on both, and no access token on either: they are how one
        // is obtained.
        XCTAssertEqual(api.connections.map(\.serviceToken), Array(repeating: ControlConnection.fixture.serviceToken, count: 2))
        XCTAssertEqual(api.accessTokens, [nil, nil])
        XCTAssertEqual(api.connections.first?.origin.absoluteString, "https://fleet.example.invalid")

        let expected = DeviceCredential(
            origin: "https://fleet.example.invalid",
            accessClientId: "client-id-1",
            accessClientSecret: "client-secret-1",
            deviceId: "device-1",
            deviceSecret: "secret-1",
            clientInstanceId: "instance-1"
        )
        XCTAssertEqual(outcome.credential, expected)
        XCTAssertEqual(try store.load(), expected)
        // The holder that minted is handed on with its token, so the first request does not mint
        // a second one.
        XCTAssertEqual(outcome.tokens.mintCount, 1)
        XCTAssertNil(model.code, "the code is spent")
        XCTAssertFalse(model.isConnecting)
    }

    func testTheEnrollmentCodeIsNeverStored() async throws {
        let store = InMemoryCredentialStore()
        let model = makeModel(api: FakeControlAPI(), store: store)
        model.apply(scanned: code)

        _ = try await XCTUnwrapAsync(model.connect())

        let stored = try XCTUnwrap(try store.load())
        let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        XCTAssertFalse(json.contains("enrollment-1"))
        XCTAssertFalse(json.contains("secret-value"))
    }

    func testTheCredentialIsWrittenBeforeTheFirstTokenIsAskedFor() async {
        let api = FakeControlAPI()
        let store = OrderRecordingCredentialStore()
        var order: [String] = []
        store.onSave = { order.append("save") }

        let model = SetupModel(
            api: api,
            credentialStore: store,
            deviceName: nil,
            makeTokenHolder: { credentialStore in
                AccessTokenHolder(credentialStore: credentialStore, clock: TestClock()) { _ in
                    order.append("mint")
                    throw ControlAPIError.transport("dropped")
                }
            },
            newClientInstanceId: { "instance-1" }
        )
        model.apply(scanned: code)
        _ = await model.connect()

        // The orchestrator commits the device before it can know its answer arrived. A phone
        // that stored the secret only after a successful mint could lose it to a dropped packet.
        XCTAssertEqual(order, ["save", "mint"])
    }

    func testAWriteFailureStopsBeforeTheMint() async {
        let api = FakeControlAPI()
        let store = OrderRecordingCredentialStore()
        store.saveError = CredentialStoreError.writeFailed(status: -34018)

        let model = SetupModel(
            api: api,
            credentialStore: store,
            deviceName: nil,
            makeTokenHolder: { credentialStore in
                AccessTokenHolder(credentialStore: credentialStore, clock: TestClock()) { _ in
                    XCTFail("the mint must not be attempted after a write failure")
                    throw ControlAPIError.transport("unreachable")
                }
            },
            newClientInstanceId: { "instance-1" }
        )
        model.apply(scanned: code)

        let outcome = await model.connect()

        XCTAssertNil(outcome)
        XCTAssertEqual(model.message, .credentialWriteFailed)
    }

    func testAFirstTokenThatCannotBeHadNowStillSignsIn() async throws {
        // Registered and stored, and the code is spent: making the person scan a new one would
        // not help. The token is asked for again when it is needed.
        let api = FakeControlAPI()
        api.mintResults = [.failure(ControlAPIError.transport("dropped"))]
        let store = InMemoryCredentialStore()
        let model = makeModel(api: api, store: store)
        model.apply(scanned: code)

        let outcome = try await XCTUnwrapAsync(model.connect())

        XCTAssertEqual(outcome.credential.deviceId, "device-1")
        XCTAssertNotNil(try store.load())
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testAFirstTokenTheOrchestratorRefusesSignsNothingIn() async {
        let api = FakeControlAPI()
        api.mintResults = [.failure(ControlAPIError.unauthorized)]
        let store = InMemoryCredentialStore()
        let model = makeModel(api: api, store: store)
        model.apply(scanned: code)

        let outcome = await model.connect()

        XCTAssertNil(outcome)
        XCTAssertEqual(model.message, .signInRefused)
        XCTAssertNil(try store.load(), "a credential the orchestrator refused is no use to anyone")
    }

    // MARK: - Registration failures

    func testARefusedRegistrationStoresNothingAndNamesWhy() async {
        let cases: [(ControlAPIError, SetupModel.Message)] = [
            // Used, expired and unknown codes are one answer on purpose; one message for all.
            (.unauthorized, .codeNotAccepted),
            (.gateChanged("device_limit"), .deviceLimit),
            (.accessDenied, .accessDenied),
            (.transport("lost"), .unreachable),
            (.refused(status: 429, message: nil), .rateLimited),
            (.refused(status: 404, message: nil), .serverTooOld),
            (.refused(status: 503, message: "sign_in_unavailable"), .serverUnavailable),
            (.decoding("RegisteredDevice"), .notAFleet),
            (.refused(status: 400, message: nil), .notAFleet)
        ]
        for (error, expected) in cases {
            let api = FakeControlAPI()
            api.registerDeviceResult = .failure(error)
            let store = InMemoryCredentialStore()
            let model = makeModel(api: api, store: store)
            model.apply(scanned: code)

            let outcome = await model.connect()

            XCTAssertNil(outcome, "\(error)")
            XCTAssertEqual(model.message, expected, "\(error)")
            XCTAssertEqual(store.saveCount, 0, "\(error)")
            XCTAssertEqual(api.mintCount(), 0, "\(error)")
            XCTAssertNotNil(model.code, "the code stays ready, in case asking again can work")
        }
    }

    // MARK: - Presenting the same code again

    func testTheSameCodeAgainOverwritesTheSecretAndKeepsTheRest() async throws {
        // Before its first token, the same code answers with the same device and a rotated
        // secret.
        let existing = DeviceCredential(
            origin: "https://fleet.example.invalid",
            accessClientId: "client-id-1",
            accessClientSecret: "client-secret-1",
            deviceId: "device-1",
            deviceSecret: "old-secret",
            clientInstanceId: "instance-original",
            pushDeviceId: "push-0001"
        )
        let api = FakeControlAPI()
        api.registerDeviceResult = .success(
            RegisteredDevice(deviceId: "device-1", deviceSecret: "rotated-secret")
        )
        let store = InMemoryCredentialStore(credential: existing)
        let model = makeModel(api: api, store: store, newClientInstanceId: { "instance-fresh" })
        model.apply(scanned: code)

        let outcome = try await XCTUnwrapAsync(model.connect())

        XCTAssertEqual(outcome.credential.deviceSecret, "rotated-secret")
        XCTAssertEqual(outcome.credential.clientInstanceId, "instance-original")
        XCTAssertEqual(outcome.credential.pushDeviceId, "push-0001")
        XCTAssertTrue(
            api.calls.contains(.mintToken(deviceId: "device-1", deviceSecret: "rotated-secret"))
        )
    }

    func testADifferentDeviceGetsAFreshClientInstanceId() async throws {
        let store = InMemoryCredentialStore(
            credential: DeviceCredential(
                origin: "https://fleet.example.invalid",
                deviceId: "an-older-device",
                deviceSecret: "old",
                clientInstanceId: "instance-original"
            )
        )
        let model = makeModel(
            api: FakeControlAPI(),
            store: store,
            newClientInstanceId: { "instance-fresh" }
        )
        model.apply(scanned: code)

        let outcome = try await XCTUnwrapAsync(model.connect())

        XCTAssertEqual(outcome.credential.clientInstanceId, "instance-fresh")
    }
}

/// A store that can fail a write and report when one happened.
private final class OrderRecordingCredentialStore: CredentialStore {
    var credential: DeviceCredential?
    var saveError: Error?
    var onSave: (() -> Void)?

    func load() throws -> DeviceCredential? { credential }

    func save(_ credential: DeviceCredential) throws {
        if let saveError { throw saveError }
        onSave?()
        self.credential = credential
    }

    func delete() throws { credential = nil }
}
