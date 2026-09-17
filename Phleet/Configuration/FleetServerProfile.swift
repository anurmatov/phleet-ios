import Foundation

/// A Fleet server the app may connect to.
///
/// The address always comes from outside the binary — the user supplies it at enrollment
/// time. Nothing in this repository constructs a profile from a literal host, and there is
/// no `Info.plist` key, `.xcconfig` key, or source literal holding one.
struct FleetServerProfile: Equatable, Sendable {

    /// A human-readable name for the server, shown in the interface.
    let displayName: String

    /// The validated base address. Always `https`, always with a host, never with user-info.
    let baseURL: URL

    /// Validates and stores a server address.
    ///
    /// Rejection throws a typed error rather than trapping: the input is user-supplied, so a
    /// bad value is an ordinary outcome to report, not a programmer error to crash on.
    init(displayName: String, urlString: String) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw FleetServerProfileError.emptyDisplayName
        }

        guard let components = URLComponents(string: urlString) else {
            throw FleetServerProfileError.malformedURL
        }
        guard let scheme = components.scheme, scheme.lowercased() == "https" else {
            throw FleetServerProfileError.insecureScheme
        }
        guard let host = components.host, !host.isEmpty else {
            throw FleetServerProfileError.missingHost
        }
        guard components.user == nil, components.password == nil else {
            throw FleetServerProfileError.userInfoPresent
        }
        guard let url = components.url else {
            throw FleetServerProfileError.malformedURL
        }

        self.displayName = name
        self.baseURL = url
    }
}

/// Why a candidate server address was refused.
enum FleetServerProfileError: Error, Equatable {
    /// The display name was empty or only whitespace.
    case emptyDisplayName
    /// The string could not be parsed as a URL at all.
    case malformedURL
    /// The scheme was absent or was something other than `https`.
    case insecureScheme
    /// The URL carried no host.
    case missingHost
    /// The URL embedded a username or password.
    case userInfoPresent
}
