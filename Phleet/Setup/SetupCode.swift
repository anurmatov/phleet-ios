import Foundation

/// What a setup code says: the address the phone uses, the access-proxy service token when
/// there is one, and a one-time enrollment code.
///
/// The dashboard draws one as a QR code under Credentials → Devices → Connect a phone. The
/// format is one JSON object, defined by the platform's `src/fleet-dashboard/src/phoneSetup.ts`:
///
///     {"phleet":"setup","v":2,"origin":"<address>","accessClientId":"…",
///      "accessClientSecret":"…","enrollmentCode":"…"}
///
/// A QR code is whatever someone printed, so it is read as untrusted input. The kind and the
/// version are checked before anything else is read, the address goes through the same rule as
/// any other (`https` only, a host, no user name or password), and reading a code connects to
/// nothing: the address it named is shown for a person to check, and connecting is a separate
/// tap.
struct SetupCode: Equatable, Sendable {

    static let kind = "setup"
    static let supportedVersion = 2

    /// The kind an older dashboard drew. It carried the fleet-wide operator token rather than a
    /// one-time code, and this build will not use one: it is recognised only so it can be refused
    /// by name instead of as "not a setup code".
    static let olderKind = "control-setup"

    /// A setup code is a few hundred characters. Anything far beyond that is not one, and is
    /// refused before it is parsed.
    static let maximumLength = 4_096

    /// The validated `https` address.
    let origin: String
    let accessClientId: String?
    let accessClientSecret: String?
    /// Single use, and short-lived. Sent once, to `origin`, and never stored.
    let enrollmentCode: String

    enum Failure: Error, Equatable, Sendable {
        /// Not a setup code at all: some other QR code, or not JSON.
        case notASetupCode
        /// A setup code from a dashboard that predates one sign-in.
        case olderDashboard
        /// A setup code in a format this build does not know. Carries the version it claimed.
        case unsupportedVersion(Int?)
        /// No address, no enrollment code, or one half of a service token without the other.
        case incomplete
        /// An address that is not `https`. Refused, never upgraded.
        case insecureAddress
        /// An address with no host, or with a user name or password in it.
        case invalidAddress
    }

    /// The service token, present only when both halves are.
    var serviceToken: AccessServiceToken? {
        guard let accessClientId, let accessClientSecret else { return nil }
        return AccessServiceToken(clientId: accessClientId, clientSecret: accessClientSecret)
    }

    /// The host, for a person to recognise.
    var displayName: String {
        ServerDisplayName.derive(fromOrigin: origin)
    }

    static func parse(_ text: String) -> Result<SetupCode, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.count <= maximumLength,
            let data = trimmed.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let claimedKind = object["phleet"] as? String
        else { return .failure(.notASetupCode) }

        if claimedKind == olderKind {
            return .failure(.olderDashboard)
        }
        guard claimedKind == kind else { return .failure(.notASetupCode) }

        // The version is checked before anything else is read: a newer format may have moved or
        // renamed every other field, and reading them by today's names would be guessing.
        let version = object["v"] as? Int
        guard version == supportedVersion else {
            return .failure(.unsupportedVersion(version))
        }

        guard
            let address = string(object["origin"]),
            let enrollmentCode = string(object["enrollmentCode"])
        else { return .failure(.incomplete) }

        let clientId = string(object["accessClientId"])
        let clientSecret = string(object["accessClientSecret"])
        guard (clientId == nil) == (clientSecret == nil) else {
            return .failure(.incomplete)
        }

        let origin: String
        switch validatedOrigin(address) {
        case .success(let value):
            origin = value
        case .failure(let failure):
            return .failure(failure)
        }

        return .success(
            SetupCode(
                origin: origin,
                accessClientId: clientId,
                accessClientSecret: clientSecret,
                enrollmentCode: enrollmentCode
            )
        )
    }

    /// The address as it will be stored, or why it will not be.
    static func validatedOrigin(_ address: String) -> Result<String, Failure> {
        do {
            // The profile's own rule, so a scanned address passes exactly the checks any other
            // address does. Its display name is not used here.
            let profile = try FleetServerProfile(displayName: address, urlString: address)
            return .success(profile.baseURL.absoluteString)
        } catch FleetServerProfileError.insecureScheme {
            return .failure(.insecureAddress)
        } catch {
            return .failure(.invalidAddress)
        }
    }

    /// A non-empty string, or `nil` — including when the value is not a string at all.
    private static func string(_ value: Any?) -> String? {
        guard
            let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !string.isEmpty
        else { return nil }
        return string
    }
}
