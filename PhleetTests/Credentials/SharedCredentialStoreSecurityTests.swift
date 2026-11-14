import Security
import XCTest
@testable import Phleet

/// Real Security, with every call recorded by operation and by the access group its query named,
/// and any one call replaceable by a test.
///
/// A failure is injected only at the call that fails. Every other call reaches the real keychain,
/// so what a test reads back afterwards is what the keychain actually holds.
final class SecurityProbe {

    enum Operation: Equatable {
        case copyMatching, add, update, delete
    }

    struct Call: Equatable {
        let operation: Operation
        let accessGroup: String?
    }

    private(set) var calls: [Call] = []

    /// A status to answer instead of the real call, given the operation and how many of that
    /// operation ran before it; `nil` lets the call through.
    var failure: (Operation, Int) -> OSStatus? = { _, _ in nil }

    /// Bytes a read answers with instead of the real call, given how many reads ran before it;
    /// `nil` lets the read through.
    var substitutedRead: (Int) -> Data? = { _ in nil }

    func count(_ operation: Operation) -> Int {
        calls.filter { $0.operation == operation }.count
    }

    var security: KeychainCredentialStore.SecurityCalls {
        KeychainCredentialStore.SecurityCalls(
            copyMatching: { query, result in
                let earlier = self.record(.copyMatching, query)
                if let status = self.failure(.copyMatching, earlier) { return status }
                if let data = self.substitutedRead(earlier) {
                    result?.pointee = data as CFData
                    return errSecSuccess
                }
                return SecItemCopyMatching(query, result)
            },
            add: { attributes, result in
                let earlier = self.record(.add, attributes)
                return self.failure(.add, earlier) ?? SecItemAdd(attributes, result)
            },
            update: { query, changes in
                let earlier = self.record(.update, query)
                return self.failure(.update, earlier) ?? SecItemUpdate(query, changes)
            },
            delete: { query in
                let earlier = self.record(.delete, query)
                return self.failure(.delete, earlier) ?? SecItemDelete(query)
            }
        )
    }

    private func record(_ operation: Operation, _ query: CFDictionary) -> Int {
        let earlier = count(operation)
        let group = (query as NSDictionary)[kSecAttrAccessGroup as String] as? String
        calls.append(Call(operation: operation, accessGroup: group))
        return earlier
    }
}

/// The app group and the app's private group, both real, holding the same synthetic item.
///
/// Every case uses its own service and account, writes only fake values, and removes what it
/// wrote with a delete scoped to each group. Nothing here touches the real sign-in's name. A group
/// the test host cannot use fails the case; it is never skipped.
final class SharedCredentialStoreSecurityTests: XCTestCase {

    private struct SeedFailed: Error {
        let status: OSStatus
    }

    private enum Readback: CaseIterable {
        case error, nothing, different
    }

    private var service = ""
    private var account = ""
    private var defaultProbeAccount = ""
    private var privateGroup = ""
    private let sharedGroup = AppGroup.identifier

    private let full = DeviceCredential(
        origin: "https://fleet.example.invalid",
        accessClientId: "client-id-1",
        accessClientSecret: "client-secret-1",
        deviceId: "device-1",
        deviceSecret: "secret-1",
        clientInstanceId: "instance-1",
        pushDeviceId: "push-0001"
    )

    private var rotated: DeviceCredential { full.rotatingSecret(to: "secret-2") }

    private let different = DeviceCredential(
        origin: "https://other.example.invalid",
        deviceId: "device-2",
        deviceSecret: "secret-9",
        clientInstanceId: "instance-9"
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        let suffix = UUID().uuidString
        service = "com.anvarlab.phleet.tests.shared." + suffix
        account = "fixture-" + suffix
        defaultProbeAccount = "default-group-" + suffix
        privateGroup = try XCTUnwrap(
            KeychainCredentialStore.validAccessGroup(KeychainCredentialStore.privateAccessGroup()),
            "the app's Info.plist must carry \(KeychainCredentialStore.privateAccessGroupInfoKey), "
                + "expanded by the build"
        )
    }

