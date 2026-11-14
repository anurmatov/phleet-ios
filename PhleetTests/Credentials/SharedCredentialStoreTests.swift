import Security
import XCTest
@testable import Phleet

/// The calls made on a pair of scripted stores, in the order they were made.
private final class Journal {
    var entries: [String] = []
}

/// A store that answers what a test tells it to, standing in for one keychain access group.
private final class ScriptedStore: CredentialStore {
    var credential: DeviceCredential?
    /// Thrown by every call, when set: the system refusing this access group.
    var refusal: CredentialStoreError?
    /// What a read answers once something has been saved, when set: a readback that fails,
    /// finds nothing, or finds something other than what was written.
    var readback: Result<DeviceCredential?, CredentialStoreError>?
    /// Thrown by `delete()` alone, when set.
    var deleteRefusal: CredentialStoreError?
    private(set) var saves = 0
    private(set) var deletes = 0
    private let name: String
    private let journal: Journal?

    init(credential: DeviceCredential? = nil, name: String = "", journal: Journal? = nil) {
        self.credential = credential
        self.name = name
        self.journal = journal
    }

    func load() throws -> DeviceCredential? {
        journal?.entries.append(name + ".load")
        if let refusal { throw refusal }
        if saves > 0, let readback { return try readback.get() }
        return credential
    }

    func save(_ credential: DeviceCredential) throws {
        journal?.entries.append(name + ".save")
        if let refusal { throw refusal }
        self.credential = credential
        saves += 1
    }

    func delete() throws {
        journal?.entries.append(name + ".delete")
        if let refusal { throw refusal }
        if let deleteRefusal { throw deleteRefusal }
        credential = nil
        deletes += 1
    }
}

/// The sign-in kept where the extensions can read it, without signing in ever depending on that.
final class SharedCredentialStoreTests: XCTestCase {

    private let missingEntitlement = CredentialStoreError.unavailable(status: errSecMissingEntitlement)

    /// The three ways a readback can disagree with what was written, and what a save reports.
    private let readbackFaults: [(Result<DeviceCredential?, CredentialStoreError>, CredentialStoreError)] = [
        (.failure(.unavailable(status: errSecInteractionNotAllowed)), .unavailable(status: errSecInteractionNotAllowed)),
        (.success(nil), .malformedPayload),
        (.success(DeviceCredential.fixture.rotatingSecret(to: "secret-other")), .malformedPayload)
    ]

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

    func testASaveIsReadBackBeforeTheOwnCopyIsRemoved() throws {
        let journal = Journal()
        let shared = ScriptedStore(name: "shared", journal: journal)
        let own = ScriptedStore(credential: .fixture, name: "own", journal: journal)

        try SharedCredentialStore(shared: shared, own: own).save(.fixture.withPushDeviceId("push-1"))

        XCTAssertEqual(journal.entries, ["shared.save", "shared.load", "own.delete"])
    }

    func testAMoveIsReadBackBeforeTheOwnCopyIsRemoved() throws {
        let journal = Journal()
        let shared = ScriptedStore(name: "shared", journal: journal)
        let own = ScriptedStore(credential: .fixture, name: "own", journal: journal)

        XCTAssertEqual(try SharedCredentialStore(shared: shared, own: own).load(), .fixture)

        XCTAssertEqual(
            journal.entries,
            ["shared.load", "own.load", "shared.save", "shared.load", "own.delete"]
        )
    }

    func testASaveWhoseReadbackDisagreesIsReportedAndTheOwnCopyIsKept() {
        for (readback, expected) in readbackFaults {
            let shared = ScriptedStore()
            shared.readback = readback
            let own = ScriptedStore(credential: .fixture)
            let store = SharedCredentialStore(shared: shared, own: own)

            XCTAssertThrowsError(try store.save(.fixture.withPushDeviceId("push-1"))) { error in
                XCTAssertEqual(error as? CredentialStoreError, expected)
            }
            XCTAssertEqual(own.credential, .fixture, "not removed before the copy is known good")
            XCTAssertEqual(own.deletes, 0)
        }
    }

    func testAMoveWhoseReadbackDisagreesReturnsAndKeepsTheOriginal() throws {
        for (readback, _) in readbackFaults {
            let shared = ScriptedStore()
            shared.readback = readback
            let own = ScriptedStore(credential: .fixture)

            XCTAssertEqual(try SharedCredentialStore(shared: shared, own: own).load(), .fixture)
            XCTAssertEqual(own.credential, .fixture)
            XCTAssertEqual(own.deletes, 0)
        }
    }

    func testACleanupThatFailsAfterAVerifiedCopyIsNotReportedAndKeepsBoth() throws {
        let shared = ScriptedStore()
        let own = ScriptedStore(credential: .fixture)
        own.deleteRefusal = .writeFailed(status: errSecInteractionNotAllowed)
        let store = SharedCredentialStore(shared: shared, own: own)

        XCTAssertEqual(try store.load(), .fixture)
        XCTAssertEqual(shared.credential, .fixture)
        XCTAssertEqual(own.credential, .fixture, "the duplicate stays when its deletion fails")

        let rotated = DeviceCredential.fixture.rotatingSecret(to: "secret-2")
        XCTAssertNoThrow(try store.save(rotated))
        XCTAssertEqual(shared.credential, rotated)
        XCTAssertEqual(try store.load(), rotated, "the shared copy is the one read")
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
        XCTAssertFalse(
            SharedCredentialStore.isMissingEntitlement(CredentialStoreError.invalidAccessGroup),
            "a store with no usable group is a fault to report, not a reason to fall back"
        )
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
