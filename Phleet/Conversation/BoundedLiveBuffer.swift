import Foundation

/// Holds live frames while catch-up runs.
///
/// The stream is attached before catch-up is issued, which closes a window rather than papering
/// over one: catch-up-then-attach leaves an interval between the read and the upgrade in which
/// appended events belong to neither, and the client cannot tell a quiet interval from a lossy
/// one. Buffering from `hello` onward means there is no interval at all.
///
/// The buffer is bounded at the server's own `outboundBufferEvents`. An unbounded one would just
/// relocate the server's overflow problem into the app.
///
/// **On overflow the whole buffer is discarded and a second catch-up round is scheduled**, not
/// individual frames dropped. The client knows its `lastApplied`, catch-up is a pure repeatable
/// read, and a silently dropped frame is the one failure it could never detect.
struct BoundedLiveBuffer: Equatable, Sendable {

    let capacity: Int

    private(set) var events: [ConversationEvent] = []

    /// Set by an overflow and cleared by `consumeOverflow()`. While set, exactly one extra
    /// catch-up round is owed.
    private(set) var needsAdditionalCatchUp = false

    /// How many times the buffer overflowed. Read by tests and by logging; never by rendering.
    private(set) var overflowCount = 0

    init(capacity: Int) {
        // A capacity below one would discard every frame and report nothing, which is the same
        // silent loss the type exists to prevent.
        self.capacity = max(capacity, 1)
    }

    var count: Int { events.count }

    mutating func append(_ event: ConversationEvent) {
        if events.count >= capacity {
            // Start again from empty rather than dropping the newest frame: what is kept does
            // not matter, because the owed catch-up re-reads all of it. What matters is that
            // the client knows it happened.
            events.removeAll(keepingCapacity: true)
            needsAdditionalCatchUp = true
            overflowCount += 1
        }
        events.append(event)
    }

    /// Records that a catch-up is owed for a reason other than overflow — an undecodable frame
    /// was dropped, or a `seq` jump was seen.
    mutating func markNeedsCatchUp() {
        needsAdditionalCatchUp = true
    }

    /// Takes everything buffered so far, leaving the overflow flag alone.
    mutating func drain() -> [ConversationEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    /// Reports whether a catch-up round is owed, and clears the debt.
    ///
    /// Clearing on read is what terminates the loop: the extra round is issued once, from
    /// `lastApplied`, and a round that does not itself overflow owes nothing further.
    mutating func consumeOverflow() -> Bool {
        defer { needsAdditionalCatchUp = false }
        return needsAdditionalCatchUp
    }
}
