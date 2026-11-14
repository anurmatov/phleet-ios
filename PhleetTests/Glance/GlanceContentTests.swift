import XCTest
@testable import Phleet

/// What the widget shows in each case — decided in the app's code, so it is tested here and the
/// widget only draws it.
final class GlanceContentTests: XCTestCase {

    private func actions(_ control: FakeControlAPI, signedIn: Bool = true) -> QuickActions {
        QuickActions(
            credentialStore: InMemoryCredentialStore(credential: signedIn ? .fixture : nil),
            controlAPI: control,
            makeChatAPI: { _ in FakeFleetAPI() },
            newIdentifier: { "id" }
        )
    }

    func testAReadFleetShowsHowManyAreWaitingTheOldestAndWhoIsDown() async throws {
        let control = FakeControlAPI()
        control.agentsResult = .success(try ControlFixture.agents())
        control.workflowsResult = .success(try ControlFixture.runs())
        control.registryResult = .success(try ControlFixture.registry())
        let gates = PendingGates.derive(
            runs: try ControlFixture.runs(),
            registry: try ControlFixture.registry()
        )

        let content = await GlanceContent.load(using: actions(control))

        XCTAssertEqual(content.state, .current)
        XCTAssertEqual(content.waitingCount, gates.count)
        XCTAssertNotNil(content.firstWaiting)
        XCTAssertTrue(content.needsAttention)
        XCTAssertFalse(content.needingAttention.isEmpty, "the fixture has an agent that is down")
    }

    func testWithNoSignInTheWidgetSaysSoAndNeverShowsAZero() async {
        let content = await GlanceContent.load(using: actions(FakeControlAPI(), signedIn: false))

        XCTAssertEqual(content, .signedOut)
        XCTAssertFalse(content.needsAttention)
        XCTAssertNil(content.agentsLine)
        XCTAssertFalse(
            content.summaryLine.contains("0"),
            "a zero would read as nothing waiting, when nothing is known"
        )
    }

    func testAFleetThatDidNotAnswerIsNotShownAsAQuietOne() async {
        let control = FakeControlAPI()
        control.agentsResult = .failure(ControlAPIError.transport("offline"))

        let content = await GlanceContent.load(using: actions(control))

        XCTAssertEqual(content, .unreachable)
        XCTAssertNotEqual(content.waitingLine, GlanceContent(summary: quiet).waitingLine)
    }

    func testEveryFailureThatIsNotSignedOutReadsAsDidNotAnswer() {
        XCTAssertEqual(GlanceContent(failure: .signedOut), .signedOut)
        for failure in [QuickActions.Failure.unreachable, .refused, .agentUnavailable, .tooLong] {
            XCTAssertEqual(GlanceContent(failure: failure), .unreachable)
        }
    }

    private let quiet = QuickActions.FleetSummary(waiting: [], needingAttention: [], agentCount: 3)

    func testAQuietFleetSaysNothingIsWaitingAndThatEveryAgentIsUp() {
        let content = GlanceContent(summary: quiet)

        XCTAssertEqual(content.waitingCount, 0)
        XCTAssertFalse(content.needsAttention)
        XCTAssertEqual(content.summaryLine, content.waitingLine)
        XCTAssertNotNil(content.agentsLine)
    }

    func testTheOneLineFormCarriesTheCountAndHowManyAreDown() {
        let content = GlanceContent(
            summary: QuickActions.FleetSummary(
                waiting: ["Merge approval — example/project · PR #42", "Design approval — example/project · #7"],
                needingAttention: ["Planner"],
                agentCount: 3
            )
        )

        XCTAssertTrue(content.summaryLine.hasPrefix("2 "))
        XCTAssertTrue(content.summaryLine.contains(" · 1 "))
        XCTAssertEqual(content.firstWaiting, "Merge approval — example/project · PR #42")
        XCTAssertTrue(content.agentsLine?.hasSuffix("Planner") == true)
    }

    func testAFleetWithNoAgentsSaysNothingAboutAgents() {
        let content = GlanceContent(
            summary: QuickActions.FleetSummary(waiting: [], needingAttention: [], agentCount: 0)
        )
        XCTAssertNil(content.agentsLine)
    }

    func testEveryLineIsWordsFromTheCatalog() {
        let contents = [
            GlanceContent.signedOut,
            .unreachable,
            .example,
            GlanceContent(summary: quiet)
        ]
        for content in contents {
            for line in [content.waitingLine, content.summaryLine, content.agentsLine ?? ""] {
                XCTAssertFalse(line.contains("glance."), "a catalog key was shown as itself: \(line)")
            }
        }
    }

    func testTheExampleNamesNoRealFleet() {
        XCTAssertEqual(GlanceContent.example.state, .current)
        XCTAssertTrue(GlanceContent.example.firstWaiting?.contains("example/") == true)
    }
}
