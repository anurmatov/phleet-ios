import SwiftUI
import XCTest
@testable import Phleet

/// Accessibility as an acceptance criterion rather than a later sweep.
///
/// Every view here is rendered across the whole Dynamic Type range, including the accessibility
/// sizes, and with Reduce Motion both off and on. A zero-height render is the signal that a row
/// collapsed or failed to lay out at all.
@MainActor
final class DynamicTypeRenderingTests: XCTestCase {

    private let sizes: [DynamicTypeSize] = [
        .xSmall, .medium, .xxxLarge,
        .accessibility1, .accessibility3, .accessibility5
    ]

    private func record(
        _ state: SubmissionState,
        text: String? = "A message the person typed",
        reply: AgentReply? = nil,
        answeredTogether: Bool = false
    ) -> SubmissionRecord {
        SubmissionRecord(
            id: "s1",
            text: text,
            state: state,
            isAnsweredTogether: answeredTogether,
            reply: reply
        )
    }

    private func assertRenders(
        _ view: some View,
        _ label: String,
        reduceMotion: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for size in sizes {
            let renderer = ImageRenderer(
                content: view
                    .environment(\.dynamicTypeSize, size)
                    .environment(\.accessibilityReduceMotion, reduceMotion)
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
            XCTAssertGreaterThan(image.size.width, 0, file: file, line: line)
        }
    }

    func testATranscriptEntryRendersAtEverySize() {
        let reply = AgentReply(
            id: "e1",
            text: "A reply long enough to wrap several times at accessibility sizes.",
            completion: .completed,
            isPartial: false,
            truncated: false,
            isRecovered: false
        )

        assertRenders(
            TranscriptEntryView(
                record: record(.completed(
                    TurnFinalPayload(
                        text: reply.text,
                        completion: .completed,
                        isPartial: false,
                        truncated: false,
                        mergedSubmissionIds: ["s1"]
                    )
                ), reply: reply),
                activity: nil,
                sendAgain: {}
            ),
            "a completed entry"
        )
    }

    func testTheWorkingIndicatorRendersWithAndWithoutMotion() {
        let view = TranscriptEntryView(
            record: record(.working),
            activity: TurnActivity(submissionId: "s1", activity: .tool, toolName: "search"),
            sendAgain: {}
        )

        assertRenders(view, "a working entry with motion")
        // With Reduce Motion on the indicator is a static, labelled state rather than an
        // animation — and it still has to lay out.
        assertRenders(view, "a working entry without motion", reduceMotion: true)
    }

    func testTheThirdStateRendersAtEverySize() {
        for reason in [
            OutcomeUnknownReason.turnReaped,
            .terminalEventOversize,
            .attemptAbandoned,
            .unrecognized("a-reason-this-build-has-never-seen")
        ] {
            assertRenders(
                TranscriptEntryView(
                    record: record(.outcomeUnknown(reason)),
                    activity: nil,
                    sendAgain: {}
                ),
                "outcome unknown (\(reason.rawValue))"
            )
        }
    }

    func testAMergedGroupMemberRendersItsMarker() {
        assertRenders(
            TranscriptEntryView(
                record: record(
                    .completed(
                        TurnFinalPayload(
                            text: "",
                            completion: .idle,
                            isPartial: false,
                            truncated: false,
                            mergedSubmissionIds: ["s1", "s2"]
                        )
                    ),
                    answeredTogether: true
                ),
                activity: nil,
                sendAgain: {}
            ),
            "an answered-together entry"
        )
    }

    func testEveryConnectionStateRendersItsBanner() {
        let states: [ConversationModel.ConnectionState] = [
            .idle, .connecting, .live, .waiting(seconds: 4), .rateLimited(seconds: 12),
            .superseded, .notPermitted, .unavailable, .revoked, .offline
        ]

        for state in states {
            assertRenders(ConnectionBanner(state: state, resume: {}), "banner \(state)")
        }
    }
}
