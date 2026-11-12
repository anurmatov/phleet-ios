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
        token.focusAndType("synthetic-operator-token")

        let address = element(in: app, .controlSetupAddressField)
        address.focusAndType("fleet.example.invalid\n")

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

    /// A token the orchestrator rejects is refused at setup, where it can be retyped, and
    /// nothing is stored: the form is still there and the fleet never appears.
    func testAnOperatorTokenTheOrchestratorRejectsIsRefusedAtSetup() throws {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArguments.scriptedBackend]
        app.launch()

        let token = element(in: app, .controlSetupTokenField)
        XCTAssertTrue(token.waitForExistence(timeout: 30), "the setup form never appeared")
        // The one value the scripted orchestrator rejects; see `ScriptedControlBackend`.
        token.focusAndType("a-token-the-scripted-orchestrator-rejects")

        let address = element(in: app, .controlSetupAddressField)
        address.focusAndType("fleet.example.invalid\n")

        element(in: app, .controlSetupConnect).tap()

        XCTAssertTrue(
            element(in: app, .controlSetupTokenMessage).waitForExistence(timeout: 30),
            "a rejected token was not reported against the token field"
        )
        XCTAssertFalse(element(in: app, .fleetAgent).exists, "a rejected token still connected")
        XCTAssertTrue(element(in: app, .controlSetupConnect).exists)
    }

    /// Notifications are turned on and off from the connection sheet, and the state is said in
    /// words each time. Under the scripted backend the system's permission prompt and Apple's
    /// token are stood in for, so this covers the app's own steps and not the system's.
    func testNotificationsCanBeTurnedOnAndOff() throws {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArguments.scriptedBackend]
        app.launch()

        let scan = element(in: app, .controlSetupScan)
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "the setup form never appeared")
        scan.tap()
        element(in: app, .controlSetupConnect).tap()
        XCTAssertTrue(
            element(in: app, .fleetAgent).waitForExistence(timeout: 30),
            "the fleet never appeared"
        )

        element(in: app, .fleetConnection).tap()

        let turnOn = element(in: app, .pushTurnOn)
        XCTAssertTrue(turnOn.waitForExistence(timeout: 30), "notifications are not offered")
        XCTAssertTrue(state(in: app, beginning: "Off").exists, "notifications did not start off")
        turnOn.tap()

        XCTAssertTrue(
            state(in: app, beginning: "On").waitForExistence(timeout: 30),
            "notifications never reported being on"
        )

        let sheet = XCTAttachment(screenshot: app.screenshot())
        sheet.name = "Notifications"
        sheet.lifetime = .keepAlways
        add(sheet)

        let turnOff = element(in: app, .pushTurnOff)
        XCTAssertTrue(turnOff.waitForExistence(timeout: 10), "turning off is not offered once on")
        turnOff.tap()
        XCTAssertTrue(
            state(in: app, beginning: "Off").waitForExistence(timeout: 30),
            "notifications never reported being off"
        )
    }

    private func state(in app: XCUIApplication, beginning prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.pushState.identifier)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
    }

    /// Scanning a setup code fills the form and stops there: the address it read is on screen,
    /// and connecting is still a separate tap. A simulator has no camera, so the scripted
    /// backend stands in for one and "scans" a valid code.
    func testScanningASetupCodeFillsTheFormAndConnectingIsStillASeparateTap() throws {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArguments.scriptedBackend]
        app.launch()

        let scan = element(in: app, .controlSetupScan)
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "the scan control is missing")
        scan.tap()

        XCTAssertTrue(
            element(in: app, .controlSetupScanNotice).waitForExistence(timeout: 10),
            "nothing said the code was read"
        )
        let address = element(in: app, .controlSetupAddressField)
        XCTAssertEqual(address.value as? String, "https://scripted.example.invalid")
        XCTAssertFalse(
            element(in: app, .fleetAgent).exists,
            "scanning connected on its own, before the address could be checked"
        )

        let filled = XCTAttachment(screenshot: app.screenshot())
        filled.name = "Scanned"
        filled.lifetime = .keepAlways
        add(filled)

        element(in: app, .controlSetupConnect).tap()
        XCTAssertTrue(
            element(in: app, .fleetAgent).waitForExistence(timeout: 30),
            "the scanned connection never reached the fleet"
        )
    }

    /// Some other QR code is refused by name and fills nothing.
    func testAScanThatIsNotASetupCodeFillsNothing() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            LaunchArguments.scriptedBackend,
            LaunchArguments.unreadableSetupCode
        ]
        app.launch()

        let scan = element(in: app, .controlSetupScan)
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "the scan control is missing")
        scan.tap()

        let notice = app.descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.controlSetupScanNotice.identifier)
            .matching(NSPredicate(format: "label CONTAINS %@", "not a setup code"))
            .firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "an unreadable code was not refused")

        let address = element(in: app, .controlSetupAddressField)
        let value = address.value as? String ?? ""
        XCTAssertFalse(value.contains("example.invalid"), "an unreadable code filled the address")
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
