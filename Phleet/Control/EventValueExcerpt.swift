import Foundation

/// The beginning of a complete value in the form a person reads most easily, for the event's
/// own screen. The reader has all of it.
///
/// A JSON string shows the text it stands for; an object or a list shows its indented text;
/// everything else, and JSON that does not parse, shows what is stored. Bounded, so a value of a
/// megabyte never becomes one row's text.
struct EventValueExcerpt: Equatable, Sendable {

    static let maximumCharacters = 600

    let text: String
    /// Stored or indented JSON, which lines up in a fixed-width face. A string's text and plain
    /// text read as prose.
    let isCode: Bool

    /// `reading` is `nil` for a value that is not JSON-encoded, and until its JSON has been read.
    init(_ value: EventPayloadText, reading: JSONReading?) {
        guard value.isJSONEncoded, case .outline(let outline)? = reading else {
            self.init(text: Self.cut(value.text), isCode: value.isJSONEncoded)
            return
        }
        switch outline.root?.kind {
        case .string?:
            self.init(text: Self.cut(outline.root?.value ?? value.text), isCode: false)
        case .number?, .literal?:
            self.init(text: Self.cut(value.text), isCode: true)
        case .object?, .array?, nil:
            // No root: too many entries for an outline, and the indented text is still whole.
            self.init(text: Self.cut(outline.pretty), isCode: true)
        }
    }

    private init(text: String, isCode: Bool) {
        self.text = text
        self.isCode = isCode
    }

    /// The first characters, with an ellipsis when there are more. Never walks the whole text.
    static func cut(_ text: String) -> String {
        guard
            let end = text.index(text.startIndex, offsetBy: maximumCharacters, limitedBy: text.endIndex),
            end < text.endIndex
        else { return text }
        return String(text[..<end]) + "…"
    }
}
