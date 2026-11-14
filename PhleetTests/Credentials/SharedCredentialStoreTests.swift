import Security
import XCTest
@testable import Phleet

/// A store that answers what a test tells it to, standing in for one keychain access group.
private final class ScriptedStore: CredentialStore {
    var credential: DeviceCredential?
    /// Thrown by every call, when set: the system refusing this access group.
    var refusal: CredentialStoreError?
    private(set) var saves = 0
    private(set) var deletes = 0

    init(credential: DeviceCredential? = nil) {
        self.credential = credential
    }

    func load() throws -> DeviceCredential? {
        if let refusal { throw refusal }
        return credential
    }

    func save(_ credential: DeviceCredential) throws {
        if let refusal { throw refusal }
        self.credential = credential
        saves += 1
    }

    func delete() throws {
        if let refusal { throw refusal }
        credential = nil
        deletes += 1
    }
}

/// The sign-in kept where the extensions can read it, without signing in ever depending on that.
final class SharedCredentialStoreTests: XCTestCase {

    private let missingEntitlement = CredentialStoreError.unavailable(status: errSecMissingEntitlement)

    func testASignInIsWrittenToTheSharedPlaceAndReadBackFromIt() throws {
        let shared = ScriptedStore()
        let own = ScriptedStore()
        let store = SharedCredentialStore(shared: shared, own: own)

        try store.save(.fixture)

        XCTAssertEqual(shared.credential, .fixture)
        XCTAssertNil(own.credential, "one copy, where the extensions can read it")
        XCTAssertEqual(try store.load(), .fixture)
    }

    func testASignInFromAnEarlierBuildIsMovedAndNotLeftBehind() throws {
        let shared = ScriptedStore()
        let own = ScriptedStore(credential: .fixture)
        let store = SharedCredentialStore(shared: shared, own: own)

        XCTAssertEqual(try store.load(), .fixture)

        XCTAssertEqual(shared.credential, .fixture)
        XCTAssertNil(own.credential)
        XCTAssertEqual(own.deletes, 1)
        // The second read finds it where it now lives and moves nothing.
        XCTAssertEqual(try store.load(), .fixture)
        XCTAssertEqual(shared.saves, 1)
    }

    func testABuildWithoutTheAppGroupKeepsItsSignInWhereItAlwaysWas() throws {
        let shared = ScriptedStore()
        shared.refusal = missingEntitlement
        let own = ScriptedStore(credential: .fixture)
        let store = SharedCredentialStore(shared: shared, own: own)

        XCTAssertEqual(try store.load(), .fixture, "signing in must not depend on the extensions' entitlement")
        XCTAssertEqual(own.credential, .fixture, "nothing is moved to a place that cannot be used")

        let rotated = DeviceCredential.fixture.withPushDeviceId("push-1")
        try store.save(rotated)
        XCTAssertEqual(own.credential, rotated)

        try store.delete()
        XCTAssertNil(own.credential)
    }

    func testAFreshInstallHasNoSignInInEitherPlace() throws {
        let store = SharedCredentialStore(shared: ScriptedStore(), own: ScriptedStore())
        XCTAssertNil(try store.load())
    }

    func testASharedPlaceThatCannotBeReadIsNotMistakenForNoSignIn() {
        // Locked, or failing for a reason that is not "this build may not use it": the same rule
        // as the keychain store's own — it throws, and nothing is deleted or overwritten.
        let shared = ScriptedStore(credential: .fixture)
        shared.refusal = .unavailable(status: errSecInteractionNotAllowed)
        let own = ScriptedStore()
        let store = SharedCredentialStore(shared: shared, own: own)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? CredentialStoreError,
                .unavailable(status: errSecInteractionNotAllowed)
            )
        }
        XCTAssertEqual(own.saves, 0)
    }

    func testAMoveThatCannotFinishLeavesTheSignInWhereItWasFound() throws {
        let shared = ScriptedStore()
        let own = ScriptedStore(credential: .fixture)
        // The shared place can be read, but a write to it fails.
        let store = SharedCredentialStore(shared: FailingWrites(wrapping: shared), own: own)

        XCTAssertEqual(try store.load(), .fixture)

        XCTAssertEqual(own.credential, .fixture, "not deleted before it was safely copied")
        XCTAssertNil(shared.credential)
    }

    func testSigningOutRemovesBothCopiesAndReportsAFailureOnlyAfterTryingBoth() {
        let shared = ScriptedStore(credential: .fixture)
        shared.refusal = .writeFailed(status: errSecInteractionNotAllowed)
        let own = ScriptedStore(credential: .fixture)
        let store = SharedCredentialStore(shared: shared, own: own)

        XCTAssertThrowsError(try store.delete())

        // A sign-out that stopped at the first failure would leave this copy to sign the phone
        // back in at the next launch.
        XCTAssertNil(own.credential)
    }

    func testOnlyTheMissingEntitlementStatusCountsAsNotAllowedToUseTheGroup() {
        XCTAssertTrue(SharedCredentialStore.isMissingEntitlement(missingEntitlement))
        XCTAssertTrue(
            SharedCredentialStore.isMissingEntitlement(
                CredentialStoreError.writeFailed(status: errSecMissingEntitlement)
            )
        )
        XCTAssertFalse(
            SharedCredentialStore.isMissingEntitlement(
                CredentialStoreError.unavailable(status: errSecInteractionNotAllowed)
            )
        )
        XCTAssertFalse(SharedCredentialStore.isMissingEntitlement(CredentialStoreError.malformedPayload))
    }

    func testTheSharedItemIsConfinedToTheAppGroupAndKeepsItsProtection() {
        let query = KeychainCredentialStore.baseQuery(
            service: "service",
            account: "account",
            accessGroup: AppGroup.identifier
        )
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, AppGroup.identifier)

        let attributes = KeychainCredentialStore.writeAttributes(
            service: "service",
            account: "account",
            payload: Data(),
            accessGroup: AppGroup.identifier
        )
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "sharing with the extensions changes who can read it, not when or where it may travel"
        )

        // With no group named, the query is the one every earlier build made.
        XCTAssertNil(
            KeychainCredentialStore.baseQuery(service: "service", account: "account")[
                kSecAttrAccessGroup as String
            ]
        )
    }
}

/// Reads through, and refuses every write.
private final class FailingWrites: CredentialStore {
    private let wrapped: CredentialStore

    init(wrapping wrapped: CredentialStore) {
        self.wrapped = wrapped
    }

    func load() throws -> DeviceCredential? { try wrapped.load() }

    func save(_ credential: DeviceCredential) throws {
        throw CredentialStoreError.writeFailed(status: errSecInteractionNotAllowed)
    }

    func delete() throws {
        throw CredentialStoreError.writeFailed(status: errSecInteractionNotAllowed)
    }
}
