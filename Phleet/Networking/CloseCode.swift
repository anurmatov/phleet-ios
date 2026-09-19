import Foundation

/// The close codes the stream publishes. Append-only once published.
enum StreamCloseCode: Int, Sendable, CaseIterable {
    case unauthenticated = 4401
    case notBoundPrincipal = 4403
    case livenessTimeout = 4408
    case superseded = 4409
    case outboundBufferOverflow = 4413
    case rateLimited = 4429
    case serverFault = 4500
    case draining = 4503
}

/// What the client does about a close.
///
/// Every code gets a distinct action. A client that reconnects on every close produces two
/// instances superseding each other forever, each looking perfectly healthy in isolation.
enum CloseAction: Equatable, Sendable {
    /// Mint a token, reconnect, catch up. Not a sign-out: only the token mint itself answering
    /// `401` proves the device credential is dead.
    case reauthenticateAndReconnect
    /// Stop. No retry, no backoff loop, terminal UI.
    case terminal
    case reconnectWithBackoff
    /// Disarm this connection's reconnect loop entirely.
    case disarm
    /// Reconnect, and catch up from the cursor — mandatorily, because frames were dropped.
    case reconnectAndCatchUp
    /// Re-derive the attach floor from a fresh open before reattaching.
    case reattachFromFreshOpen
    /// Wait exactly this long, then reconnect.
    case reconnectAfter(seconds: Int)
}

enum CloseCode {

    /// Maps a close to its action.
    ///
    /// `framesAppliedSinceHello` is what separates the two `4413` cases, and the separation is
    /// load-bearing. A mid-session overflow means this client fell behind: reconnect and catch
    /// up. An overflow on the **first** frame after `hello` means the attach floor was wrong —
    /// the server replayed history into its own 256-slot buffer before the drain loop started —
    /// and the documented response, "reconnect and catch up from the cursor", reattaches at the
    /// same floor and loops forever. That case re-derives the floor from a fresh open instead.
    static func action(
        for code: Int,
        reason: String?,
        framesAppliedSinceHello: Int
    ) -> CloseAction {
        switch StreamCloseCode(rawValue: code) {
        case .unauthenticated:
            return .reauthenticateAndReconnect
        case .notBoundPrincipal:
            return .terminal
        case .livenessTimeout, .serverFault, .draining:
            return .reconnectWithBackoff
        case .superseded:
            return .disarm
        case .outboundBufferOverflow:
            return framesAppliedSinceHello == 0 ? .reattachFromFreshOpen : .reconnectAndCatchUp
        case .rateLimited:
            // One carrier, one format: the whole close reason is a decimal integer of seconds.
            return .reconnectAfter(seconds: RetryAfterParser.seconds(from: reason))
        case .none:
            // An unpublished code. Backing off is the only safe default: it neither gives up on
            // a conversation nor hammers a server that just said something this build cannot
            // interpret.
            return .reconnectWithBackoff
        }
    }
}
