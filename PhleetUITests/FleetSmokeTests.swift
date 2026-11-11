import XCTest

/// Connect, see the fleet, and answer what is waiting — end to end, against the in-app scripted
/// orchestrator.
///
/// The double is selected by a launch argument rather than a build gate, so this drives the app
/// exactly as built. No network, no secret, and every value it types is obviously synthetic.
final class FleetSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testConnectSeeTheFleetAndAnswerAGate() throws {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArguments.scriptedBackend]
        app.launch()

        // Setup: the token first, then the address ending in a return, so the keyboard is down
        // before the connect control is needed.
        let token = element(in: app, .controlSetupTokenField)
        XCTAssertTrue(token.waitForExistence(timeout: 30), "the setup form never appeared")
        token.tap()
        token.typeText("synthetic-operator-token")

        let address = element(in: app, .controlSetupAddressField)
        address.tap()
        address.typeText("fleet.example.invalid\n")

        element(in: app, .controlSetupConnect).tap()

        // The fleet: what is waiting comes first, and the agent that is down is named.
        let gate = element(in: app, .fleetGate)
        XCTAssertTrue(gate.waitForExistence(timeout: 30), "the waiting gate never appeared")
        XCTAssertTrue(
            element(in: app, .fleetAgent).exists,
            "no agent is listed"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Scripted planner. Down"))
                .firstMatch
                .exists,
            "the agent that is down is not announced as down"
        )

        let fleet = XCTAttachment(screenshot: app.screenshot())
        fleet.name = "Fleet"
        fleet.lifetime = .keepAlways
        add(fleet)

        // The gate: a decision that needs a comment is unavailable without one.
        gate.tap()

        let approve = app.buttons["Approve Merge"]
        XCTAssertTrue(approve.waitForExistence(timeout: 30), "the decisions never appeared")
        XCTAssertFalse(
            app.buttons["Request Changes"].isEnabled,
            "a decision that requires a comment was offered without one"
        )

        // Two taps: choose, then send.
        approve.tap()
        let send = element(in: app, .gateConfirm)
        XCTAssertTrue(send.waitForExistence(timeout: 10), "choosing did not ask for confirmation")

        let decision = XCTAttachment(screenshot: app.screenshot())
        decision.name = "Decision"
        decision.lifetime = .keepAlways
        add(decision)

        send.tap()

        // Answered: back on the fleet, with nothing left waiting.
        XCTAssertTrue(
            element(in: app, .fleetNoGates).waitForExistence(timeout: 30),
            "the answered gate stayed on the list"
        )
        XCTAssertFalse(element(in: app, .fleetGate).exists)
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
