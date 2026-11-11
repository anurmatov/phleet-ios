import XCTest
@testable import Phleet

/// The control plane's place in the composition root.
///
/// The property worth pinning is independence: the control-plane connection and the device
/// enrollment are stored apart and neither one's lifecycle touches the other's.
@MainActor
final class ControlEnvironmentTests: XCTestCase {

    private final class UnreadableStore: ControlCredentialStore {
        private(set) var deleteCount = 0
        func load() throws -> ControlCredential? {
            throw CredentialStoreError.unavailable(status: -25308)
        }
        func save(_ credential: ControlCredential) throws {}
        func delete() throws { deleteCount += 1 }
    }

    private let credential = ControlCredential(
        origin: "https://fleet.example.invalid",
        accessClientId: "client-id-1",
        accessClientSecret: "client-secret-1",
        operatorToken: "operator-token-1"
    )

    private func makeEnvironment(
        controlStore: ControlCredentialStore,
        deviceStore: InMemoryCredentialStore = InMemoryCredentialStore()
    ) -> AppEnvironment {
        AppEnvironment(
            credentialStore: deviceStore,
            api: FakeFleetAPI(),
            stream: FakeConversationStream(),
            controlCredentialStore: controlStore,
            controlAPI: FakeControlAPI(),
            controlStream: FakeControlLiveStream(),
            launchArguments: [],
            launchEnvironment: [:]
        )
    }

    func testAFreshInstallHasNoControlPlane() {
        let environment = makeEnvironment(controlStore: InMemoryControlCredentialStore())

        XCTAssertNil(environment.controlPlane)
        XCTAssertNil(environment.controlCredential)
        XCTAssertFalse(environment.controlCredentialUnavailable)
    }

    func testAStoredConnectionIsRestoredWithoutEnrollment() {
        let environment = makeEnvironment(
            controlStore: InMemoryControlCredentialStore(credential: credential)
        )

        XCTAssertEqual(environment.controlCredential, credential)
        XCTAssertEqual(environment.controlPlane?.canDecide, true)
        // The thread is a separate surface with a separate credential, and has none here.
        XCTAssertEqual(environment.route, .enrollment)
    }

    func testAReadOnlyConnectionRestoresAsReadOnly() {
        let readOnly = ControlCredential(
            origin: "https://fleet.example.invalid",
            accessClientId: nil,
            accessClientSecret: nil,
            operatorToken: nil
        )
        let environment = makeEnvironment(
            controlStore: InMemoryControlCredentialStore(credential: readOnly)
        )
        XCTAssertEqual(environment.controlPlane?.canDecide, false)
    }

    func testAnUnreadableConnectionIsReportedAndNeverDeleted() {
        // A read that fails while the device is locked must not destroy a working connection.
        let store = UnreadableStore()
        let environment = makeEnvironment(controlStore: store)

        XCTAssertTrue(environment.controlCredentialUnavailable)
        XCTAssertNil(environment.controlPlane)
        XCTAssertEqual(store.deleteCount, 0)
    }

    func testFinishingSetupAdoptsTheConnection() {
        let environment = makeEnvironment(controlStore: InMemoryControlCredentialStore())

        environment.finishControlSetup(credential)

        XCTAssertEqual(environment.controlCredential, credential)
        XCTAssertNotNil(environment.controlPlane)
    }

    func testRemovingTheConnectionDeletesItAndLeavesTheDeviceCredentialAlone() throws {
        let controlStore = InMemoryControlCredentialStore(credential: credential)
        let deviceStore = InMemoryCredentialStore(
            credential: DeviceCredential(
                origin: "https://server.invalid",
                deviceId: "device-1",
                deviceSecret: "secret-1",
                clientInstanceId: "instance-1"
            )
        )
        let environment = makeEnvironment(controlStore: controlStore, deviceStore: deviceStore)

        environment.removeControlConnection()

        XCTAssertNil(environment.controlPlane)
        XCTAssertNil(environment.controlCredential)
        XCTAssertNil(try controlStore.load())
        XCTAssertEqual(controlStore.deleteCount, 1)
        XCTAssertEqual(deviceStore.deleteCount, 0, "the thread's credential is a different item")
        XCTAssertEqual(environment.route, .agent)
    }

    func testTheScriptedBackendNeverTouchesTheKeychain() {
        let environment = AppEnvironment(
            launchArguments: [LaunchArguments.scriptedBackend],
            launchEnvironment: [:]
        )
        XCTAssertTrue(environment.controlCredentialStore is InMemoryControlCredentialStore)
        XCTAssertTrue(environment.controlAPI is ScriptedControlBackend)
        XCTAssertNil(environment.controlPlane)
    }
}
