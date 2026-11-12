import XCTest
@testable import Phleet

/// An agent's reply rendered as Markdown: what is rendered, what is left as written, and what is
/// never interpreted at all.
final class ReplyMarkdownTests: XCTestCase {

    private func text(_ rendered: AttributedString) -> String {
        String(rendered.characters)
    }

    /// The runs carrying `intent`, as text.
    private func runs(
        _ rendered: AttributedString,
        with intent: InlinePresentationIntent
    ) -> [String] {
        rendered.runs.compactMap { run in
            guard run.inlinePresentationIntent?.contains(intent) == true else { return nil }
            return String(rendered[run.range].characters)
        }
    }

    private func links(_ rendered: AttributedString) -> [URL] {
        rendered.runs.compactMap { $0.link }
    }

    // MARK: - Inline syntax

    func testEmphasisAndCodeAreRenderedAndTheirPunctuationGoes() {
        let rendered = ReplyMarkdown.render("**bold** and *em* and `code` and ~~gone~~")

        XCTAssertEqual(text(rendered), "bold and em and code and gone")
        XCTAssertEqual(runs(rendered, with: .stronglyEmphasized), ["bold"])
        XCTAssertEqual(runs(rendered, with: .emphasized), ["em"])
        XCTAssertEqual(runs(rendered, with: .code), ["code"])
        XCTAssertEqual(runs(rendered, with: .strikethrough), ["gone"])
    }

    func testEveryLineBreakIsKept() {
        let reply = "line one\nline two\n\nafter a blank line"
        XCTAssertEqual(text(ReplyMarkdown.render(reply)), reply)
    }

    func testBlockSyntaxIsLeftAsWritten() {
        // A `Text` does not lay out lists and headings; left as typed, they still read.
        let reply = "- item one\n- item two\n# A heading"
        XCTAssertEqual(text(ReplyMarkdown.render(reply)), reply)
    }

    func testPlainTextIsUnchanged() {
        let reply = "Nothing special here: 3 * 4 = 12, and a_b_c stays."
        XCTAssertEqual(text(ReplyMarkdown.render(reply)), reply)
    }

    // MARK: - Fenced code

    func testAFencedBlockIsShownAsWrittenWithItsLineBreaks() {
        let rendered = ReplyMarkdown.render(
            "Before\n```swift\nlet x = 1\nlet *y* = 2\n```\nAfter"
        )

        // The fences and the language go; the code keeps its lines and its asterisks.
        XCTAssertEqual(text(rendered), "Before\nlet x = 1\nlet *y* = 2\nAfter")
        XCTAssertEqual(runs(rendered, with: .code), ["let x = 1\nlet *y* = 2"])
    }

    func testTildeFencesAndUnclosedFencesAreBlocksToo() {
        XCTAssertEqual(runs(ReplyMarkdown.render("~~~\nraw *text*\n~~~"), with: .code), ["raw *text*"])
        // As CommonMark has it, an unclosed fence runs to the end of the text.
        XCTAssertEqual(
            runs(ReplyMarkdown.render("```\nunclosed\nstill code"), with: .code),
            ["unclosed\nstill code"]
        )
    }

    func testTripleBackticksWithinALineAreACodeSpanNotAFence() {
        XCTAssertEqual(
            ReplyMarkdown.segments(of: "inline ```x``` span"),
            [.prose("inline ```x``` span")]
        )
        XCTAssertEqual(runs(ReplyMarkdown.render("inline ```x``` span"), with: .code), ["x"])
    }

    func testWindowsLineEndingsAreLineEndings() {
        XCTAssertEqual(
            ReplyMarkdown.segments(of: "a\r\n```\r\ncode\r\n```\r\nb"),
            [.prose("a"), .code("code"), .prose("b")]
        )
    }

    // MARK: - Links

    func testAWebLinkIsKept() {
        let rendered = ReplyMarkdown.render("[the page](https://example.invalid/page)")

        XCTAssertEqual(text(rendered), "the page")
        XCTAssertEqual(links(rendered), [URL(string: "https://example.invalid/page")!])
    }

    func testAnyOtherLinkStaysTextAndOpensNothing() {
        let rendered = ReplyMarkdown.render(
            "[a](javascript:alert(1)) [b](/relative/path) [c](customscheme://open) [d](file:///etc)"
        )

        XCTAssertEqual(text(rendered), "a b c d", "the words stay visible")
        XCTAssertTrue(links(rendered).isEmpty)
    }

    func testOnlyWebSchemesAreOpenable() throws {
        XCTAssertTrue(ReplyMarkdown.isOpenable(try XCTUnwrap(URL(string: "https://example.invalid"))))
        XCTAssertTrue(ReplyMarkdown.isOpenable(try XCTUnwrap(URL(string: "HTTP://example.invalid"))))
        XCTAssertFalse(ReplyMarkdown.isOpenable(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
        XCTAssertFalse(ReplyMarkdown.isOpenable(try XCTUnwrap(URL(string: "/relative"))))
    }

    // MARK: - Never HTML

    func testHTMLIsShownAsTheCharactersItIsAndInterpretsNothing() {
        let reply = "<b>bold</b> <script>alert(1)</script> <a href=\"x\">link</a>"
        let rendered = ReplyMarkdown.render(reply)

        XCTAssertEqual(text(rendered), reply)
        XCTAssertTrue(runs(rendered, with: .stronglyEmphasized).isEmpty)
        XCTAssertTrue(runs(rendered, with: .inlineHTML).isEmpty, "no run is marked as HTML")
        XCTAssertTrue(links(rendered).isEmpty)
    }
}
