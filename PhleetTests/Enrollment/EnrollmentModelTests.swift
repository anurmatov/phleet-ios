import XCTest
@testable import Phleet

/// Enrollment, including the ordering rule that stops a dropped packet locking the owner out.
@MainActor
final class EnrollmentModelTests: XCTestCase {

    private func makeModel(
        api: FakeFleetAPI,
        store: InMemoryCredentialStore,
        clock: TestClock = TestClock(),
        newClientInstanceId: @escaping () -> String = { "instance-1" }
    ) -> EnrollmentModel {
        EnrollmentModel(
            api: api,
            credentialStore: store,
            makeTokenHolder: { credentialStore in
                AccessTokenHolder(credentialStore: credentialStore, clock: clock) { credential in
                    guard let origin = credential.originURL else {
                        throw FleetAPIError.transport("malformed stored origin")
                    }
                    return try await api.mintToken(
                        origin: origin,
                        deviceId: credential.deviceId,
                        deviceSecret: credential.deviceSecret
                    )
                }
            },
            newClientInstanceId: newClientInstanceId
        )
    }

    // MARK: - The address

    func testABareHostIsNormalisedToASecureAddress() {
        guard case .success(let normalized) =
            EnrollmentModel.normalizedAddress("server.invalid") else {
            return XCTFail("a bare host must be accepted")
        }
        XCTAssertEqual(normalized, "https://server.invalid")
    }

    func testAnInsecureAddressIsRejectedRatherThanUpgraded() {
        // Silently upgrading hides that the person was handed the wrong address — and the
        // address is the one value here a human is expected to retype.
        guard case .failure(let message) =
            EnrollmentModel.normalizedAddress("http://server.invalid") else {
            return XCTFail("an http address must be refused")
        }
        XCTAssertEqual(message, .addressInsecure)
    }

    func testTheInsecureMessageIsDistinctFromEveryOtherAddressMessage() {
        let messages: [EnrollmentModel.Message] = [
            .addressInsecure, .addressEmpty, .addressMalformed, .addressMissingHost,
            .addressUserInfo
        ]
        for (index, message) in messages.enumerated() {
            for other in messages[(index + 1)...] {
                XCTAssertNotEqual(message, other)
            }
        }
    }

    func testAnEmptyAddressIsItsOwnMessage() {
        guard case .failure(let message) = EnrollmentModel.normalizedAddress("   ") else {
            return XCTFail("an empty address must be refused")
        }
        XCTAssertEqual(message, .addressEmpty)
    }

    func testTheDisplayNameIsDerivedFromTheHost() throws {
        let components = try XCTUnwrap(URLComponents(string: "https://www.server.invalid"))
        XCTAssertEqual(ServerDisplayName.derive(from: components), "server.invalid")

        let withPort = try XCTUnwrap(URLComponents(string: "https://server.invalid:8443"))
        XCTAssertEqual(ServerDisplayName.derive(from: withPort), "server.invalid:8443")
    }

    // MARK: - The code

    func testAPastedCodeIsTrimmedOnlyAtItsEdges() {
        // A value pasted out of a chat message frequently carries a trailing newline. Internal
        // whitespace is a different value, not a formatting artefact.
        XCTAssertEqual(EnrollmentModel.normalizedCode("  abc.def\n"), "abc.def")
        XCTAssertEqual(EnrollmentModel.normalizedCode("ab cd"), "ab cd")
    }

    func testTheCodeIsSentUnmodified() async {
        let api = FakeFleetAPI()
        let store = InMemoryCredentialStore()
        let model = makeModel(api: api, store: store)

        model.address = "server.invalid"
        model.enrollmentCode = "  prefix.secret-value\n"
        _ = await model.connect()

        XCTAssertEqual(api.calls.first, .registerDevice(code: "prefix.secret-value"))
    }

    // MARK: - Persist before mint

