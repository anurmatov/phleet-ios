import XCTest
@testable import Phleet

/// Connecting to an orchestrator: what is checked before anything is stored.
@MainActor
final class ControlSetupModelTests: XCTestCase {

    private func makeModel(
        api: FakeControlAPI = FakeControlAPI(),
        store: InMemoryControlCredentialStore = InMemoryControlCredentialStore()
    ) -> ControlSetupModel {
        let model = ControlSetupModel(api: api, credentialStore: store)
        model.address = "fleet.example.invalid"
        model.accessClientId = "client-id-1"
        model.accessClientSecret = "client-secret-1"
        model.operatorToken = "operator-token-1"
        return model
    }

    // MARK: - The address

    func testABareHostBecomesASecureOrigin() {
        XCTAssertEqual(
            ControlSetupModel.validatedOrigin("  fleet.example.invalid \n"),
            .success("https://fleet.example.invalid")
        )
    }

    func testAnInsecureAddressIsRefusedRatherThanUpgraded() {
        XCTAssertEqual(
            ControlSetupModel.validatedOrigin("http://fleet.example.invalid"),
            .failure(.addressInsecure)
        )
    }

    func testAnAddressProblemIsNamed() {
        XCTAssertEqual(ControlSetupModel.validatedOrigin("   "), .failure(.addressEmpty))
        XCTAssertEqual(
            ControlSetupModel.validatedOrigin("https://someone:secret@fleet.example.invalid"),
            .failure(.addressUserInfo)
        )
        XCTAssertEqual(ControlSetupModel.validatedOrigin("https://"), .failure(.addressMissingHost))
    }

    func testABadAddressNeverReachesTheNetwork() async {
        let api = FakeControlAPI()
        let store = InMemoryControlCredentialStore()
        let model = makeModel(api: api, store: store)
        model.address = "http://fleet.example.invalid"

        let credential = await model.connect()

        XCTAssertNil(credential)
        XCTAssertEqual(model.addressMessage, .addressInsecure)
        XCTAssertTrue(api.calls.isEmpty)
        XCTAssertEqual(store.saveCount, 0)
    }

    // MARK: - The service token

    func testHalfAServiceTokenIsRefusedBeforeAnythingIsSent() async {
        let api = FakeControlAPI()
        let model = makeModel(api: api)
        model.accessClientSecret = "  "

        let credential = await model.connect()

        XCTAssertNil(credential)
        XCTAssertEqual(model.serviceTokenMessage, .serviceTokenIncomplete)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testNoServiceTokenAtAllIsAnOrdinaryConnection() async throws {
        let api = FakeControlAPI()
        let model = makeModel(api: api)
        model.accessClientId = ""
        model.accessClientSecret = ""

        let credential = try await XCTUnwrapAsync(model.connect())

        XCTAssertNil(credential.serviceToken)
        XCTAssertNil(api.connections.first?.serviceToken)
    }

    // MARK: - The probe

    func testConnectingProbesWithExactlyWhatWillBeStored() async throws {
        let api = FakeControlAPI()
        let store = InMemoryControlCredentialStore()
        let model = makeModel(api: api, store: store)
        model.accessClientId = " client-id-1 "
        model.operatorToken = " operator-token-1\n"

        let credential = try await XCTUnwrapAsync(model.connect())

        XCTAssertEqual(api.calls, [.agents])
        XCTAssertEqual(api.connections.first, credential.connection)
        XCTAssertEqual(
            credential,
            ControlCredential(
                origin: "https://fleet.example.invalid",
                accessClientId: "client-id-1",
                accessClientSecret: "client-secret-1",
                operatorToken: "operator-token-1"
            )
        )
        XCTAssertEqual(try store.load(), credential)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertFalse(model.isConnecting)
    }

    func testAnEmptyOperatorTokenStoresAReadOnlyConnection() async throws {
        let model = makeModel()
        model.operatorToken = "   "

        let credential = try await XCTUnwrapAsync(model.connect())

        XCTAssertNil(credential.operatorToken)
        XCTAssertFalse(credential.canDecide)
    }

    func testAFailedProbeStoresNothingAndNamesTheProblem() async {
        let cases: [(ControlAPIError, ControlSetupModel.Message)] = [
            (.accessDenied, .accessDenied),
            (.transport("x"), .unreachable),
            (.decoding("x"), .notAnOrchestrator),
            (.refused(status: 404, message: nil), .notAnOrchestrator)
        ]
        for (error, expected) in cases {
            let api = FakeControlAPI()
            api.agentsResult = .failure(error)
            let store = InMemoryControlCredentialStore()
            let model = makeModel(api: api, store: store)

            let credential = await model.connect()

            XCTAssertNil(credential, "\(error)")
            XCTAssertEqual(model.formMessage, expected, "\(error)")
            XCTAssertEqual(store.saveCount, 0, "a connection that was never proved is not stored")
            XCTAssertFalse(model.isConnecting)
        }
    }

    func testAMessageFromAnEarlierAttemptIsClearedByTheNext() async {
        let api = FakeControlAPI()
        api.agentsResult = .failure(ControlAPIError.accessDenied)
        let model = makeModel(api: api)
        await model.connect()
        XCTAssertEqual(model.formMessage, .accessDenied)

        api.agentsResult = .success([])
        await model.connect()

        XCTAssertNil(model.formMessage)
    }

    // MARK: - The credential

    func testACredentialNormalisesEmptyPartsToAbsentOnes() {
        let credential = ControlCredential(
            origin: "https://fleet.example.invalid",
            accessClientId: "  ",
            accessClientSecret: "client-secret-1",
            operatorToken: ""
        )
        XCTAssertNil(credential.accessClientId)
        XCTAssertNil(credential.serviceToken, "half a service token is no service token")
        XCTAssertNil(credential.operatorToken)
        XCTAssertFalse(credential.canDecide)
    }

    func testACredentialSurvivesStorage() throws {
        let credential = ControlCredential(
            origin: "https://fleet.example.invalid",
            accessClientId: "client-id-1",
            accessClientSecret: "client-secret-1",
            operatorToken: "operator-token-1"
        )
        let decoded = try JSONDecoder().decode(
            ControlCredential.self,
            from: JSONEncoder().encode(credential)
        )
        XCTAssertEqual(decoded, credential)
        XCTAssertEqual(decoded.connection, .fixture)
    }

    /// The same security decision the device credential makes, asserted for this item too: it
    /// must not migrate to another device with an operator token inside it.
    func testTheKeychainItemIsSeparateFromTheDeviceCredentialAndDeviceBound() throws {
        XCTAssertNotEqual(
            KeychainControlCredentialStore.defaultService,
            "com.anvarlab.phleet.device-credential"
        )

        let service = "com.anvarlab.phleet.tests." + UUID().uuidString
        let store = KeychainControlCredentialStore(service: service, account: "orchestrator")
        defer { try? store.delete() }

        XCTAssertNil(try store.load())

        let credential = ControlCredential(
            origin: "https://fleet.example.invalid",
            accessClientId: "client-id-1",
            accessClientSecret: "client-secret-1",
            operatorToken: "operator-token-1"
        )
        try store.save(credential)
        XCTAssertEqual(try store.load(), credential)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "orchestrator",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )

        try store.delete()
        XCTAssertNil(try store.load())
    }
}

/// `XCTUnwrap` for a value produced by an `await`.
func XCTUnwrapAsync<Value>(
    _ value: Value?,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Value {
    try XCTUnwrap(value, file: file, line: line)
}
