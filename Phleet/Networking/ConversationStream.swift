import Foundation

/// What one stream connection publishes.
///
/// `ping` never appears: the implementation answers it with `{"kind":"pong"}` and nothing above
/// this seam needs to know liveness exists. Nor does an unknown `kind` appear as a failure — it
/// is an ordinary forward-compatible event and arrives as `.event`.
enum ConversationStreamEvent: Equatable, Sendable {
    /// Always first, and always before any event.
    case hello(HelloFrame)
    case event(ConversationEvent)
    /// A frame arrived and could not be read. Logged, the frame dropped, a catch-up triggered —
    /// never a reason to tear the connection down.
    case undecodableFrame(String)
    /// The connection ended. Terminates the sequence.
    case closed(code: Int, reason: String?)
    /// The upgrade never completed. Terminates the sequence.
    case failed(String)
}

/// One connection, expressed as a sequence.
///
/// The seam the tests drive. A scripted double yields `hello`, some events and a close code with
/// no socket anywhere, which is what lets every close-code behaviour be asserted hermetically.
protocol ConversationStream {

    /// Opens one connection and yields its frames until it ends.
    ///
    /// `afterSeq` is the **live-tail floor** and nothing else — see `StreamAttachFloor`. The
    /// server replays every committed event from whatever floor it is given into a bounded,
    /// non-blocking 256-slot buffer, and it starts that replay *before* it sends `hello` and
    /// before the drain loop runs. Handing it a history cursor closes `4413` deterministically
    /// on any conversation with more than 256 retained events.
    func frames(
        origin: URL,
        accessToken: String,
        conversationId: String,
        clientInstanceId: String,
        afterSeq: Int
    ) -> AsyncStream<ConversationStreamEvent>
}
