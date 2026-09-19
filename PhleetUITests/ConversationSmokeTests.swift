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

    /// The keyboard follows the person's last intent: up across a send they made with it up,
    /// gone on a tap outside, and **still** gone across a send they made with it down.
    ///
    /// That last case is the one worth having. Restoring focus unconditionally after a send
    /// would re-open a keyboard someone had just dismissed, which is the tap-outside fix
    /// undoing itself one tap later.
    func testTheKeyboardFollowsTheLastIntentAcrossASend() throws {
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

        // Fill the field *before* dismissing: `typeText` needs keyboard focus, so the draft for
        // the keyboard-down send has to be typed while the keyboard is still up.
        composer.tap()
        composer.typeText("again")

        // A coordinate rather than `.tap()` on the scroll view: the tap has to land somewhere
        // outside the composer, and that is true of the point whether or not the container
        // itself reports as hittable.
        tapOutsideTheComposer(in: app)
        wait(
            for: [keyboardGone(keyboard, "a tap outside the composer")],
            timeout: 10
        )

        // The draft survived the dismissal, so this sends with the keyboard down. Waiting on
        // "still absent" would fulfil instantly and prove nothing, so this waits for the send to
        // land — a real settling event — and only then asks whether the keyboard came back.
        let sent = entries(in: app).count
        element(in: app, .conversationSend).tap()
        let landed = expectation(
            for: NSPredicate(format: "count > %d", sent),
            evaluatedWith: entries(in: app)
        )
        landed.expectationDescription = "the second message reaches the transcript"
        wait(for: [landed], timeout: 30)

        XCTAssertFalse(
            keyboard.exists,
            "sending re-opened a keyboard the person had just dismissed"
        )
    }

    /// Scrolling dismisses the keyboard.
    ///
    /// Needs a transcript taller than the viewport, so the scripted backend is asked for a long
    /// reply — against a one-message thread there is nothing to scroll and the assertion would
    /// pass without exercising anything. `.interactively` dismisses on a drag *toward* the
    /// keyboard, so this is a real downward drag rather than a flick.
    func testScrollingDismissesTheKeyboard() throws {
        let app = launchAndOpenTheThread(extraArguments: [LaunchArguments.tallTranscript])

        let composer = element(in: app, .conversationComposer)
        composer.tap()
        composer.typeText("hello")

        let keyboard = app.keyboards.element
        guard keyboard.waitForExistence(timeout: 5) else {
            throw XCTSkip("no software keyboard on this simulator")
        }

        element(in: app, .conversationSend).tap()
        XCTAssertTrue(
            element(in: app, .conversationAgentReply).waitForExistence(timeout: 30),
            "the long reply never rendered"
        )

        let transcript = element(in: app, .conversationTranscript)
        transcript
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(
                forDuration: 0.1,
                thenDragTo: transcript.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 1.4)
                )
            )

        wait(for: [keyboardGone(keyboard, "a scroll")], timeout: 10)
    }

    /// The composer grew a line of copy. At the largest text size that line must not push the
    /// send button off the bottom of a real screen — which is a claim only a real viewport can
    /// settle, so it lives here rather than in the `ImageRenderer` suite.
    func testTheSendButtonStaysReachableAtAccessibilitySizes() throws {
        let app = launchAndOpenTheThread(
            extraArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        )

        let send = element(in: app, .conversationSend)
        XCTAssertTrue(send.waitForExistence(timeout: 30), "the send button never appeared")
        XCTAssertTrue(
            send.isHittable,
            "the composer pushed the send button off the screen at the largest text size"
        )
        XCTAssertTrue(
            element(in: app, .conversationComposer).isHittable,
            "the composer field is not reachable at the largest text size"
        )
    }

    private func entries(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.conversationEntry.identifier)
    }

    private func tapOutsideTheComposer(in app: XCUIApplication) {
        element(in: app, .conversationTranscript)
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .tap()
    }

    // `expectation(for:evaluatedWith:)` is declared as returning `XCTestExpectation`, whatever it
    // hands back at runtime, so that is what this returns. `wait(for:timeout:)` takes those.
    private func keyboardGone(
        _ keyboard: XCUIElement,
        _ after: String
    ) -> XCTestExpectation {
        let gone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: keyboard
        )
        gone.expectationDescription = "the keyboard leaves on \(after)"
        return gone
    }

    /// Enrollment through to an open thread. Shared so each test asserts its own behaviour
    /// rather than re-typing the journey.
    private func launchAndOpenTheThread(
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArguments.scriptedBackend] + extraArguments
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
