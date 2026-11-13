import XCTest

/// Sign in, see the fleet, and answer what is waiting — end to end, against the in-app scripted
/// orchestrator.
///
/// The double is selected by a launch argument rather than a build gate, so this drives the app
/// exactly as built. No network, no secret, and every value it types is obviously synthetic.
final class FleetSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSignInSeeTheFleetAndAnswerAGate() throws {
        let app = SignIn.launch()

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

    /// Notifications are turned on and off from the connection sheet, and the state is said in
    /// words each time. Under the scripted backend the system's permission prompt and Apple's
    /// token are stood in for, so this covers the app's own steps and not the system's.
    func testNotificationsCanBeTurnedOnAndOff() throws {
        let app = SignIn.launch()

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

    /// Scanning shows the address the code names and stops there: connecting is still a
    /// separate tap. A simulator has no camera, so the scripted backend stands in for one and
    /// "scans" a valid code.
    func testScanningShowsTheAddressAndConnectingIsStillASeparateTap() throws {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArguments.scriptedBackend]
        app.launch()

        let scan = element(in: app, .setupScan)
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "the scan control is missing")
        scan.tap()

        let scanned = element(in: app, .setupScanned)
        XCTAssertTrue(scanned.waitForExistence(timeout: 10), "nothing said the code was read")
        XCTAssertTrue(
            scanned.label.contains("scripted.example.invalid"),
            "the address the code names is not on screen to be checked: \(scanned.label)"
        )
        XCTAssertFalse(
            element(in: app, .fleetAgent).exists,
            "scanning signed in on its own, before the address could be checked"
        )

        let read = XCTAttachment(screenshot: app.screenshot())
        read.name = "Scanned"
        read.lifetime = .keepAlways
        add(read)

        element(in: app, .setupConnect).tap()
        XCTAssertTrue(
            element(in: app, .fleetAgent).waitForExistence(timeout: 30),
            "the scanned code never signed in"
        )
    }

    /// Some other QR code is refused by name, and nothing is offered to connect to.
    func testAScanThatIsNotASetupCodeIsRefused() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            LaunchArguments.scriptedBackend,
            LaunchArguments.unreadableSetupCode
        ]
        app.launch()

        let scan = element(in: app, .setupScan)
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "the scan control is missing")
        scan.tap()

        XCTAssertTrue(
            message(in: app, containing: "not a Phleet setup code").waitForExistence(timeout: 10),
            "an unreadable code was not refused"
        )
        XCTAssertFalse(element(in: app, .setupConnect).exists)
    }

    /// A code from a dashboard that predates one sign-in carried the operator token. It is
    /// refused by name, with where to make a new one.
    func testACodeFromAnOlderDashboardIsRefusedByName() throws {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArguments.scriptedBackend, LaunchArguments.olderSetupCode]
        app.launch()

        let scan = element(in: app, .setupScan)
        XCTAssertTrue(scan.waitForExistence(timeout: 30), "the scan control is missing")
        scan.tap()

        XCTAssertTrue(
            message(in: app, containing: "older dashboard").waitForExistence(timeout: 10),
            "a code from an older dashboard was not named as one"
        )
        XCTAssertFalse(element(in: app, .setupConnect).exists)
    }

    /// Signing out takes two taps and returns the phone to the one setup step.
    func testSigningOutReturnsToSetup() throws {
        let app = SignIn.launch()

        element(in: app, .fleetConnection).tap()
        let signOut = element(in: app, .connectionSignOut)
        XCTAssertTrue(signOut.waitForExistence(timeout: 30), "signing out is not offered")
        signOut.tap()

        let confirm = element(in: app, .connectionSignOutConfirm)
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "signing out did not ask to confirm")
        confirm.tap()

        XCTAssertTrue(
            element(in: app, .setupScan).waitForExistence(timeout: 30),
            "signing out did not return to setup"
        )
        XCTAssertFalse(app.tabBars.buttons[AppTabs.fleetLabel].exists, "the tabs outlived the sign-in")
    }

    private func message(in app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.setupMessage.identifier)
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
