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

        // The thread.
        let composer = element(in: app, .conversationComposer)
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "the composer never appeared")
        composer.tap()
        composer.typeText("hello")

        element(in: app, .conversationSend).tap()

        let entry = element(in: app, .conversationEntry)
        XCTAssertTrue(entry.waitForExistence(timeout: 30), "the message never appeared")

        let reply = element(in: app, .conversationAgentReply)
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "the terminal never rendered")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Thread"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
