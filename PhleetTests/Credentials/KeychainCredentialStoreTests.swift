import XCTest
@testable import Phleet

/// The credential at rest.
///
/// Each test uses its own service name so runs cannot collide, and cleans up after itself.
final class KeychainCredentialStoreTests: XCTestCase {

    private var service = ""
    private var store = KeychainCredentialStore()

    private let credential = DeviceCredential(
        origin: "https://server.invalid",
        deviceId: "device-1",
        deviceSecret: "secret-1",
        clientInstanceId: "instance-1"
    )

    override func setUp() {
        super.setUp()
        service = "com.anvarlab.phleet.tests." + UUID().uuidString
        store = KeychainCredentialStore(service: service, account: "device")
    }

    override func tearDown() {
        try? store.delete()
        super.tearDown()
    }

    /// The one thing in this file that is a security decision rather than plumbing.
    ///
    /// `AfterFirstUnlock` so a reconnect can read the credential with the screen locked, and
    /// `ThisDeviceOnly` because it excludes the item from iCloud Keychain and encrypted backups.
    /// A restore to a new device therefore arrives with **no** credential, which is exactly what
    /// the contract requires: a secure-store loss is recovered by revoke-and-re-enroll, never a
    /// silent re-issue.
    func testTheWriteAttributesPinTheAccessibilityClass() {
        let attributes = KeychainCredentialStore.writeAttributes(
            service: service,
            account: "device",
            payload: Data()
        )

        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as! CFString,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        XCTAssertEqual(attributes[kSecClass as String] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, service)
    }

    /// The first thing to read when this file goes red.
    ///
    /// `-34018` is `errSecMissingEntitlement`, and on the simulator it means the host process has
    /// no keychain access group — which happens when the build is not signed at all, or when the
    /// `keychain-access-groups` entitlement is dropped. Neither is a fault in the store; both
    /// silence the only coverage the device secret has.
    func testTheTestHostCanReachTheKeychain() {
        XCTAssertNoThrow(
            try store.save(credential),
            "the app host has no keychain access group. Check keychain-access-groups in "
                + "Phleet/Phleet.entitlements and the ad-hoc CODE_SIGN_IDENTITY in the Makefile; "
                + "-34018 is errSecMissingEntitlement, not a store defect"
        )
    }

    func testAFreshInstallReportsNoCredentialRatherThanFailing() throws {
        XCTAssertNil(try store.load())
    }

    func testRoundTrip() throws {
        try store.save(credential)
        XCTAssertEqual(try store.load(), credential)
    }

    func testARotatedSecretOverwritesTheStoredItem() throws {
        try store.save(credential)
        let rotated = credential.rotatingSecret(to: "secret-2")
        try store.save(rotated)

        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.deviceSecret, "secret-2")
        XCTAssertEqual(
            loaded.clientInstanceId,
            "instance-1",
            "the same device keeps its cursor bookkeeping across a rotation"
        )
    }

    func testDeleteRemovesTheItemAndIsIdempotent() throws {
        try store.save(credential)
        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.delete())
    }

    func testThePersistedPayloadHoldsExactlyTheFourFields() throws {
        // The access token is never written anywhere: it is derivable at any time from the
        // device id and secret, and persisting it would add a second secret at rest.
        let encoded = try JSONEncoder().encode(credential)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let keys = Set(try XCTUnwrap(object).keys)

        XCTAssertEqual(keys, ["origin", "deviceId", "deviceSecret", "clientInstanceId"])
    }
}
