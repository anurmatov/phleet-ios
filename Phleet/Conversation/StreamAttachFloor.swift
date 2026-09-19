import Foundation

// The three cursor values live in this one file, and this is the only place any of them is
// written as arithmetic. They share a name on the wire — `afterSeq` — and they share a meaning,
// "I have processed up to and including this seq", and they are computed from different sources
// on purpose. Restating any of them locally is how one number becomes three slightly different
// numbers, which is a defect that reviews do not catch because each restatement looks right on
// its own.

/// Where a stream upgrade attaches.
///
/// The server's tail is a **replay-then-tail**, not a live-only subscription: it replays every
/// committed event from whatever floor it is given into a bounded 256-slot channel with a
/// non-blocking writer, and it starts that replay *before* it sends `hello` and before the drain
/// loop begins. So the buffer fills while nothing is reading it.
///
/// Attaching with a history cursor on a conversation holding more than 256 retained events
/// therefore closes `4413` deterministically, every time, before the client reads one useful
/// frame — and the documented `4413` response, "reconnect and catch up from the cursor",
/// reattaches at the same floor and loops forever.
///
/// The rule has no branch: **every** upgrade attaches at the live-tail floor, derived from the
/// open response's `nextSeq`. History is catch-up's job and only catch-up's job. The two ranges
/// abut exactly — catch-up covers `lastApplied + 1 … nextSeq − 1`, the stream covers `nextSeq …`
/// — and `eventId` dedupe absorbs anything committed between the open and the upgrade.
enum StreamAttachFloor {

    /// The live-tail floor for a conversation whose open response reported `nextSeq`.
    ///
    /// The `max(…, 1)` guard is mandatory, not padding: a fresh conversation may report
    /// `nextSeq: 0` or `1`, and an unguarded subtraction either underflows or comes back
    /// `400 invalid_cursor` — failing on exactly the brand-new thread that has to load first.
    static func liveTailFloor(nextSeq: Int) -> Int {
        max(nextSeq, 1) - 1
    }
}

/// Where a catch-up read starts.
///
/// Two values, two different reasons. Collapsing them is the specific mistake this file exists
/// to prevent: the recovery floor used at cold start underflows or is rejected on a fresh
/// conversation, and the cold-start cursor used for recovery asks for everything and hides that
/// local state was wrong.
enum CatchUpCursor {

    /// A session with no stored cursor. "I have processed nothing."
    ///
    /// Sent explicitly rather than by omitting the parameter — the server parses an absent
    /// `afterSeq` to the same value, but an explicit one makes the request self-describing in a
    /// log.
    static let coldStart = 0

    /// After `400 invalid_cursor`: the local cursor was ahead of the server, which means local
    /// corruption or a restored backup. Never clamped server-side, never silently continued
    /// from.
    static func recoveryFloor(retainedFloorSeq: Int) -> Int {
        max(retainedFloorSeq, 1) - 1
    }

    /// To read a submission's whole lifecycle from its `acceptedSeq`.
    ///
    /// `afterSeq` is inclusive of the seq it names, so the accepted event itself is only
    /// returned when the request starts one below it.
    static func beforeAcceptedSeq(_ acceptedSeq: Int) -> Int {
        max(acceptedSeq, 1) - 1
    }
}
