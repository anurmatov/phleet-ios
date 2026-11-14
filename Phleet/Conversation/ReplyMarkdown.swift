import Foundation

/// An agent's reply, rendered as Markdown.
///
/// Agents answer in Markdown, and raw asterisks, pound signs and pipes read as noise. This renders
/// what a column of `Text` can show faithfully, and leaves everything else as the characters the
/// agent wrote:
///
/// - **Inline syntax** — emphasis, strong emphasis, strikethrough, code spans and links — through
///   the system parser, `AttributedString(markdown:)`, interpreting inline syntax only and
///   preserving whitespace. Its full block parsing turns paragraphs, lists and headings into
///   presentation intents a `Text` does not lay out, so paragraphs run together and list markers
///   vanish. Block syntax is therefore read here, a line at a time, and written back as text.
/// - **Headings** become strong text. **List items** keep their indentation and get a bullet, or
///   a box for a task; a numbered item keeps its number. **Quotes** get a bar, and a **rule**
///   becomes a line. Every line of the reply is still one line of the result.
/// - **Tables** are split out and laid out as a grid (`MarkdownBlocksView`).
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

    /// A table: a header row and the rows under it, each cell rendered inline.
    struct Table: Equatable, Sendable {
        let header: [AttributedString]
        let rows: [[AttributedString]]
    }

    /// One piece of the reply as it is laid out, top to bottom.
    enum Block: Equatable, Sendable {
        case text(AttributedString)
        case code(String)
        case table(Table)
    }

    /// The reply as one attributed string: what is spoken, what a copy takes, and what a single
    /// `Text` would show. A table is written a row to a line here, its cells set apart by bars.
    static func render(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, block) in blocks(of: text).enumerated() {
            if index > 0 {
                // Blocks were lines; the break between them is kept.
                result.append(AttributedString("\n"))
            }
            switch block {
            case .text(let rendered):
                result.append(rendered)
            case .code(let code):
                var run = AttributedString(code)
                run.inlinePresentationIntent = .code
                result.append(run)
            case .table(let table):
                result.append(flattened(table))
            }
        }
        return result
    }

    /// The reply, split into what is laid out separately: runs of text, code blocks and tables.
    static func blocks(of text: String) -> [Block] {
        var blocks: [Block] = []
        for segment in segments(of: text) {
            switch segment {
            case .code(let code):
                blocks.append(.code(code))
            case .prose(let prose):
                blocks.append(contentsOf: proseBlocks(prose))
            }
        }
        return blocks
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

    // MARK: - Block syntax

    /// What one line of prose is, read by its first characters.
    enum Line: Equatable {
        case heading(Substring)
        /// `task` is `nil` for a plain item, else whether its box is ticked.
        case bullet(indent: Substring, task: Bool?, content: Substring)
        case ordered(indent: Substring, marker: Substring, content: Substring)
        case quote(depth: Int, content: Substring)
        case rule
        case plain
    }

    static func classify(_ line: Substring) -> Line {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let body = line.dropFirst(indent.count)
        guard let first = body.first else { return .plain }

        if isRule(body) { return .rule }

        if first == "#" {
            let level = body.prefix { $0 == "#" }.count
            let rest = body.dropFirst(level)
            if level <= 6, rest.isEmpty || rest.first == " " {
                return .heading(trimmedHeading(rest))
            }
            return .plain
        }

        if first == ">" {
            var depth = 0
            var rest = body
            while rest.first == ">" {
                depth += 1
                rest = rest.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() }
            }
            return .quote(depth: depth, content: rest)
        }

        if first == "-" || first == "*" || first == "+" {
            let rest = body.dropFirst()
            guard rest.first == " " else { return .plain }
            let content = rest.dropFirst()
            guard !content.isEmpty else { return .plain }
            if let task = taskBox(content) {
                return .bullet(indent: indent, task: task.isDone, content: task.content)
            }
            return .bullet(indent: indent, task: nil, content: content)
        }

        if first.isASCII, first.isNumber {
            let digits = body.prefix { $0.isASCII && $0.isNumber }
            let rest = body.dropFirst(digits.count)
            if digits.count <= 9, let mark = rest.first, mark == "." || mark == ")",
               rest.dropFirst().first == " " {
                let content = rest.dropFirst(2)
                if !content.isEmpty {
                    return .ordered(
                        indent: indent,
                        marker: body.prefix(digits.count + 1),
                        content: content
                    )
                }
            }
        }
        return .plain
    }

    /// A header row and the separator row under it open a table when they have as many cells as
    /// each other. Anything less is two lines of prose that happen to hold a bar.
    static func tableHeader(_ line: Substring, separator: Substring) -> [String]? {
        guard line.contains("|") else { return nil }
        let header = cells(of: line)
        let marks = cells(of: separator)
        guard !header.isEmpty, header.count == marks.count else { return nil }
        let isSeparator = marks.allSatisfy { mark in
            var dashes = Substring(mark)
            if dashes.first == ":" { dashes = dashes.dropFirst() }
            if dashes.last == ":" { dashes = dashes.dropLast() }
            return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
        }
        return isSeparator ? header : nil
    }

    /// The cells of one table row: split on bars that are not escaped, outer bars dropped.
    static func cells(of line: Substring) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }

        var cells: [String] = []
        var current = ""
        var isEscaped = false
        for character in text {
            if isEscaped {
                // An escaped bar is a bar in the cell; any other escape is left for the inline
                // parser to read.
                if character != "|" { current.append("\\") }
                current.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if isEscaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func proseBlocks(_ prose: String) -> [Block] {
        let lines = prose.split(separator: "\n", omittingEmptySubsequences: false)
        var blocks: [Block] = []
        var rendered: [AttributedString] = []
        var paragraph: [Substring] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            // Parsed together, so emphasis that opens on one line and closes on the next holds.
            rendered.append(inline(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushText() {
            flushParagraph()
            guard !rendered.isEmpty else { return }
            var text = AttributedString()
            for (index, piece) in rendered.enumerated() {
                if index > 0 { text.append(AttributedString("\n")) }
                text.append(piece)
            }
            blocks.append(.text(text))
            rendered = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]

            if index + 1 < lines.count,
               let header = tableHeader(line, separator: lines[index + 1]) {
                flushText()
                var rows: [[AttributedString]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"),
                      !lines[index].allSatisfy({ $0 == " " || $0 == "\t" }) {
                    var row = cells(of: lines[index]).map { inline($0) }
                    // A short row is padded and a long one cut, so every row has the header's
                    // columns and the grid stays a grid.
                    while row.count < header.count { row.append(AttributedString()) }
                    rows.append(Array(row.prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(Table(header: header.map { strong(inline($0)) }, rows: rows)))
                continue
            }

            switch classify(line) {
            case .plain:
                paragraph.append(line)
            case .heading(let content):
                flushParagraph()
                rendered.append(strong(inline(String(content))))
            case .bullet(let indent, let task, let content):
                flushParagraph()
                let mark: String
                switch task {
                case true?: mark = "\u{2611} "
                case false?: mark = "\u{2610} "
                case nil: mark = "\u{2022} "
                }
                rendered.append(AttributedString(String(indent) + mark) + inline(String(content)))
            case .ordered(let indent, let marker, let content):
                flushParagraph()
                rendered.append(
                    AttributedString(String(indent) + String(marker) + " ") + inline(String(content))
                )
            case .quote(let depth, let content):
                flushParagraph()
                let bars = String(repeating: "\u{258E} ", count: max(depth, 1))
                rendered.append(AttributedString(bars) + inline(String(content)))
            case .rule:
                flushParagraph()
                rendered.append(AttributedString(String(repeating: "\u{2500}", count: 12)))
            }
            index += 1
        }
        flushText()
        return blocks
    }

    /// A table as lines of text, for what is spoken and copied.
    private static func flattened(_ table: Table) -> AttributedString {
        var result = AttributedString()
        for (index, row) in ([table.header] + table.rows).enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            for (column, cell) in row.enumerated() {
                if column > 0 { result.append(AttributedString(" \u{2502} ")) }
                result.append(cell)
            }
        }
        return result
    }

    /// The same text with every run made strong, keeping whatever else each run already was.
    private static func strong(_ text: AttributedString) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            var piece = AttributedString(text[run.range])
            var intent = run.inlinePresentationIntent ?? []
            intent.insert(.stronglyEmphasized)
            piece.inlinePresentationIntent = intent
            result.append(piece)
        }
        return result
    }

    /// Three or more of the same mark — hyphen, asterisk or underscore — and nothing else.
    private static func isRule(_ body: Substring) -> Bool {
        guard let mark = body.first, mark == "-" || mark == "*" || mark == "_" else { return false }
        var count = 0
        for character in body {
            if character == mark {
                count += 1
            } else if character != " " && character != "\t" {
                return false
            }
        }
        return count >= 3
    }

    /// A heading's text, without the space after its marks or a closing run of marks.
    private static func trimmedHeading(_ rest: Substring) -> Substring {
        var content = rest.drop { $0 == " " }
        while content.last == " " { content = content.dropLast() }
        let closing = content.reversed().prefix { $0 == "#" }.count
        if closing > 0, closing < content.count {
            let withoutMarks = content.dropLast(closing)
            if withoutMarks.last == " " {
                content = withoutMarks
                while content.last == " " { content = content.dropLast() }
            }
        }
        return content
    }

    private static func taskBox(_ content: Substring) -> (isDone: Bool, content: Substring)? {
        guard content.count >= 4, content.first == "[" else { return nil }
        let mark = content.dropFirst().first
        let close = content.dropFirst(2)
        guard close.first == "]", close.dropFirst().first == " " else { return nil }
        switch mark {
        case " "?: return (false, close.dropFirst(2))
        case "x"?, "X"?: return (true, close.dropFirst(2))
        default: return nil
        }
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
