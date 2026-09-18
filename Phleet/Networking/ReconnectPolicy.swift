import Foundation

/// When to try the stream again, and when not to try at all.
///
/// The client never stops retrying; it retries at the cap. The two rules that are easy to get
/// wrong are both encoded here rather than in the connection controller, so they are testable
/// without a socket:
///
/// - **Reset needs a connection that stayed up.** Resetting on any successful `hello` turns a
///   connection that dies immediately after it into a hot loop at the initial interval.
/// - **`4409` disarms, it does not delay.** The reconnect loop stops entirely and a person has
///   to resume it.
struct ReconnectPolicy: Equatable, Sendable {

    /// The first delay after a failure.
    static let initialSeconds: Double = 1
    /// The ceiling, and also the fallback rate-limit delay.
    static let maximumSeconds: Double = 30
    /// How long a connection must stay up before a close resets the backoff.
    static let resetAfterConnectedSeconds: Double = 60

    private(set) var consecutiveFailures = 0

    /// Set by a `4409`. A disarmed policy yields no delay at all, ever, until a person resumes.
    private(set) var isDisarmed = false

    init() {}

    /// The un-jittered interval the next delay is drawn from.
    var currentInterval: Double {
        let doublings = min(consecutiveFailures, 6)
        return min(Self.maximumSeconds, Self.initialSeconds * Double(1 << doublings))
    }

    /// The delay before the next attempt, or `nil` when the policy is disarmed.
    ///
    /// Full jitter: the delay is drawn uniformly from `[0, currentInterval]` rather than being
    /// the interval itself. `randomFraction` is injected so the distribution is assertable.
    mutating func nextDelay(randomFraction: Double) -> Double? {
        guard !isDisarmed else { return nil }

        let fraction = min(max(randomFraction, 0), 1)
        let delay = fraction * currentInterval
        consecutiveFailures += 1
        return delay
    }

    /// Records that a connection ended after being up for `connectedForSeconds`.
    ///
    /// A connection failing at 59 seconds does **not** reset the backoff.
    mutating func recordConnectionEnded(connectedForSeconds: Double) {
        if connectedForSeconds >= Self.resetAfterConnectedSeconds {
            consecutiveFailures = 0
        }
    }

    /// Stops this connection from ever reconnecting.
    ///
    /// Scoped to the connection object that received the `4409`, never to the thread. The
    /// supersede key is `conversationId + clientInstanceId` and this client holds one stable
    /// `clientInstanceId` per install, so its own reconnect supersedes its own stale socket and
    /// a `4409` on an already-replaced connection is routine.
    mutating func disarm() {
        isDisarmed = true
    }

    /// Re-arms after an explicit action by a person, as a fresh connection.
    mutating func resumeManually() {
        isDisarmed = false
        consecutiveFailures = 0
    }
}
