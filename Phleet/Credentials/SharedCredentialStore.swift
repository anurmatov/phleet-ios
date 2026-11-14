import Foundation
import Security

/// The app group this app shares with its two extensions.
enum AppGroup {
    /// The group's identifier, as the entitlements of all three targets name it.
    static let identifier = "group.com.anvarlab.phleet"
}

/// The sign-in, kept where the widget and the share sheet can read it too.
///
/// Two places, in order. The **shared** one is the app group: the app writes there and the
/// extensions read there, each from its own process. The **own** one is the app's private
/// access group, where every build before this one kept the sign-in.
///
/// - A sign-in found only in the app's own group is copied to the shared one and then removed
///   from its own, so an install that was signed in before this build stays signed in and ends
///   with one copy, not two.
/// - A build whose signature does not carry the app group cannot use the shared place at all:
///   every call there answers "missing entitlement". The app then keeps its sign-in where it
///   always was. Signing in must never depend on an entitlement only the extensions need; they
///   simply find nothing and say the app has to be opened.
///
/// What does not change: one item, `AfterFirstUnlockThisDeviceOnly`, never synchronised and never
/// in a backup. Who can read it does: the two extensions, signed by the same team as the app.
final class SharedCredentialStore: CredentialStore {

    private let shared: CredentialStore
    private let own: CredentialStore

    init(shared: CredentialStore, own: CredentialStore) {
        self.shared = shared
        self.own = own
    }

    /// The real pair: the app group, then the app's own group.
    static func keychain() -> SharedCredentialStore {
        SharedCredentialStore(
            shared: KeychainCredentialStore(accessGroup: AppGroup.identifier),
            own: KeychainCredentialStore()
        )
    }

    func load() throws -> DeviceCredential? {
        do {
            if let credential = try shared.load() {
                return credential
            }
        } catch let error where Self.isMissingEntitlement(error) {
            return try own.load()
        }

        guard let credential = try own.load() else { return nil }
        // Moved rather than copied. If the move cannot be finished the sign-in is still good
        // where it was found, and the next launch tries again.
        if (try? shared.save(credential)) != nil {
            try? own.delete()
        }
        return credential
    }

    func save(_ credential: DeviceCredential) throws {
        do {
            try shared.save(credential)
        } catch let error where Self.isMissingEntitlement(error) {
            try own.save(credential)
            return
        }
        // Best effort: an older copy left in the app's own group is never read again once the
        // shared one exists, but a rotated secret should not leave its predecessor lying there.
        try? own.delete()
    }

    func delete() throws {
        var failure: Error?
        do {
            try shared.delete()
        } catch let error where Self.isMissingEntitlement(error) {
            // Nothing can be there.
        } catch {
            failure = error
        }
        do {
            try own.delete()
        } catch {
            failure = failure ?? error
        }
        // Both are attempted before either failure is reported: a sign-out that stopped at the
        // first error would leave the other copy to sign the phone back in at the next launch.
        if let failure { throw failure }
    }

    /// Whether a failure is the system saying this build may not use that access group.
    static func isMissingEntitlement(_ error: Error) -> Bool {
        switch error as? CredentialStoreError {
        case .unavailable(let status)?, .writeFailed(let status)?:
            return status == errSecMissingEntitlement
        case .malformedPayload?, nil:
            return false
        }
    }
}
