import Foundation

/// Everything this device needs to address one server, in one value.
///
/// The origin lives here rather than in `UserDefaults`, and that is a decision, not tidiness. A
/// `deviceSecret` is minted by one server and is meaningless to another. Stored separately, a
/// changed origin and a retained credential can desync, and the app presents a credential to a
/// server that never issued it. One value means they move together or not at all.
///
/// The access token is **not** here. It is derivable at any time from `deviceId` and
/// `deviceSecret`; persisting it would add a second secret at rest to buy one saved round trip
/// per fifteen minutes.
struct DeviceCredential: Equatable, Sendable, Codable {

    /// The validated `https` origin this credential belongs to.
    let origin: String

    let deviceId: String
    let deviceSecret: String

    /// Opaque cursor bookkeeping, not a credential — but pointless to store separately, since it
    /// is meaningless without the server it was used against.
    let clientInstanceId: String

    init(origin: String, deviceId: String, deviceSecret: String, clientInstanceId: String) {
        self.origin = origin
        self.deviceId = deviceId
        self.deviceSecret = deviceSecret
        self.clientInstanceId = clientInstanceId
    }

    init(origin: URL, deviceId: String, deviceSecret: String, clientInstanceId: String) {
        self.init(
            origin: origin.absoluteString,
            deviceId: deviceId,
            deviceSecret: deviceSecret,
            clientInstanceId: clientInstanceId
        )
    }

    /// The origin as a URL, or `nil` if the stored string will not parse.
    var originURL: URL? { URL(string: origin) }

    /// Replaces the secret while keeping everything else.
    ///
    /// Re-presenting the same enrollment code inside the server's re-presentation window returns
    /// the **same** `deviceId` with a **rotated** `deviceSecret`. An existing credential is
    /// therefore not a reason to refuse: it is overwritten.
    func rotatingSecret(to newSecret: String) -> DeviceCredential {
        DeviceCredential(
            origin: origin,
            deviceId: deviceId,
            deviceSecret: newSecret,
            clientInstanceId: clientInstanceId
        )
    }
}