    func testTheCredentialIsWrittenBeforeTheMintIsAttempted() async {
        let api = FakeFleetAPI()
        let store = InMemoryCredentialStore()
        api.mintResults = [.failure(FleetAPIError.transport("dropped"))]

        let model = makeModel(api: api, store: store)
        model.address = "server.invalid"
        model.enrollmentCode = "code"
        let outcome = await model.connect()

        XCTAssertNil(outcome, "a failed mint does not complete enrollment")

        // The server commits the device record before it can know its response arrived. A client
        // that persists only after a successful mint can lose the secret to a dropped packet
        // while the server holds an active device that blocks re-registration.
        let stored = try? store.load()
        XCTAssertEqual(stored?.deviceId, "device-1")
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testTheWriteHappensBeforeTheMintCallInOrder() async {
        let api = FakeFleetAPI()
        let store = OrderRecordingCredentialStore()
        var order: [String] = []
        store.onSave = { order.append("save") }
        api.mintResults = [.failure(FleetAPIError.transport("dropped"))]

        let model = EnrollmentModel(
            api: api,
            credentialStore: store,
            makeTokenHolder: { credentialStore in
                AccessTokenHolder(credentialStore: credentialStore, clock: TestClock()) { _ in
                    order.append("mint")
                    throw FleetAPIError.transport("dropped")
                }
            },
            newClientInstanceId: { "instance-1" }
        )
        model.address = "server.invalid"
        model.enrollmentCode = "code"
        _ = await model.connect()

        XCTAssertEqual(order, ["save", "mint"])
    }

    func testAWriteFailureAbortsBeforeTheMint() async {
        let api = FakeFleetAPI()
        let store = OrderRecordingCredentialStore()
        store.saveError = CredentialStoreError.writeFailed(status: -34018)

        let model = makeModel(api: api, store: InMemoryCredentialStore())
        _ = model

        let failing = EnrollmentModel(
            api: api,
            credentialStore: store,
            makeTokenHolder: { credentialStore in
                AccessTokenHolder(credentialStore: credentialStore, clock: TestClock()) { _ in
                    XCTFail("the mint must not be attempted after a write failure")
                    throw FleetAPIError.transport("unreachable")
                }
            },
            newClientInstanceId: { "instance-1" }
        )
        failing.address = "server.invalid"
        failing.enrollmentCode = "code"

        let outcome = await failing.connect()
        XCTAssertNil(outcome)
        XCTAssertEqual(failing.formMessage, .credentialWriteFailed)
    }

    // MARK: - Re-presentation

    func testRePresentingTheSameCodeOverwritesTheStoredSecret() async {
        let api = FakeFleetAPI()
        let existing = DeviceCredential(
            origin: "https://server.invalid",
            deviceId: "device-1",
            deviceSecret: "old-secret",
            clientInstanceId: "instance-original"
        )
        let store = InMemoryCredentialStore(credential: existing)

        // The same deviceId with a rotated secret, which is what the re-presentation window
        // returns.
        api.registerResults = [
            .success(RegisterDeviceResponse(
                deviceId: "device-1",
                deviceSecret: "rotated-secret",
                protocolVersion: ProtocolVersion.current
            ))
        ]

        let model = makeModel(api: api, store: store)
        model.address = "server.invalid"
        model.enrollmentCode = "code"
        let outcome = await model.connect()

        XCTAssertEqual(outcome?.credential.deviceSecret, "rotated-secret")
        XCTAssertEqual(
            outcome?.credential.clientInstanceId,
            "instance-original",
            "the same device keeps its cursor bookkeeping"
        )

        // And the authenticated call that follows uses the new secret, not the old one.
        XCTAssertTrue(
            api.calls.contains(.mintToken(deviceId: "device-1", deviceSecret: "rotated-secret"))
        )
    }

    func testADifferentDeviceGetsAFreshClientInstanceId() async {
        let api = FakeFleetAPI()
        let store = InMemoryCredentialStore(
            credential: DeviceCredential(
                origin: "https://server.invalid",
                deviceId: "an-older-device",
                deviceSecret: "old",
                clientInstanceId: "instance-original"
            )
        )

        let model = makeModel(api: api, store: store, newClientInstanceId: { "instance-fresh" })
        model.address = "server.invalid"
        model.enrollmentCode = "code"
        let outcome = await model.connect()

        XCTAssertEqual(outcome?.credential.clientInstanceId, "instance-fresh")
    }

    // MARK: - Failures

    func testDeviceLimitNamesOperatorRevocationAndOffersNoReplace() async {
        let api = FakeFleetAPI()
        api.registerResults = [
            .failure(FleetAPIError.refused(.deviceLimit, status: 409, message: nil))
        ]

        let model = makeModel(api: api, store: InMemoryCredentialStore())
        model.address = "server.invalid"
        model.enrollmentCode = "code"
        _ = await model.connect()

        XCTAssertEqual(model.formMessage, .deviceLimit)
        // No north route can replace the other device, and an unauthenticated one would be a
        // one-request denial of service against the only way in. There is no control to render.
        XCTAssertEqual(api.calls.count, 1)
    }

    func testEveryAuthenticationFailureProducesOneIdenticalMessage() async {
        // Expired, already-burned, unknown and wrong-secret are indistinguishable by contract,
        // and there is deliberately no branch in the app that tells them apart.
        for _ in 0..<4 {
            let api = FakeFleetAPI()
            api.registerResults = [.failure(FleetAPIError.unauthorized)]

            let model = makeModel(api: api, store: InMemoryCredentialStore())
            model.address = "server.invalid"
            model.enrollmentCode = "code"
            _ = await model.connect()

            XCTAssertEqual(model.formMessage, .codeNotAccepted)
        }
    }

    func testAFailedSessionReadStillCompletesEnrollment() async {
        let api = FakeFleetAPI()
        api.sessionResults = [.failure(FleetAPIError.unexpectedStatus(503))]

        let model = makeModel(api: api, store: InMemoryCredentialStore())
        model.address = "server.invalid"
        model.enrollmentCode = "code"
        let outcome = await model.connect()

        // The credential is what matters. The contract's documented defaults stand in until the
        // next foreground retries it.
        XCTAssertNotNil(outcome)
        XCTAssertNil(outcome?.agentLabel)
        XCTAssertEqual(outcome?.limits, SessionLimits.documentedDefaults)
    }

    func testTheHappyPathRunsRegisterThenMintThenSession() async {
        let api = FakeFleetAPI()
        let model = makeModel(api: api, store: InMemoryCredentialStore())
        model.address = "server.invalid"
        model.enrollmentCode = "code"
        let outcome = await model.connect()

        XCTAssertNotNil(outcome)
        XCTAssertEqual(outcome?.displayName, "server.invalid")
        XCTAssertEqual(outcome?.principalId, "principal-1")
        XCTAssertEqual(
            api.calls,
            [
                .registerDevice(code: "code"),
                .mintToken(deviceId: "device-1", deviceSecret: "secret-1"),
                .session
            ]
        )
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
