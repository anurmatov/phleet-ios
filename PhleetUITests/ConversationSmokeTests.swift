import XCTest

/// Enroll, see the agent, open the thread, send, and see a terminal — end to end, against the
/// in-app scripted backend.
///
/// The double is selected by a launch argument rather than a build gate, so this drives the app
/// exactly as built. No network, no secret, and every value it types is obviously synthetic.
final class ConversationSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnrollOpenThreadSendAndSeeATerminal() throws {
        let app = launchAndOpenTheThread()

        let composer = element(in: app, .conversationComposer)
        composer.tap()
        composer.typeText("hello")

        element(in: app, .conversationSend).tap()

        let entry = element(in: app, .conversationEntry)
        XCTAssertTrue(entry.waitForExistence(timeout: 30), "the message never appeared")

        let reply = element(in: app, .conversationAgentReply)
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "the terminal never rendered")

        // Said out loud rather than left to an absent paperclip.
        XCTAssertTrue(
            element(in: app, .conversationMediaUnsupported).exists,
            "the composer never stated that images are unsupported"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Thread"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// The keyboard stays up across a send and goes away on a tap outside the composer.
    ///
    /// Scroll dismissal is `scrollDismissesKeyboard(.interactively)` and is not asserted here:
    /// it needs a transcript taller than the viewport, which the scripted backend does not
    /// produce, and asserting it against a one-message thread would pass without exercising
    /// anything.
    func testTheKeyboardSurvivesASendAndLeavesOnATapOutside() throws {
        let app = launchAndOpenTheThread()

        let composer = element(in: app, .conversationComposer)
        composer.tap()
        composer.typeText("hello")

        let keyboard = app.keyboards.element
        guard keyboard.waitForExistence(timeout: 5) else {
            // A simulator attached to the host's hardware keyboard shows no software keyboard,
            // so there is nothing to observe being dismissed. Skipped rather than failed: the
            // absence is the runner's configuration, not the app's behaviour.
            throw XCTSkip("no software keyboard on this simulator")
        }

        element(in: app, .conversationSend).tap()
        XCTAssertTrue(
            element(in: app, .conversationEntry).waitForExistence(timeout: 30),
            "the message never appeared"
        )
        XCTAssertTrue(
            keyboard.exists,
            "the keyboard went away on send, so a burst of messages costs a tap each"
        )

        // A coordinate rather than `.tap()` on the scroll view: the tap has to land somewhere
        // outside the composer, and that is true of the point whether or not the container
        // itself reports as hittable.
        element(in: app, .conversationTranscript)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .tap()

        let dismissed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: keyboard
        )
        dismissed.expectationDescription = "the keyboard leaves on a tap outside the composer"
        wait(for: [dismissed], timeout: 10)
    }

    /// Enrollment through to an open thread. Shared so each test asserts its own behaviour
    /// rather than re-typing the journey.
    private func launchAndOpenTheThread() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArguments.scriptedBackend]
        app.launch()

        // Enrollment: type the origin, paste the code.
        let address = element(in: app, .enrollmentAddressField)
        XCTAssertTrue(address.waitForExistence(timeout: 30), "the enrollment form never appeared")
        address.tap()
        address.typeText("server.invalid")

        let code = element(in: app, .enrollmentCodeField)
        code.tap()
        code.typeText("synthetic-enrollment-code")

        element(in: app, .enrollmentConnect).tap()

        // The agent: one entry, derived from the session, with no selection model.
        let agentLabel = element(in: app, .agentLabel)
        XCTAssertTrue(agentLabel.waitForExistence(timeout: 30), "the agent entry never appeared")

        element(in: app, .agentOpenThread).tap()

        let composer = element(in: app, .conversationComposer)
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "the composer never appeared")
        return app
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
