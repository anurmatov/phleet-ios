import Foundation

/// What a copy action puts on the pasteboard — and when there is no copy action at all.
///
/// Selection is the primary path and the platform provides it. This exists for the VoiceOver
/// path, where the entry reads as one element and there is no character-level selection to make,
/// so the action has to name a whole block.
///
/// The rule worth having in one place is the negative one: a block with nothing in it must not
/// offer Copy. `completion: "idle"` legitimately carries empty reply text, and an action that
/// silently writes an empty string is the same failure as a control that silently does nothing.
enum TranscriptCopy {

    /// The text to copy, or `nil` when the block has nothing worth copying.
    ///
    /// Whitespace decides whether an action is *offered*; it is not trimmed out of what gets
    /// copied. A person's own message is put on the pasteboard exactly as they typed it.
    static func copyable(_ text: String?) -> String? {
        guard let text else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
