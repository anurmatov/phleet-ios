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
