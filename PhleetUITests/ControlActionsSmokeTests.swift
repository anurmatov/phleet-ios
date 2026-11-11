import XCTest

/// Act on an agent, read its log, cancel a run and start one — end to end, against the in-app
/// scripted orchestrator.
///
/// Each step asserts the *effect* of the tap, which the scripted backend makes observable: the
/// restarted agent comes up, the cancelled run says so, the started workflow reports its run.
final class ControlActionsSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRestartAnAgentAndReadItsLog() throws {
        let app = launchConnected()

        // The agent that is down is first on the list.
        let planner = labelled("Scripted planner. Down", in: app)
        XCTAssertTrue(planner.waitForExistence(timeout: 30), "the agent that is down is not listed")
        planner.tap()

        // Two taps: choose, then confirm.
        let restart = app.buttons["Restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 30), "no restart is offered for a down agent")
        restart.tap()

        let confirm = element(in: app, .agentActionConfirm)
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "choosing did not ask for confirmation")
        confirm.tap()

        XCTAssertTrue(
            element(in: app, .agentActionState).waitForExistence(timeout: 30),
            "nothing reported what happened to the restart"
        )
        // The agent's own state is the evidence that it worked.
        let up = app.descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.agentDetailHealth.identifier)
            .matching(NSPredicate(format: "label CONTAINS %@", "Idle"))
            .firstMatch
        XCTAssertTrue(up.waitForExistence(timeout: 30), "the restarted agent never came up")

        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "Agent"
        detail.lifetime = .keepAlways
        add(detail)

        // The log.
        let logs = element(in: app, .agentLogOpen)
        XCTAssertTrue(logs.waitForExistence(timeout: 10), "the log link is missing")
        logs.tap()
        XCTAssertTrue(
            labelled("scripted log line one", in: app).waitForExistence(timeout: 30),
            "the log never showed a line"
        )

        let log = XCTAttachment(screenshot: app.screenshot())
        log.name = "Log"
        log.lifetime = .keepAlways
        add(log)
    }

    func testCancelARunAndStartAWorkflow() throws {
        let app = launchConnected()
        AppTabs.selectRuns(in: app)

        // All three sections have something in them.
        let running = labelled("scripted/project · PR #42", in: app)
        XCTAssertTrue(running.waitForExistence(timeout: 30), "the run in progress is not listed")
        XCTAssertTrue(
            labelled("scripted/project · PR #41", in: app).waitForExistence(timeout: 30),
            "the failed run is not listed"
        )
        XCTAssertTrue(labelled("scripted/project · PR #40", in: app).exists)

        let list = XCTAttachment(screenshot: app.screenshot())
        list.name = "Runs"
        list.lifetime = .keepAlways
        add(list)

        // Cancel: two taps, then the run says a cancel was requested.
        running.tap()
        XCTAssertTrue(
            element(in: app, .runEvent).waitForExistence(timeout: 30),
            "the run's history never loaded"
        )
        let cancel = element(in: app, .runCancel)
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "a running run offered no cancel")
        cancel.tap()
        let confirm = element(in: app, .runCancelConfirm)
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "cancel did not ask for confirmation")
        confirm.tap()

        // The scripted run closes on cancel, so the screen stops offering one.
        let gone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: element(in: app, .runCancelConfirm)
        )
        wait(for: [gone], timeout: 30)
        XCTAssertFalse(element(in: app, .runCancel).exists, "a cancelled run still offers cancel")

        app.navigationBars.buttons.firstMatch.tap()

        // Start: pick the type, fill the required input, start.
        let start = element(in: app, .runsStart)
        XCTAssertTrue(start.waitForExistence(timeout: 10), "starting a workflow is not offered")
        start.tap()

        let type = element(in: app, .startType)
        XCTAssertTrue(type.waitForExistence(timeout: 30), "no workflow type is listed")
        type.tap()

        let required = app.descendants(matching: .any)
            .matching(NSPredicate(format: "placeholderValue == %@", "Required"))
            .firstMatch
        XCTAssertTrue(required.waitForExistence(timeout: 10), "the required input is missing")
        required.tap()
        required.typeText("a scripted topic")

        element(in: app, .startSubmit).tap()

        let done = element(in: app, .startDone)
        XCTAssertTrue(done.waitForExistence(timeout: 30), "the workflow never reported starting")

        let started = XCTAttachment(screenshot: app.screenshot())
        started.name = "Started"
        started.lifetime = .keepAlways
        add(started)

        done.tap()
        XCTAssertTrue(
            labelled("scripted-started-1", in: app).waitForExistence(timeout: 30),
            "the started run is not on the running list"
        )
    }

    /// Setup through to the fleet. Shared so each test asserts its own behaviour.
    private func launchConnected() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArguments.scriptedBackend]
        app.launch()

        let token = element(in: app, .controlSetupTokenField)
        XCTAssertTrue(token.waitForExistence(timeout: 30), "the setup form never appeared")
        token.tap()
        token.typeText("synthetic-operator-token")

        let address = element(in: app, .controlSetupAddressField)
        address.tap()
        address.typeText("fleet.example.invalid\n")

        element(in: app, .controlSetupConnect).tap()

        XCTAssertTrue(
            element(in: app, .fleetAgent).waitForExistence(timeout: 30),
            "the fleet never appeared"
        )
        return app
    }

    private func labelled(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    private func element(
        in app: XCUIApplication,
        _ identifier: AccessibilityIdentifier
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier.identifier)
            .firstMatch
    }
}