    override func tearDown() {
        removeFixtures()
        super.tearDown()
    }

    // MARK: - AC1, AC2: the groups themselves

    /// An item written with no group lands in the app's private group, and that is the very string
    /// the build wrote into `Info.plist`. Both groups the sign-in relies on are usable from here.
    func testTheDefaultGroupIsTheBuildExpandedPrivateGroupAndBothGroupsAreReachable() throws {
        var attributes = KeychainCredentialStore.writeAttributes(
            service: service,
            account: defaultProbeAccount,
            payload: Data("{}".utf8)
        )
        attributes[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemAdd(attributes as CFDictionary, &result)
        XCTAssertEqual(
            status,
            errSecSuccess,
            "-34018 is errSecMissingEntitlement: the test host has no keychain access group"
        )
        let returned = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(
            returned[kSecAttrAccessGroup as String] as? String,
            privateGroup,
            "the group an unnamed write lands in is not the one Info.plist names"
        )

        for group in [privateGroup, sharedGroup] {
            let store = scoped(group)
            XCTAssertNoThrow(try store.save(full), "a scoped write to one of the two groups failed")
            XCTAssertEqual(try store.load(), full)
        }
    }

    /// The negative control: the same item in both groups, and a delete that names no group
    /// removes it from both. This is why no store instance ever makes one.
    func testAnUnscopedDeleteRemovesTheSameItemFromBothGroups() throws {
        try seed(full, in: privateGroup)
        try seed(full, in: sharedGroup)

        let status = SecItemDelete(
            KeychainCredentialStore.baseQuery(service: service, account: account) as CFDictionary
        )

        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(raw(in: privateGroup).status, errSecItemNotFound)
        XCTAssertEqual(raw(in: sharedGroup).status, errSecItemNotFound)
    }

    // MARK: - AC3, AC4: the real pair

    func testASaveThroughTheRealPairLeavesOneSharedCopyTheOwnCleanupCannotReach() throws {
        try seed(full, in: privateGroup)

        try SharedCredentialStore.keychain(service: service, account: account).save(rotated)

        XCTAssertEqual(try SharedCredentialStore.keychain(service: service, account: account).load(), rotated)
        XCTAssertEqual(try scoped(sharedGroup).load(), rotated, "what the extensions read")
        XCTAssertEqual(raw(in: privateGroup).status, errSecItemNotFound, "the older own copy is gone")

        // The own group's cleanup, run again on a fresh copy there, still leaves the shared one.
        try seed(full, in: privateGroup)
        try scoped(privateGroup).delete()
        XCTAssertEqual(try scoped(sharedGroup).load(), rotated)
        XCTAssertEqual(raw(in: privateGroup).status, errSecItemNotFound)
    }

    func testASignInAnEarlierBuildStoredWithNoGroupIsMovedWhole() throws {
        try seed(full, in: nil)
        XCTAssertEqual(decoded(raw(in: privateGroup).data), full, "an unnamed write lands in the private group")

        XCTAssertEqual(try SharedCredentialStore.keychain(service: service, account: account).load(), full)

        XCTAssertEqual(decoded(raw(in: sharedGroup).data), full)
        XCTAssertEqual(raw(in: privateGroup).status, errSecItemNotFound)

        let reloaded = try XCTUnwrap(
            try SharedCredentialStore.keychain(service: service, account: account).load()
        )
        XCTAssertEqual(reloaded, full)
        XCTAssertEqual(reloaded.serviceToken, full.serviceToken, "the proxy fields")
        XCTAssertEqual(reloaded.clientInstanceId, "instance-1", "the cursor bookkeeping")
        XCTAssertEqual(reloaded.pushDeviceId, "push-0001", "the notification identifier")
    }

    // MARK: - AC5: a copy that is not known good

    func testAFailedCopyLeavesTheOriginalUntouchedAndUsable() throws {
        try seed(full, in: privateGroup)
        let before = raw(in: privateGroup).data
        let sharedProbe = SecurityProbe()
        sharedProbe.failure = { operation, _ in
            operation == .add ? errSecInteractionNotAllowed : nil
        }
        let ownProbe = SecurityProbe()
        let store = pair(shared: sharedProbe, own: ownProbe)

        XCTAssertEqual(try store.load(), full)
        XCTAssertEqual(raw(in: sharedGroup).status, errSecItemNotFound)

        XCTAssertThrowsError(try store.save(rotated)) { error in
            XCTAssertEqual(
                error as? CredentialStoreError,
                .writeFailed(status: errSecInteractionNotAllowed)
            )
        }

        XCTAssertEqual(ownProbe.count(.delete), 0)
        XCTAssertEqual(raw(in: privateGroup).data, before)
        XCTAssertEqual(try scoped(privateGroup).load(), full)
    }

    func testAMoveThatDoesNotReadBackEqualReturnsAndKeepsTheOriginal() throws {
        for fault in Readback.allCases {
            try seed(full, in: privateGroup)
            let before = raw(in: privateGroup).data
            let ownProbe = SecurityProbe()
            // Read 0 is the first look in the shared group; read 1 is the readback.
            let store = pair(shared: readbackFault(fault, atRead: 1), own: ownProbe)

            XCTAssertEqual(try store.load(), full, "\(fault)")

            XCTAssertEqual(ownProbe.count(.delete), 0, "\(fault)")
            XCTAssertEqual(raw(in: privateGroup).data, before, "\(fault)")
            XCTAssertEqual(try scoped(privateGroup).load(), full, "\(fault)")
            removeFixtures()
        }
    }

    func testASaveThatDoesNotReadBackEqualReportsItAndKeepsTheOwnCopy() throws {
        let expected: [(Readback, CredentialStoreError)] = [
            (.error, .unavailable(status: errSecInteractionNotAllowed)),
            (.nothing, .malformedPayload),
            (.different, .malformedPayload)
        ]
        for (fault, expectedError) in expected {
            try seed(full, in: privateGroup)
            let before = raw(in: privateGroup).data
            let ownProbe = SecurityProbe()
            // A save reads nothing before it writes, so read 0 is the readback.
            let store = pair(shared: readbackFault(fault, atRead: 0), own: ownProbe)

            XCTAssertThrowsError(try store.save(rotated), "\(fault)") { error in
                XCTAssertEqual(error as? CredentialStoreError, expectedError, "\(fault)")
            }

            XCTAssertEqual(ownProbe.count(.delete), 0, "\(fault)")
            XCTAssertEqual(raw(in: privateGroup).data, before, "\(fault)")
            removeFixtures()
        }
    }

    // MARK: - AC6: a replacement that fails

    func testAFailedReplacementKeepsBothItemsAndItsStatusAndDeletesNothing() throws {
        let olderOwn = full.withPushDeviceId(nil)
        try seed(full, in: sharedGroup)
        try seed(olderOwn, in: privateGroup)
        let sharedBefore = raw(in: sharedGroup).data
        let privateBefore = raw(in: privateGroup).data
        let sharedProbe = SecurityProbe()
        sharedProbe.failure = { operation, _ in
            operation == .update ? errSecInteractionNotAllowed : nil
        }
        let ownProbe = SecurityProbe()

        XCTAssertThrowsError(try pair(shared: sharedProbe, own: ownProbe).save(rotated)) { error in
            XCTAssertEqual(
                error as? CredentialStoreError,
                .writeFailed(status: errSecInteractionNotAllowed)
            )
        }

        XCTAssertEqual(sharedProbe.count(.delete) + ownProbe.count(.delete), 0)
        XCTAssertEqual(sharedProbe.count(.add), 0)
        XCTAssertEqual(raw(in: sharedGroup).data, sharedBefore)
        XCTAssertEqual(raw(in: privateGroup).data, privateBefore)
        XCTAssertEqual(try scoped(sharedGroup).load(), full)
        XCTAssertEqual(try scoped(privateGroup).load(), olderOwn)
    }

    func testAFailedReplacementInThePrivateFallbackKeepsTheItemAndDeletesNothing() throws {
        try seed(full, in: privateGroup)
        let before = raw(in: privateGroup).data
        let sharedProbe = SecurityProbe()
        sharedProbe.failure = { _, _ in errSecMissingEntitlement }
        let ownProbe = SecurityProbe()
        ownProbe.failure = { operation, _ in
            operation == .update ? errSecInteractionNotAllowed : nil
        }

        XCTAssertThrowsError(try pair(shared: sharedProbe, own: ownProbe).save(rotated)) { error in
            XCTAssertEqual(
                error as? CredentialStoreError,
                .writeFailed(status: errSecInteractionNotAllowed)
            )
        }

        XCTAssertEqual(sharedProbe.count(.delete) + ownProbe.count(.delete), 0)
        XCTAssertEqual(ownProbe.count(.add), 0)
        XCTAssertEqual(raw(in: privateGroup).data, before)
        XCTAssertEqual(try scoped(privateGroup).load(), full)
    }

    // MARK: - AC7: cleanup, fallback, unreadable data and sign-out

    func testACleanupThatFailsAfterAVerifiedCopyLeavesTheSharedCopyInCharge() throws {
        try seed(full, in: privateGroup)
        let ownProbe = SecurityProbe()
        ownProbe.failure = { operation, _ in
            operation == .delete ? errSecInteractionNotAllowed : nil
        }

        XCTAssertEqual(try pair(shared: SecurityProbe(), own: ownProbe).load(), full)

        XCTAssertEqual(ownProbe.count(.delete), 1)
        XCTAssertEqual(decoded(raw(in: sharedGroup).data), full)
        XCTAssertEqual(decoded(raw(in: privateGroup).data), full, "kept when its deletion fails")
        XCTAssertEqual(try SharedCredentialStore.keychain(service: service, account: account).load(), full)

        // A save the same way: verified, its cleanup failure not reported, both kept.
        XCTAssertNoThrow(try pair(shared: SecurityProbe(), own: ownProbe).save(rotated))

        XCTAssertEqual(decoded(raw(in: sharedGroup).data), rotated)
        XCTAssertEqual(decoded(raw(in: privateGroup).data), full)
        XCTAssertEqual(try SharedCredentialStore.keychain(service: service, account: account).load(), rotated)
    }

    func testWithoutTheAppGroupTheSignInStaysInThePrivateGroupAlone() throws {
        let sharedProbe = SecurityProbe()
        sharedProbe.failure = { _, _ in errSecMissingEntitlement }
        let ownProbe = SecurityProbe()
        let store = pair(shared: sharedProbe, own: ownProbe)

        try store.save(full)
        XCTAssertEqual(try store.load(), full)

        XCTAssertEqual(decoded(raw(in: privateGroup).data), full)
        XCTAssertEqual(raw(in: sharedGroup).status, errSecItemNotFound)
        XCTAssertEqual(Set(ownProbe.calls.map(\.accessGroup)), [privateGroup])
        XCTAssertEqual(sharedProbe.count(.add), 0)
    }

    func testASharedGroupThatCannotBeReadIsNotTreatedAsEmpty() throws {
        try seed(full, in: privateGroup)
        let before = raw(in: privateGroup).data
        let sharedProbe = SecurityProbe()
        sharedProbe.failure = { operation, _ in
            operation == .copyMatching ? errSecInteractionNotAllowed : nil
        }
        let ownProbe = SecurityProbe()

        XCTAssertThrowsError(try pair(shared: sharedProbe, own: ownProbe).load()) { error in
            XCTAssertEqual(
                error as? CredentialStoreError,
                .unavailable(status: errSecInteractionNotAllowed)
            )
        }

        let writes = (sharedProbe.calls + ownProbe.calls).filter { $0.operation != .copyMatching }
        XCTAssertEqual(writes, [])
        XCTAssertEqual(raw(in: privateGroup).data, before)
        XCTAssertEqual(raw(in: sharedGroup).status, errSecItemNotFound)
    }

    func testSigningOutTriesBothScopedCopiesBeforeReportingAFailure() throws {
        try seed(full, in: sharedGroup)
        try seed(full, in: privateGroup)
        let sharedProbe = SecurityProbe()
        sharedProbe.failure = { operation, _ in
            operation == .delete ? errSecInteractionNotAllowed : nil
        }
        let ownProbe = SecurityProbe()

        XCTAssertThrowsError(try pair(shared: sharedProbe, own: ownProbe).delete()) { error in
            XCTAssertEqual(
                error as? CredentialStoreError,
                .writeFailed(status: errSecInteractionNotAllowed)
            )
        }

        XCTAssertEqual(sharedProbe.calls, [SecurityProbe.Call(operation: .delete, accessGroup: sharedGroup)])
        XCTAssertEqual(ownProbe.calls, [SecurityProbe.Call(operation: .delete, accessGroup: privateGroup)])
        XCTAssertEqual(raw(in: privateGroup).status, errSecItemNotFound)
        XCTAssertEqual(raw(in: sharedGroup).status, errSecSuccess, "the failed deletion left it")

        try SharedCredentialStore.keychain(service: service, account: account).delete()

        XCTAssertEqual(raw(in: sharedGroup).status, errSecItemNotFound)
        XCTAssertEqual(raw(in: privateGroup).status, errSecItemNotFound)
    }

    // MARK: - Helpers

    private func scoped(_ group: String, _ probe: SecurityProbe? = nil) -> KeychainCredentialStore {
        KeychainCredentialStore(
            service: service,
            account: account,
            accessGroup: group,
            security: probe?.security ?? KeychainCredentialStore.SecurityCalls()
        )
    }

    private func pair(shared: SecurityProbe, own: SecurityProbe) -> SharedCredentialStore {
        SharedCredentialStore(shared: scoped(sharedGroup, shared), own: scoped(privateGroup, own))
    }

    /// A shared-group probe whose readback fails, finds nothing, or finds another credential.
    private func readbackFault(_ fault: Readback, atRead read: Int) -> SecurityProbe {
        let probe = SecurityProbe()
        switch fault {
        case .error:
            probe.failure = { operation, earlier in
                operation == .copyMatching && earlier == read ? errSecInteractionNotAllowed : nil
            }
        case .nothing:
            probe.failure = { operation, earlier in
                operation == .copyMatching && earlier == read ? errSecItemNotFound : nil
            }
        case .different:
            let bytes = try? JSONEncoder().encode(different)
            probe.substitutedRead = { earlier in earlier == read ? bytes : nil }
        }
        return probe
    }

    /// Writes a credential the way a store does, or with no group the way earlier builds did.
    private func seed(_ credential: DeviceCredential, in group: String?) throws {
        let attributes = KeychainCredentialStore.writeAttributes(
            service: service,
            account: account,
            payload: try JSONEncoder().encode(credential),
            accessGroup: group
        )
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            XCTFail("seeding a fixture failed with \(status); -34018 means the host cannot use that group")
            throw SeedFailed(status: status)
        }
    }

    /// What one group holds, read straight from the keychain.
    private func raw(in group: String) -> (status: OSStatus, data: Data?) {
        var query = KeychainCredentialStore.baseQuery(
            service: service,
            account: account,
            accessGroup: group
        )
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    private func decoded(_ data: Data?) -> DeviceCredential? {
        data.flatMap { try? JSONDecoder().decode(DeviceCredential.self, from: $0) }
    }

    /// Scoped to each group in turn: cleanup never makes the unscoped delete the stores avoid.
    private func removeFixtures() {
        for group in [privateGroup, sharedGroup] where !group.isEmpty {
            for itemAccount in [account, defaultProbeAccount] {
                SecItemDelete(
                    KeychainCredentialStore.baseQuery(
                        service: service,
                        account: itemAccount,
                        accessGroup: group
                    ) as CFDictionary
                )
            }
        }
    }
}
