import SwiftUI
import XCTest
@testable import Phleet

/// The rows of the schedules, memory and chat screens, an agent's Markdown, and a sent image,
/// rendered across the Dynamic Type range.
///
/// Same rule as `ControlRenderingTests`: a zero-height render is the signal that a row collapsed
/// or failed to lay out at all, and the accessibility sizes are where that happens.
@MainActor
final class NewScreensRenderingTests: XCTestCase {

    private let sizes: [DynamicTypeSize] = [
        .xSmall, .medium, .xxxLarge,
        .accessibility1, .accessibility3, .accessibility5
    ]

    private func assertRenders(
        _ view: some View,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for size in sizes {
            let renderer = ImageRenderer(
                content: view
                    .environment(\.dynamicTypeSize, size)
                    .frame(width: 390)
            )
            renderer.scale = 1

            guard let image = renderer.uiImage else {
                XCTFail("\(label) produced no render at \(size)", file: file, line: line)
                continue
            }
            XCTAssertGreaterThan(
                image.size.height,
                0,
                "\(label) collapsed to zero height at \(size)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Schedules

    func testAScheduleRowRendersPausedAndRunning() {
        for isPaused in [false, true] {
            let schedule = FleetSchedule(
                scheduleId: "a-schedule-with-an-identifier-long-enough-to-wrap",
                namespace: "fleet",
                workflowType: "AWorkflowTypeWithANameLongEnoughToWrapAtLargeSizes",
                cronExpression: "0 3 * * 1-5",
                isPaused: isPaused,
                note: "A note"
            )
            assertRenders(ScheduleRow(schedule: schedule), "a schedule row (paused: \(isPaused))")
            XCTAssertEqual(
                ScheduleRow.caption(for: schedule).contains(String(localized: "schedule.paused")),
                isPaused,
                "whether it is paused is said in words, not only by the symbol"
            )
        }
    }

    func testEveryScheduleActionStateRenders() {
        let states: [SchedulesModel.ActionState] = [
            .sending(.pause),
            .done(.trigger),
            .failed(.unpause, .outcomeUnknown),
            .failed(.trigger, .refused("Schedule not found"))
        ]
        for state in states {
            assertRenders(ScheduleActionStateRow(state: state), "a schedule action state")
        }
    }

    func testEveryScheduleActionHasATitle() {
        let titles = ScheduleAction.allCases.map(\.localizedTitle)
        XCTAssertEqual(Set(titles).count, ScheduleAction.allCases.count)
        for action in ScheduleAction.allCases {
            XCTAssertNotEqual(action.localizedTitle, action.titleKey, "\(action.titleKey) is missing")
        }
    }

    // MARK: - Memory

    func testAMemoryResultRowRendersWithAndWithoutItsDetails() {
        let full = MemorySearchResult(
            id: "m-1",
            title: "A memory with a title long enough to wrap onto a second line",
            project: "fleet",
            type: "reference",
            tags: ["deploy"],
            snippet: "A snippet long enough to wrap, and then to be cut off after a few lines "
                + "at ordinary sizes, which is what the row promises to do with it."
        )
        assertRenders(MemoryResultRow(result: full), "a memory result")
        assertRenders(
            MemoryResultRow(result: MemorySearchResult(id: "m-2", title: "Bare")),
            "a bare memory result"
        )
        XCTAssertEqual(MemoryResultRow.caption(for: full), "fleet · reference")
        XCTAssertNil(MemoryResultRow.caption(for: MemorySearchResult(id: "m-2", title: "Bare")))
    }

    // MARK: - Markdown

    func testMarkdownWithEveryKindOfBlockRenders() {
        let reply = """
        # A heading
        Some prose with **strong** text and `code`.

        - one
        - [x] two

        | Agent | State | Task |
        |-------|-------|------|
        | builder | working | A task long enough to wrap inside its cell |
        | planner | down | |

        ```
        make test
        ```
        > and a quote
        """
        assertRenders(
            MarkdownBlocksView(
                text: reply,
                identifier: .conversationReplyBody,
                spokenPrefix: "Agent",
                copyActionKey: "conversation.copy.reply"
            ),
            "a reply with every kind of block"
        )
        assertRenders(MarkdownBlocksView(text: "One line."), "a one-line reply")
    }

    // MARK: - Chat

    func testAChatRowRendersWithAndWithoutTheFleetsViewOfTheAgent() {
        let agent = ChatAgent(agentName: "builder", displayName: "An agent with a long display name")
        let working = FleetAgent(
            agentName: "builder",
            currentTask: "A task description long enough to wrap onto a second line.",
            effectiveStatus: "busy"
        )
        assertRenders(ChatAgentRow(agent: agent), "a bare chat row")
        assertRenders(
            ChatAgentRow(
                agent: agent,
                fleetAgent: working,
                hasNewActivity: true,
                lastActivity: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            "a chat row with state, a time and a mark"
        )
    }

    func testASentImageRendersBeforeItsBytesArriveAndWhenTheyCannotBeHad() {
        let image = AttachmentDescriptor(attachmentId: "a-1")
        let file = AttachmentDescriptor(attachmentId: "a-2", kind: "document")

        assertRenders(SentAttachmentView(attachment: image, images: nil), "an image with no bytes")
        assertRenders(SentAttachmentView(attachment: file, images: nil), "an attachment it cannot draw")
        assertRenders(
            TranscriptEntryView(
                record: SubmissionRecord(id: "s-1", text: "", attachments: [image]),
                activity: nil,
                sendAgain: {}
            ),
            "a message that is only an image"
        )
    }

    func testAnImageIsScaledToFitWithoutBeingEnlarged() {
        XCTAssertEqual(
            SentAttachmentView.fitting(CGSize(width: 2000, height: 1000), within: 500),
            CGSize(width: 500, height: 250)
        )
        XCTAssertEqual(
            SentAttachmentView.fitting(CGSize(width: 200, height: 100), within: 500),
            CGSize(width: 200, height: 100)
        )
    }

    // MARK: - Settings and links

    func testTheConfirmItsYouSectionRendersOnAndOff() async {
        let model = OwnerConfirmation(check: FakeOwnerCheck(), preferences: InMemoryPreferenceStore())
        assertRenders(List { OwnerConfirmationSection(model: model) }.frame(height: 400), "the switch, off")

        await model.setRequired(true, reason: "the setting")
        assertRenders(List { OwnerConfirmationSection(model: model) }.frame(height: 400), "the switch, on")
    }

    func testARunWithAPullRequestRendersItsLink() {
        let run = WorkflowRun(
            workflowId: "pr-42",
            runId: "run-1",
            workflowType: "T",
            namespace: "fleet",
            prNumber: 42,
            repo: "example/project"
        )
        assertRenders(RunWebLinkRow(run: run), "the pull request link")
    }

    func testEveryNewAgentActionHasATitleAndASymbol() {
        XCTAssertNotEqual(AgentAction.reprovision.localizedTitle, AgentAction.reprovision.titleKey)
        XCTAssertFalse(AgentAction.reprovision.symbolName.isEmpty)
    }
}
