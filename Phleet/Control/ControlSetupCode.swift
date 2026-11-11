import Foundation

/// What a setup code says: the three things the setup form asks for.
///
/// The orchestrator's dashboard shows one as a QR code so they need not be typed on a phone. The
/// format is one JSON object, defined by the platform's `docs/phone-setup-code.md`:
///
///     {"phleet":"control-setup","v":1,"origin":"<address>","accessClientId":"…",
///      "accessClientSecret":"…","operatorToken":"…"}
///
/// Reading a code **fills the form and does nothing else**. It never connects. A QR code is
/// whatever someone printed, so the address in it is shown for a person to check before anything
/// is sent to it — and the validation that refuses an insecure address is the form's, applied to
/// a scanned value exactly as to a typed one.
struct ControlSetupCode: Equatable, Sendable {

    static let kind = "control-setup"
    static let supportedVersion = 1

    /// A setup code is a few hundred characters. Anything far beyond that is not one, and is
    /// refused before it is parsed.
    static let maximumLength = 4_096

    let origin: String
    let accessClientId: String?
    let accessClientSecret: String?
    let operatorToken: String?

    enum Failure: Error, Equatable, Sendable {
        /// Not a setup code at all: some other QR code, or not JSON.
        case notASetupCode
        /// A setup code in a format this build does not know. Carries the version it claimed.
        case unsupportedVersion(Int?)
        /// A setup code with no address in it.
        case missingAddress
        /// One half of a service token without the other.
        case incompleteServiceToken
    }

    static func parse(_ text: String) -> Result<ControlSetupCode, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.count <= maximumLength,
            let data = trimmed.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            object["phleet"] as? String == kind
        else { return .failure(.notASetupCode) }

        // The version is checked before anything else is read: a newer format may have moved or
        // renamed every other field, and reading them by today's names would be guessing.
        let version = object["v"] as? Int
        guard version == supportedVersion else {
            return .failure(.unsupportedVersion(version))
        }

        guard let origin = string(object["origin"]) else {
            return .failure(.missingAddress)
        }

        let clientId = Self.string(object["accessClientId"])
        let clientSecret = Self.string(object["accessClientSecret"])
        guard (clientId == nil) == (clientSecret == nil) else {
            return .failure(.incompleteServiceToken)
        }

        return .success(
            ControlSetupCode(
                origin: origin,
                accessClientId: clientId,
                accessClientSecret: clientSecret,
                operatorToken: Self.string(object["operatorToken"])
            )
        )
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
