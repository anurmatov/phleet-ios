import XCTest
@testable import Phleet

/// Block Markdown in an agent's reply: what becomes text, what becomes a table, and what is left
/// alone because it only looks like block syntax.
final class ReplyMarkdownBlockTests: XCTestCase {

    private func text(_ rendered: AttributedString) -> String {
        String(rendered.characters)
    }

    private func strong(_ rendered: AttributedString) -> [String] {
        rendered.runs.compactMap { run in
            guard run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true else {
                return nil
            }
            return String(rendered[run.range].characters)
        }
    }

    // MARK: - Lines

    func testAHeadingIsStrongTextWithoutItsMarks() {
        let rendered = ReplyMarkdown.render("## Findings ##\nbody")

        XCTAssertEqual(text(rendered), "Findings\nbody")
        XCTAssertEqual(strong(rendered), ["Findings"])
    }

    func testAPoundSignWithNoSpaceAfterItIsNotAHeading() {
        // An issue number at the start of a line is the common case.
        XCTAssertEqual(ReplyMarkdown.classify("#42 is fixed"), .plain)
        XCTAssertEqual(text(ReplyMarkdown.render("#42 is fixed")), "#42 is fixed")
    }

    func testListItemsKeepTheirIndentationAndGetABullet() {
        let rendered = ReplyMarkdown.render("- one\n  * nested\n+ three")
        XCTAssertEqual(text(rendered), "\u{2022} one\n  \u{2022} nested\n\u{2022} three")
    }

    func testEmphasisAtTheStartOfALineIsNotAListItem() {
        // `*word*` opens with a list marker's character and is not one: no space follows it.
        let rendered = ReplyMarkdown.render("*note* and **done**")
        XCTAssertEqual(text(rendered), "note and done")
    }

    func testTaskItemsShowABoxTickedOrNot() {
        let rendered = ReplyMarkdown.render("- [ ] open\n- [x] closed")
        XCTAssertEqual(text(rendered), "\u{2610} open\n\u{2611} closed")
    }

    func testANumberedItemKeepsItsNumber() {
        let rendered = ReplyMarkdown.render("1. first\n2) second")
        XCTAssertEqual(text(rendered), "1. first\n2) second")
    }

    func testAQuoteGetsABarForEachLevel() {
        let rendered = ReplyMarkdown.render("> quoted\n>> deeper")
        XCTAssertEqual(text(rendered), "\u{258E} quoted\n\u{258E} \u{258E} deeper")
    }

    func testARuleBecomesALine() {
        let rendered = ReplyMarkdown.render("above\n---\nbelow")
        XCTAssertEqual(
            text(rendered),
            "above\n" + String(repeating: "\u{2500}", count: 12) + "\nbelow"
        )
    }

    func testInlineSyntaxInsideAListItemIsStillRendered() {
        let rendered = ReplyMarkdown.render("- run `make test` **now**")
        XCTAssertEqual(text(rendered), "\u{2022} run make test now")
        XCTAssertEqual(strong(rendered), ["now"])
    }

    func testEmphasisAcrossTwoPlainLinesStillHolds() {
        // Plain lines are parsed together, so a pair that spans a line break is still a pair.
        let rendered = ReplyMarkdown.render("**strong\nstill strong** after")
        XCTAssertEqual(text(rendered), "strong\nstill strong after")
    }

    // MARK: - Tables

    func testATableIsItsOwnBlockWithEveryRowTheHeadersWidth() {
        let reply = """
        Before
        | Name | State |
        |------|:-----:|
        | builder | up |
        | planner |
        | reviewer | down | extra |
        After
        """
        let blocks = ReplyMarkdown.blocks(of: reply)

        guard blocks.count == 3,
              case .text(let before) = blocks[0],
              case .table(let table) = blocks[1],
              case .text(let after) = blocks[2]
        else {
            return XCTFail("expected text, a table, then text; got \(blocks)")
        }

        XCTAssertEqual(text(before), "Before")
        XCTAssertEqual(text(after), "After")
        XCTAssertEqual(table.header.map(text), ["Name", "State"])
        XCTAssertEqual(
            table.rows.map { $0.map(text) },
            [["builder", "up"], ["planner", ""], ["reviewer", "down"]],
            "a short row is padded and a long one cut, so the grid stays a grid"
        )
    }

    func testATableReadsARowToALineWhenSpokenOrCopied() {
        let rendered = ReplyMarkdown.render("| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(text(rendered), "A \u{2502} B\n1 \u{2502} 2")
    }

    func testABarInProseIsNotATable() {
        // No separator row under it, so it is a line that happens to hold a bar.
        let reply = "use a | b to pipe\nand carry on"
        XCTAssertEqual(ReplyMarkdown.blocks(of: reply).count, 1)
        XCTAssertEqual(text(ReplyMarkdown.render(reply)), reply)
    }

    func testASeparatorWithTheWrongNumberOfCellsOpensNoTable() {
        XCTAssertNil(ReplyMarkdown.tableHeader("| A | B |", separator: "|---|"))
        XCTAssertNotNil(ReplyMarkdown.tableHeader("| A | B |", separator: "|---|---|"))
    }

    func testAnEscapedBarStaysInItsCell() {
        XCTAssertEqual(ReplyMarkdown.cells(of: "| a \\| b | c |"), ["a | b", "c"])
    }

    // MARK: - With fences

    func testBlockSyntaxInsideAFenceIsLeftExactlyAsWritten() {
        let reply = "```\n# not a heading\n- not a list\n| not | a table |\n```"
        let blocks = ReplyMarkdown.blocks(of: reply)

        XCTAssertEqual(blocks, [.code("# not a heading\n- not a list\n| not | a table |")])
    }
}
