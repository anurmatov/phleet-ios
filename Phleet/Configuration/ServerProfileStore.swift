import Foundation

/// Where an enrolled server profile is read from.
///
/// This is a seam, not a feature. Persisting a profile means enrollment, and enrollment is a
/// later slice; keeping the protocol here now means that slice changes the store and leaves
/// `ServerProfileResolution` untouched.
protocol ServerProfileStore {
    /// The currently enrolled profile, or `nil` when the app is unenrolled.
    var currentProfile: FleetServerProfile? { get }
}

/// The store this slice ships: it holds nothing and always reports unenrolled.
///
/// There is deliberately no Keychain access, no file, and no user defaults behind this. A
/// fresh install has no server configured, and so does every install of this build.
struct InMemoryServerProfileStore: ServerProfileStore {
    var currentProfile: FleetServerProfile? { nil }
}
