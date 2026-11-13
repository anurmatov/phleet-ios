import Foundation

/// Everything this phone needs to reach one Fleet server, in one value: the one credential the
/// Fleet, Runs and Chat tabs all use.
///
/// The origin lives here rather than in `UserDefaults`, and that is a decision, not tidiness. A
/// `deviceSecret` is issued by one orchestrator and is meaningless to another, and a service token
/// is issued for one address. Stored separately, a changed origin and a retained secret can
/// desync, and the app presents a credential to a server that never issued it. One value means
/// they move together or not at all.
///
/// The access token is **not** here. It is derivable at any time from `deviceId` and
/// `deviceSecret`; persisting it would add a second secret at rest to buy one saved round trip
/// per fifteen minutes.
struct DeviceCredential: Equatable, Sendable, Codable {

    /// The validated `https` origin: the dashboard's address, which carries every route.
    let origin: String

    /// The access-proxy service token, when the address sits behind one. Both halves or neither.
    let accessClientId: String?
    let accessClientSecret: String?

    let deviceId: String
    let deviceSecret: String

    /// Opaque cursor bookkeeping, not a credential — but pointless to store separately, since it
    /// is meaningless without the server it was used against.
    let clientInstanceId: String

    /// This install's name on the orchestrator's list of phones to notify, or `nil` when
    /// notifications are off. Its presence is the record that the person turned them on.
    let pushDeviceId: String?

    init(
        origin: String,
        accessClientId: String? = nil,
        accessClientSecret: String? = nil,
        deviceId: String,
        deviceSecret: String,
        clientInstanceId: String,
        pushDeviceId: String? = nil
    ) {
        self.origin = origin
        self.accessClientId = Self.nonEmpty(accessClientId)
        self.accessClientSecret = Self.nonEmpty(accessClientSecret)
        self.deviceId = deviceId
        self.deviceSecret = deviceSecret
        self.clientInstanceId = clientInstanceId
        self.pushDeviceId = Self.nonEmpty(pushDeviceId)
    }

    /// The origin as a URL, or `nil` if the stored string will not parse.
    var originURL: URL? { URL(string: origin) }

    /// The service token, present only when both halves are.
    var serviceToken: AccessServiceToken? {
        guard let accessClientId, let accessClientSecret else { return nil }
        return AccessServiceToken(clientId: accessClientId, clientSecret: accessClientSecret)
    }

    /// The server as a request sees it, with no access token yet, or `nil` when the stored origin
    /// will not parse.
    var connection: ControlConnection? {
        guard let originURL else { return nil }
        return ControlConnection(origin: originURL, serviceToken: serviceToken)
    }

    /// Replaces the secret while keeping everything else.
    ///
    /// Re-presenting the same enrollment code inside the server's recovery window returns the
    /// **same** `deviceId` with a **rotated** `deviceSecret`. An existing credential is therefore
    /// not a reason to refuse: it is overwritten.
    func rotatingSecret(to newSecret: String) -> DeviceCredential {
        DeviceCredential(
            origin: origin,
            accessClientId: accessClientId,
            accessClientSecret: accessClientSecret,
            deviceId: deviceId,
            deviceSecret: newSecret,
            clientInstanceId: clientInstanceId,
            pushDeviceId: pushDeviceId
        )
    }

    /// The same credential with notifications turned on under this identifier, or off for `nil`.
    func withPushDeviceId(_ pushDeviceId: String?) -> DeviceCredential {
        DeviceCredential(
            origin: origin,
            accessClientId: accessClientId,
            accessClientSecret: accessClientSecret,
            deviceId: deviceId,
            deviceSecret: deviceSecret,
            clientInstanceId: clientInstanceId,
            pushDeviceId: pushDeviceId
        )
    }

    /// Notification preference is mutable metadata, not a new enrollment or credential.
    func isSameSignIn(as other: DeviceCredential) -> Bool {
        withPushDeviceId(nil) == other.withPushDeviceId(nil)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
