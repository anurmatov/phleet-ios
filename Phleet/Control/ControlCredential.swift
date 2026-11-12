import Foundation

/// Everything this device needs to reach one orchestrator, in one value.
///
/// This is a **different** credential from `DeviceCredential`, for a different surface. The
/// thread talks to the device boundary, where a device enrolls and holds its own revocable
/// secret. The control plane talks to the orchestrator's operator API, which has no enrollment:
/// it is guarded by whatever sits in front of it, and by one shared operator token on every
/// request that changes something.
///
/// The three parts move together for the same reason the device credential's do. A service token
/// is issued for one address and an operator token belongs to one orchestrator; stored apart, a
/// changed address and a retained token would desync, and the app would present a token to a
/// server that never issued it.
struct ControlCredential: Equatable, Sendable, Codable {

    /// The validated `https` origin of the orchestrator.
    let origin: String

    /// The access-proxy service token, when the orchestrator sits behind one.
    ///
    /// Both halves or neither. A deployment reached over a private network has no proxy and
    /// stores no service token at all.
    let accessClientId: String?
    let accessClientSecret: String?

    /// The orchestrator's operator token, or `nil` for a **read-only** connection.
    ///
    /// Reading needs no token on the orchestrator, so a device can be set up to watch without
    /// being able to change anything. Every control that would change something is then stated
    /// as unavailable rather than left to fail on the first tap.
    let operatorToken: String?

    /// This install's name for itself on the orchestrator's list of phones to notify, or `nil`
    /// when notifications are off.
    ///
    /// Its presence is the record that the person turned notifications on. It lives with the
    /// connection because it belongs to it: a device registered with one orchestrator means
    /// nothing to another, and removing the connection removes this with it.
    let pushDeviceId: String?

    init(
        origin: String,
        accessClientId: String?,
        accessClientSecret: String?,
        operatorToken: String?,
        pushDeviceId: String? = nil
    ) {
        self.origin = origin
        self.accessClientId = Self.nonEmpty(accessClientId)
        self.accessClientSecret = Self.nonEmpty(accessClientSecret)
        self.operatorToken = Self.nonEmpty(operatorToken)
        self.pushDeviceId = Self.nonEmpty(pushDeviceId)
    }

    /// The same connection with notifications turned on under this identifier, or off for `nil`.
    func withPushDeviceId(_ pushDeviceId: String?) -> ControlCredential {
        ControlCredential(
            origin: origin,
            accessClientId: accessClientId,
            accessClientSecret: accessClientSecret,
            operatorToken: operatorToken,
            pushDeviceId: pushDeviceId
        )
    }

    /// The origin as a URL, or `nil` if the stored string will not parse.
    var originURL: URL? { URL(string: origin) }

    /// The service token, present only when both halves are.
    var serviceToken: AccessServiceToken? {
        guard let accessClientId, let accessClientSecret else { return nil }
        return AccessServiceToken(clientId: accessClientId, clientSecret: accessClientSecret)
    }

    /// Whether this connection may change anything.
    var canDecide: Bool { operatorToken != nil }

    /// What a request needs, or `nil` when the stored origin will not parse.
    var connection: ControlConnection? {
        guard let originURL else { return nil }
        return ControlConnection(
            origin: originURL,
            serviceToken: serviceToken,
            operatorToken: operatorToken
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// The two halves of an access-proxy service token.
struct AccessServiceToken: Equatable, Sendable {
    let clientId: String
    let clientSecret: String
}

/// One orchestrator as a request sees it.
struct ControlConnection: Equatable, Sendable {
    let origin: URL
    let serviceToken: AccessServiceToken?
    let operatorToken: String?
}
