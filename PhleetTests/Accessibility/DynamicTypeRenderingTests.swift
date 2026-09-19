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
        assertRenders(
            TranscriptEntryView(
                record: record(.working),
                activity: TurnActivity(submissionId: "s1", activity: .tool, toolName: "search"),
                sendAgain: {}
            ),
            "a working entry"
        )

        // `accessibilityReduceMotion` is a read-only environment value, so it cannot be written
        // from a test. The indicator therefore takes it as a parameter and is rendered both ways
        // directly: with motion reduced it is a static, labelled state rather than an animation,
        // and it still has to lay out at every size.
        for reduceMotion in [false, true] {
            assertRenders(
                ProgressIndicatorView(
                    activity: TurnActivity(
                        submissionId: "s1",
                        activity: .tool,
                        toolName: "search"
                    ),
                    reduceMotion: reduceMotion
                ),
                "the working indicator (reduceMotion: \(reduceMotion))"
            )
        }
    }

    func testTheWorkingIndicatorKeepsItsLabelWithMotionReduced() {
        // The label is what carries the meaning; the animation never did.
        for reduceMotion in [false, true] {
            assertRenders(
                ProgressIndicatorView(activity: nil, reduceMotion: reduceMotion),
                "the bare working indicator (reduceMotion: \(reduceMotion))"
            )
            XCTAssertFalse(
                AccessibilityIdentifier.conversationProgress.localizedLabel.isEmpty,
                "the indicator has no spoken label at reduceMotion: \(reduceMotion)"
            )
        }
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

    /// The whole thread rather than only the rows, because the composer grew a line of copy and
    /// a row-only render cannot see whether the composer still lays out at all.
    ///
    /// What this deliberately does **not** prove: `assertRenders` bounds width and leaves height
    /// free, so the render grows to fit whatever it is given and a composer pushed below the
    /// bottom of a real screen would still pass here. That claim needs a real viewport and
    /// belongs to `testTheSendButtonStaysReachableAtAccessibilitySizes` in the UI tests.
    func testTheThreadRendersAtEverySize() throws {
        let environment = AppEnvironment(
            credentialStore: InMemoryCredentialStore(
                credential: DeviceCredential(
                    origin: "https://server.invalid",
                    deviceId: "device-1",
                    deviceSecret: "secret-1",
                    clientInstanceId: "instance-1"
                )
            ),
            api: FakeFleetAPI(),
            stream: FakeConversationStream(),
            launchArguments: [],
            launchEnvironment: [:]
        )
        // The environment builds the thread's model from the stored credential, so this renders
        // the composition the app actually runs. Nothing reaches the network: `run()` is started
        // by `.task`, and `ImageRenderer` does not run tasks.
        let model = try XCTUnwrap(environment.conversation)

        assertRenders(ConversationView(model: model).environment(environment), "the thread")
    }

    func testTheMediaLimitationHasASpokenLabel() {
        // Stated, not implied by an absent button — and stated to VoiceOver too.
        let label = AccessibilityIdentifier.conversationMediaUnsupported.localizedLabel
        XCTAssertFalse(label.isEmpty)
        XCTAssertNotEqual(
            label,
            AccessibilityIdentifier.conversationMediaUnsupported.labelKey
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
