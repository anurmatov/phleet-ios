import Foundation

/// Why the credential store could not do what was asked.
enum CredentialStoreError: Error, Equatable {
    /// A read failed for a reason other than "not there".
    ///
    /// Treated as unenrolled and surfaced as a distinct message — and the item is **not**
    /// deleted. A read that fails while the device is locked must not destroy a working
    /// credential.
    case unavailable(status: Int32)

    /// A write failed. Enrollment aborts here rather than proceeding to the token mint: the
    /// alternative is a device the server holds and this client cannot address.
    case writeFailed(status: Int32)

    /// The credential could not be turned into bytes, or back.
    case malformedPayload
}

/// Where the device credential lives.
protocol CredentialStore {
    /// The stored credential, or `nil` when there is none.
    ///
    /// "Not there" is an ordinary outcome and returns `nil`. Every other failure throws
    /// `CredentialStoreError.unavailable`, because the two must not be confused: one means a
    /// fresh install, the other means a working credential this app cannot currently read.
    func load() throws -> DeviceCredential?

    /// Writes the credential, replacing any existing one.
    func save(_ credential: DeviceCredential) throws

    /// Removes the credential. The only caller is the sign-out path.
    func delete() throws
}

/// A store that holds a credential for the lifetime of the process and nothing longer.
///
/// Used by the tests and by the launch-argument-driven double. It is not a fallback for the
/// Keychain: a real install that cannot reach the Keychain is unenrolled, not quietly enrolled
/// somewhere weaker.
final class InMemoryCredentialStore: CredentialStore {

    private var credential: DeviceCredential?

    /// How many times `delete()` ran. The sign-out rule is "exactly one path deletes", and this
    /// is what lets a test say so.
    private(set) var deleteCount = 0
    private(set) var saveCount = 0

    init(credential: DeviceCredential? = nil) {
        self.credential = credential
    }

    func load() throws -> DeviceCredential? { credential }

    func save(_ credential: DeviceCredential) throws {
        self.credential = credential
        saveCount += 1
    }

    func delete() throws {
        credential = nil
        deleteCount += 1
    }
}
