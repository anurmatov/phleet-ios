import Security
import XCTest
@testable import Phleet

/// What earlier builds kept in the Keychain is taken away at launch, and one thing in it is kept.
///
/// Each test writes the old items under its own service names, so runs cannot collide with each
/// other or with a real install, and cleans up after itself.
final class LegacyCredentialStoreTests: XCTestCase {

    private var chatService = ""
    private var fleetService = ""
    private var store = KeychainLegacyCredentialStore()

    override func setUp() {
        super.setUp()
        let suffix = UUID().uuidString
        chatService = "com.anvarlab.phleet.tests.legacy-chat." + suffix
        fleetService = "com.anvarlab.phleet.tests.legacy-fleet." + suffix
        store = KeychainLegacyCredentialStore(
            chatService: chatService,
            chatAccount: "device",
            fleetService: fleetService,
            fleetAccount: "orchestrator"
        )
    }

    override func tearDown() {
        delete(chatService, "device")
        delete(fleetService, "orchestrator")
        super.tearDown()
    }

    private func write(_ json: String, _ service: String, _ account: String) {
        let attributes = KeychainCredentialStore.writeAttributes(
            service: service,
            account: account,
            payload: Data(json.utf8)
        )
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
    }

    private func exists(_ service: String, _ account: String) -> Bool {
        var query = KeychainCredentialStore.baseQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func delete(_ service: String, _ account: String) {
        SecItemDelete(
            KeychainCredentialStore.baseQuery(service: service, account: account) as CFDictionary
        )
    }

    func testBothOldItemsAreDeletedAndTheNotificationWishIsKept() {
        write(
            #"{"origin":"https://server.invalid","deviceId":"d","deviceSecret":"s","clientInstanceId":"i"}"#,
            chatService,
            "device"
        )
        write(
            #"{"origin":"https://fleet.example.invalid","operatorToken":"operator-token-1","pushDeviceId":"push-0001"}"#,
            fleetService,
            "orchestrator"
        )

        let wish = store.takeNotificationWish()

        XCTAssertEqual(
            wish,
            LegacyNotificationWish(origin: "https://fleet.example.invalid", pushDeviceId: "push-0001")
        )
        // The operator token must not outlive the build that needed it.
        XCTAssertFalse(exists(fleetService, "orchestrator"))
        XCTAssertFalse(exists(chatService, "device"))
        XCTAssertNil(store.takeNotificationWish(), "taken once, and gone")
    }

    func testAnOldConnectionWithNotificationsOffIsDeletedAndLeavesNothingToKeep() {
        write(
            #"{"origin":"https://fleet.example.invalid","operatorToken":"operator-token-1"}"#,
            fleetService,
            "orchestrator"
        )

        XCTAssertNil(store.takeNotificationWish())
        XCTAssertFalse(exists(fleetService, "orchestrator"))
    }

    func testAnUnreadableOldItemIsStillDeleted() {
        write("not json", fleetService, "orchestrator")

        XCTAssertNil(store.takeNotificationWish())
        XCTAssertFalse(exists(fleetService, "orchestrator"))
    }

    func testNothingLeftBehindIsAnOrdinaryLaunch() {
        XCTAssertNil(store.takeNotificationWish())
    }
}
