import Foundation

/// An agent's reply, rendered as Markdown.
///
/// Agents answer in Markdown, and raw asterisks and backticks read as noise. This renders what a
/// single `Text` can show faithfully, and leaves everything else as the characters the agent wrote:
///
/// - **Inline syntax** — emphasis, strong emphasis, strikethrough, code spans and links — through
///   the system parser, `AttributedString(markdown:)`, interpreting inline syntax only and
///   preserving whitespace. Full block parsing turns paragraphs, lists and headings into
///   presentation intents a `Text` does not lay out, so paragraphs run together and list markers
///   vanish; inline-only keeps every line break and leaves a `- item` or a `# heading` readable
///   as typed.
/// - **Fenced code blocks** are split out first and shown verbatim in a monospaced run. Parsed
///   inline, a fence becomes one code span, and a code span turns its line breaks into spaces.
///
/// Never HTML. Nothing here interprets markup as HTML or hands text to anything that would; a
/// tag in a reply is shown as the characters it is, with the parser's HTML mark taken off.
///
/// A link is kept only when it opens a web page (`http` or `https`). Anything else — a custom
/// scheme, a script URL, a path with no scheme — stays visible as text and opens nothing.
enum ReplyMarkdown {

    /// A run of the reply: prose to parse, or a fenced block to show as written.
    enum Segment: Equatable, Sendable {
        case prose(String)
        case code(String)
    }

    /// The reply, rendered.
    static func render(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, segment) in segments(of: text).enumerated() {
            if index > 0 {
                // Segments were lines; the break between them is kept.
                result.append(AttributedString("\n"))
            }
            switch segment {
            case .prose(let prose):
                result.append(inline(prose))
            case .code(let code):
                var block = AttributedString(code)
                block.inlinePresentationIntent = .code
                result.append(block)
            }
        }
        return result
    }

    /// Splits fenced code blocks out of the text.
    ///
    /// A fence is a line that starts, after any indentation, with three or more backticks or
    /// tildes. A backtick fence's info string may not contain a backtick — "```x```" on one line
    /// is a code span, not a fence. The block ends at a line holding only a fence of the same
    /// character and at least the same length, or at the end of the text: an unclosed fence runs
    /// to the end, as CommonMark has it. The fence lines themselves, and the language named after
    /// an opening one, are not shown.
    static func segments(of text: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [Substring] = []
        var code: [Substring] = []
        var openFence: (character: Character, count: Int)?

        // `\r\n` is one `Character` in Swift, so it would never match a split on `\n`.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }

            if let fence = openFence {
                if isClosingFence(trimmed, character: fence.character, count: fence.count) {
                    segments.append(.code(code.joined(separator: "\n")))
                    code = []
                    openFence = nil
                } else {
                    code.append(line)
                }
                continue
            }

            if let fence = openingFence(trimmed) {
                if !prose.isEmpty {
                    segments.append(.prose(prose.joined(separator: "\n")))
                    prose = []
                }
                openFence = fence
            } else {
                prose.append(line)
            }
        }

        if openFence != nil {
            segments.append(.code(code.joined(separator: "\n")))
        } else if !prose.isEmpty {
            segments.append(.prose(prose.joined(separator: "\n")))
        }
        return segments
    }

    /// Whether a link may be opened from a reply.
    static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // MARK: - Private

    private static var options: AttributedString.MarkdownParsingOptions {
        AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
    }

    private static func inline(_ prose: String) -> AttributedString {
        guard let parsed = try? AttributedString(markdown: prose, options: options) else {
            return AttributedString(prose)
        }

        // Rebuilt run by run rather than edited in place, so no index is used after a mutation.
        var cleaned = AttributedString()
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if let link = run.link, !isOpenable(link) {
                piece.link = nil
            }
            if let intent = run.inlinePresentationIntent, intent.contains(.inlineHTML) {
                // The parser marks a tag as HTML and keeps its characters. The mark is dropped,
                // so the tag is plain text to everything that draws it.
                let rest = intent.subtracting(.inlineHTML)
                piece.inlinePresentationIntent = rest.isEmpty ? nil : rest
            }
            cleaned.append(piece)
        }
        return cleaned
    }

    private static func openingFence(_ line: Substring) -> (character: Character, count: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        if first == "`" && line.dropFirst(count).contains("`") {
            return nil
        }
        return (first, count)
    }

    private static func isClosingFence(
        _ line: Substring,
        character: Character,
        count: Int
    ) -> Bool {
        let run = line.prefix { $0 == character }.count
        guard run >= count else { return false }
        return line.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }
}
