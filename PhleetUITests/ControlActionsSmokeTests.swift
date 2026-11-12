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
        required.focusAndType("a scripted topic")

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

    func testHumanInputChoiceKeepsOrderAndNeedsExplicitConfirmation() throws {
        let app = launchConnected(humanMode: LaunchArguments.humanInputChoice)
        try openHumanInput(app, mode: "choice")
        let second = app.buttons["Second choice 🧭"]
        scrollTo(second, in: app)
        XCTAssertTrue(second.exists)
        let choices = app.buttons.matching(identifier: AccessibilityIdentifier.humanInputChoice.identifier)
        XCTAssertEqual(choices.count, 2)
        XCTAssertEqual(choices.element(boundBy: 0).label, "Second choice 🧭")
        XCTAssertEqual(choices.element(boundBy: 1).label, "First choice {{literal}}")
        let review = element(in: app, .gateDecision)
        scrollTo(review, in: app)
        XCTAssertFalse(review.isEnabled, "no default answer")
        scrollTo(second, in: app)
        second.tap()
        try confirmHumanInput(app, mode: "choice")
    }

    func testHumanInputTextKeepsLiteralMultilineAnswer() throws {
        let app = launchConnected(humanMode: LaunchArguments.humanInputText)
        try openHumanInput(app, mode: "text")
        let answer = element(in: app, .humanInputAnswer)
        scrollTo(answer, in: app)
        answer.focusAndType("  literal {{answer}}\nsecond line  ")
        app.swipeUp()
        try confirmHumanInput(app, mode: "text")
    }

    func testHumanInputPresetCancelSendsNothing() throws {
        let app = launchConnected(humanMode: LaunchArguments.humanInputPreset)
        try openHumanInput(app, mode: "preset")
        let reject = app.buttons["Reject"]
        scrollTo(reject, in: app)
        reject.tap()
        let review = element(in: app, .gateDecision)
        scrollTo(review, in: app)
        review.tap()
        let cancel = element(in: app, .gateCancel)
        scrollTo(cancel, in: app)
        cancel.tap()
        XCTAssertFalse(element(in: app, .gateConfirm).exists)
        XCTAssertTrue(element(in: app, .gateDecision).exists)
        try confirmHumanInput(app, mode: "preset")
    }

    func testHumanInputHistoryFailureOffersNoAnswerControls() throws {
        let app = launchConnected(humanMode: LaunchArguments.humanInputChoice,
                                  extra: [LaunchArguments.humanInputUnavailable])
        element(in: app, .fleetGate).tap()
        XCTAssertTrue(element(in: app, .humanInputReload).waitForExistence(timeout: 30))
        XCTAssertFalse(element(in: app, .gateConfirm).exists)
        XCTAssertFalse(element(in: app, .humanInputChoice).exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(in: app, .fleetGate).waitForExistence(timeout: 10))
    }

    func testHumanInputReadOnlyShowsLiteralQuestionWithoutSend() throws {
        let app = launchConnected(humanMode: LaunchArguments.humanInputText,
                                  extra: [LaunchArguments.humanInputReadOnly])
        try openHumanInput(app, mode: "read-only")
        let notice = element(in: app, .gateNotice)
        scrollTo(notice, in: app)
        XCTAssertTrue(notice.exists)
        XCTAssertFalse(element(in: app, .humanInputAnswer).exists)
        XCTAssertFalse(element(in: app, .gateDecision).exists)
        XCTAssertFalse(element(in: app, .gateConfirm).exists)
    }

    private func openHumanInput(_ app: XCUIApplication, mode: String) throws {
        let gate = element(in: app, .fleetGate)
        XCTAssertTrue(gate.waitForExistence(timeout: 30))
        gate.tap()
        let question = element(in: app, .humanInputQuestion)
        XCTAssertTrue(question.waitForExistence(timeout: 30))
        scrollTo(question, in: app)
        XCTAssertEqual(question.label, "Which \"answer\"?\n{{literal}} 🧭")
        captureHumanInput(app, name: mode + "-literal-request")
    }

    private func confirmHumanInput(_ app: XCUIApplication, mode: String) throws {
        let review = element(in: app, .gateDecision)
        scrollTo(review, in: app)
        XCTAssertTrue(review.isEnabled)
        XCTAssertFalse(element(in: app, .gateConfirm).exists)
        review.tap()
        let send = element(in: app, .gateConfirm)
        scrollTo(send, in: app)
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        captureHumanInput(app, name: mode + "-confirm")
        send.tap()
        XCTAssertTrue(element(in: app, .fleetNoGates).waitForExistence(timeout: 30))
    }

    private func captureHumanInput(_ app: XCUIApplication, name: String) {
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "human-input-" + name
        screen.lifetime = .keepAlways
        add(screen)
        let accessibility = XCTAttachment(string: app.debugDescription)
        accessibility.name = "human-input-accessibility-" + name
        accessibility.lifetime = .keepAlways
        add(accessibility)
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable {
            if element.exists && element.frame.minY < app.frame.midY { app.swipeDown() }
            else { app.swipeUp() }
        }
    }

    /// Setup through to the fleet. Shared so each test asserts its own behaviour.
    private func launchConnected(humanMode: String? = nil, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArguments.scriptedBackend] + (humanMode.map { [$0] } ?? []) + extra
        app.launch()

        // The scripted stand-in for the camera fills the form, so nothing here types. Typing
        // into the form is covered once, by `FleetSmokeTests`; every other journey that merely
        // needs a connection should not depend on the keyboard.
        let scan = element(in: app, .controlSetupScan)
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "the setup form never appeared")
        scan.tap()
        XCTAssertTrue(
            element(in: app, .controlSetupScanNotice).waitForExistence(timeout: 10),
            "the setup code was not read"
        )

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
