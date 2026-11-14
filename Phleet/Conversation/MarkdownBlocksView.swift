import SwiftUI
import UIKit

/// Markdown someone else wrote, laid out top to bottom: text, code blocks and tables.
///
/// Each run of text is its own selectable `Text`, so a long press selects within it and Select
/// All takes that run. What is spoken, and what the copy action takes, is the whole of it as
/// plain text — the characters without their Markdown punctuation.
///
/// Nothing here scrolls sideways. A long line of code wraps and a wide table's columns narrow,
/// because a region that scrolls on its own inside a transcript steals the drag that was meant
/// for the transcript.
struct MarkdownBlocksView: View {

    let text: String

    /// The hook on each run of text, when the caller has one for it.
    var identifier: AccessibilityIdentifier?

    /// Spoken before the first run of text: who wrote this.
    var spokenPrefix: String?

    /// The name of the copy action, for VoiceOver. No action when `nil`.
    var copyActionKey: LocalizedStringKey?

    var body: some View {
        let blocks = ReplyMarkdown.blocks(of: text)
        let plain = String(ReplyMarkdown.render(text).characters)
        let firstText = blocks.firstIndex { block in
            if case .text = block { return true }
            return false
        }

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .text(let rendered):
                    textBlock(rendered, isFirst: index == firstText, plain: plain)
                case .code(let code):
                    codeBlock(code)
                case .table(let table):
                    tableBlock(table)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func textBlock(_ rendered: AttributedString, isFirst: Bool, plain: String) -> some View {
        let spoken = String(rendered.characters)
        let label = isFirst ? [spokenPrefix, spoken].compactMap { $0 }.joined(separator: ". ") : spoken
        let body = Text(rendered)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier?.identifier ?? "")
            .accessibilityLabel(label)

        if let copyActionKey {
            body.accessibilityAction(named: Text(copyActionKey)) {
                UIPasteboard.general.string = plain
            }
        } else {
            body
        }
    }

    /// As written, in a monospaced face on its own ground so where the code starts and stops is
    /// plain to see.
    private func codeBlock(_ code: String) -> some View {
        Text(verbatim: code)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(String(localized: "markdown.code") + ". " + code)
    }

    private func tableBlock(_ table: ReplyMarkdown.Table) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                    Text(cell)
                        .font(.footnote)
                }
            }
            Divider()
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .font(.footnote)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
