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
        /// This holder's sign-in was replaced or signed out. It can never join a later sign-in.
        case sessionEnded
    }

    /// How far ahead of the deadline a refresh starts.
    nonisolated static let refreshLeadSeconds: Double = 60

    /// Whether a failed mint was the server refusing the device credential: a `401`, however the
    /// client that made the request names it. The orchestrator's sign-in routes answer through
    /// `ControlAPIError`; the chat client's through `FleetAPIError`.
    nonisolated static func isRefusal(_ error: Error) -> Bool {
        (error as? FleetAPIError) == .unauthorized || (error as? ControlAPIError) == .unauthorized
    }

    private let credentialStore: CredentialStore
    private let enrollment: Result<DeviceCredential?, Error>
    private var retired = false
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
        self.enrollment = Result { try credentialStore.load() }
        self.clock = clock
        self.mint = mint
    }

    /// Permanently retire this generation, even if its network operation ignores cancellation.
    func invalidateSession() {
        retired = true
        invalidateToken()
        inFlight?.cancel()
        onDeviceRevoked = nil
    }

    private func activeCredential() throws -> DeviceCredential {
        guard !retired else { throw Failure.sessionEnded }
        guard let credential = try enrollment.get() else { throw Failure.notEnrolled }
        return credential
    }

    /// A retained wrapper cannot use this holder's token on another connection.
    func validateSession(for connection: ControlConnection) throws {
        let credential = try activeCredential()
        guard credential.originURL == connection.origin,
              credential.serviceToken == connection.serviceToken else { throw Failure.sessionEnded }
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
        _ = try activeCredential()
        if let token, let deadline, clock.uptimeSeconds < deadline - Self.refreshLeadSeconds {
            return token
        }
        let refreshed = try await refresh()
        _ = try activeCredential()
        return refreshed
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
            let value = try await operation(first)
            _ = try activeCredential()
            return value
        } catch {
            _ = try activeCredential()
            guard Self.isRefusal(error) else { throw error }
            invalidateToken()
            let retried = try await accessToken()
            do {
                let value = try await operation(retried)
                _ = try activeCredential()
                return value
            } catch {
                _ = try activeCredential()
                throw error
            }
        }
    }

    private func refresh() async throws -> String {
        if let inFlight {
            return try await inFlight.value
        }

        // Created in a `@MainActor` context, so the body runs there too and can touch this
        // object's state directly.
        let task = Task { () throws -> String in
            // Captured at construction, never reloaded to mint after a late 401.
            let credential = try self.activeCredential()

            let response: MintTokenResponse
            do {
                response = try await self.mint(credential)
            } catch let error where Self.isRefusal(error) {
                // The one condition. Spending the device credential is the only thing that can
                // distinguish "expired token" from "revoked device", and this is that answer.
                _ = try self.activeCredential()
                // Setup may have persisted a replacement before it was adopted by the UI.
                // Compare synchronously before deletion, ignoring notification-only updates.
                guard let stored = try self.credentialStore.load(),
                      stored.isSameSignIn(as: credential) else {
                    self.invalidateSession()
                    throw Failure.sessionEnded
                }
                try? self.credentialStore.delete()
                let callback = self.onDeviceRevoked
                self.invalidateSession()
                callback?()
                throw Failure.deviceRevoked
            }

            // Absolute, and measured at receipt rather than at request time: the deadline the
            // server issued starts when this client learned about it.
            _ = try self.activeCredential()
            self.token = response.accessToken
            self.deadline = self.clock.uptimeSeconds + Double(response.expiresInSeconds)
            self.mintCount += 1
            return response.accessToken
        }

        inFlight = task
        defer { inFlight = nil }

        return try await task.value
    }
}
