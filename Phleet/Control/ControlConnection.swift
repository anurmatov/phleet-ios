import Foundation

/// The two halves of an access-proxy service token.
struct AccessServiceToken: Equatable, Sendable {
    let clientId: String
    let clientSecret: String
}

/// One Fleet server as a request to it sees it.
///
/// The origin is the dashboard's address, which carries the orchestrator's routes (`/api/…`,
/// `/ws…`) and the chat service's (`/v1/…`) alike. The service token is for an access proxy in
/// front of that address, when there is one.
///
/// `accessToken` is this phone's fifteen-minute sign-in, and it is never stored here for longer
/// than one request: the models hold a connection without one, and `SignedInControlAPI` puts a
/// current token on each request as it goes out. The routes that obtain a token are sent with
/// none.
struct ControlConnection: Equatable, Sendable {
    let origin: URL
    let serviceToken: AccessServiceToken?
    let accessToken: String?

    init(origin: URL, serviceToken: AccessServiceToken?, accessToken: String? = nil) {
        self.origin = origin
        self.serviceToken = serviceToken
        self.accessToken = accessToken
    }

    /// The same server, signed in with `accessToken`.
    func bearing(_ accessToken: String) -> ControlConnection {
        ControlConnection(origin: origin, serviceToken: serviceToken, accessToken: accessToken)
    }
}
