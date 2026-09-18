import Dispatch
import Foundation

/// A clock that never runs backward.
///
/// Token deadlines are measured on this and never on `Date`. The server stores absolute expiry
/// at issue time rather than recomputing it, for the same reason: a backward wall-clock jump
/// must not extend a token's apparent life. No security decision in this app is made on a wall
/// clock.
protocol MonotonicClock {
    var uptimeSeconds: Double { get }
}

struct SystemMonotonicClock: MonotonicClock {
    var uptimeSeconds: Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Holds the access token, mints it when it is needed, and owns the one sign-out condition.
///
/// The token is in memory only. Its deadline is absolute, computed from `expiresInSeconds` at
/// receipt on a monotonic clock, and refresh is proactive at deadline − 60 seconds.
///
/// Refresh is **single-flight**: concurrent callers await one in-flight mint rather than each
/// issuing their own. Without that, a screen that fires three requests at once on resume mints
/// three tokens.
@MainActor
final class AccessTokenHolder {

    enum Failure: Error, Equatable {
        /// The device credential itself is dead — revoked, or the record is gone.
        ///
        /// The **only** sign-out trigger, raised only by a `401` from the token mint. Every auth
        /// failure is indistinguishable by contract, so a `401` on any other route carries no
        /// information about whether the token merely expired; the only way to tell is to spend
        /// the device credential and see what happens, which is exactly what minting does.
        case deviceRevoked
        /// There is no credential to mint against.
        case notEnrolled
    }

    /// How far ahead of the deadline a refresh starts.
    nonisolated static let refreshLeadSeconds: Double = 60

    private let credentialStore: CredentialStore
    private let mint: (DeviceCredential) async throws -> MintTokenResponse
    private let clock: MonotonicClock

    private var token: String?
    private var deadline: Double?
    private var inFlight: Task<String, Error>?

    /// Runs when the device credential has been proven dead and deleted.
    var onDeviceRevoked: (@MainActor () -> Void)?

    /// Every mint this holder performed. Asserted directly by the single-flight test.
    private(set) var mintCount = 0

    init(
        credentialStore: CredentialStore,
        clock: MonotonicClock = SystemMonotonicClock(),
        mint: @escaping (DeviceCredential) async throws -> MintTokenResponse
    ) {
        self.credentialStore = credentialStore
        self.clock = clock
        self.mint = mint
    }

    /// Drops the in-memory token without touching the credential.
    ///
    /// Used when a route answers `401`: the token is suspect, the credential is not.
    func invalidateToken() {
        token = nil
        deadline = nil
    }

    /// A usable access token, minting one if the current token is absent or near its deadline.
    func accessToken() async throws -> String {
        if let token, let deadline, clock.uptimeSeconds < deadline - Self.refreshLeadSeconds {
            return token
        }
        return try await refresh()
    }

    /// Runs an authenticated operation, replaying it once against a fresh token on `401`.
    ///
    /// Exactly one mint and exactly one replay. The credential is untouched throughout: a second
    /// `401` against a token this holder just successfully minted proves the credential is alive
    /// and the failure is something else, so it is surfaced rather than turned into a
    /// re-enrollment.
    func authorized<T>(_ operation: (String) async throws -> T) async throws -> T {
        let first = try await accessToken()
        do {
            return try await operation(first)
        } catch FleetAPIError.unauthorized {
            invalidateToken()
            let retried = try await accessToken()
            return try await operation(retried)
        }
    }

    private func refresh() async throws -> String {
        if let inFlight {
            return try await inFlight.value
        }

        // Created in a `@MainActor` context, so the body runs there too and can touch this
        // object's state directly.
        let task = Task { () throws -> String in
            guard let credential = try self.credentialStore.load() else {
                throw Failure.notEnrolled
            }

            let response: MintTokenResponse
            do {
                response = try await self.mint(credential)
            } catch FleetAPIError.unauthorized {
                // The one condition. Spending the device credential is the only thing that can
                // distinguish "expired token" from "revoked device", and this is that answer.
                try? self.credentialStore.delete()
                throw Failure.deviceRevoked
            }

            // Absolute, and measured at receipt rather than at request time: the deadline the
            // server issued starts when this client learned about it.
            self.token = response.accessToken
            self.deadline = self.clock.uptimeSeconds + Double(response.expiresInSeconds)
            self.mintCount += 1
            return response.accessToken
        }

        inFlight = task
        defer { inFlight = nil }

        do {
            return try await task.value
        } catch Failure.deviceRevoked {
            token = nil
            deadline = nil
            onDeviceRevoked?()
            throw Failure.deviceRevoked
        }
    }
}
