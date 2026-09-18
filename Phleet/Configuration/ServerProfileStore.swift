import Foundation

/// Where an enrolled server profile is read from.
protocol ServerProfileStore {
    /// The currently enrolled profile, or `nil` when the app is unenrolled.
    var currentProfile: FleetServerProfile? { get }
}

/// The store the app ships: the profile is whatever the stored device credential says.
///
/// This is the shape the seam was built for. `ServerProfileResolution` is untouched by this
/// slice — the store changed, the precedence rules did not.
///
/// There is no separate copy of the origin anywhere. A `deviceSecret` is minted by one server
/// and is meaningless to another, so the address and the credential move together or not at all.
struct CredentialBackedServerProfileStore: ServerProfileStore {

    private let credentialStore: CredentialStore

    init(credentialStore: CredentialStore) {
        self.credentialStore = credentialStore
    }

    var currentProfile: FleetServerProfile? {
        // A read failure resolves to "no profile" here, and `AppEnvironment` separately surfaces
        // it as its own message. Nothing on this path ever deletes the item: a read that failed
        // because the device is locked must not destroy a working credential.
        guard
            let credential = try? credentialStore.load(),
            let components = URLComponents(string: credential.origin)
        else {
            return nil
        }
        return try? FleetServerProfile(
            displayName: ServerDisplayName.derive(from: components),
            urlString: credential.origin
        )
    }
}

/// A store that holds nothing and always reports unenrolled.
///
/// Kept for the resolution tests, which need a store whose answer is fixed. It is not a fallback
/// for the credential-backed one.
struct InMemoryServerProfileStore: ServerProfileStore {
    var currentProfile: FleetServerProfile? { nil }
}
