import XCTest

/// One smoke test: the app launches, a fresh install has nothing configured, and the one setup
/// step says what it needs. `AccessibilityIdentifier` is compiled into this target too, so a
/// renamed case breaks the build here rather than silently querying a stale string.
final class LaunchSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAFreshInstallOpensOnTheOneSetupStep() throws {
        let app = XCUIApplication()
        app.launch()

        let title = element(in: app, AccessibilityIdentifier.rootTitle)
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the root title never appeared")
        XCTAssertEqual(title.label, "Phleet")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Launch"
        // The default lifetime is .deletedWhenTestCompletes, which discards the attachment on
        // exactly the passing run this is meant to be evidence of.
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // A fresh install has no sign-in, so it is the setup screen: one action, scanning.
        let scan = element(in: app, AccessibilityIdentifier.setupScan)
        XCTAssertTrue(scan.exists, "the scan control is missing")
        XCTAssertTrue(scan.isHittable, "the scan control is not reachable by touch")

        // Connecting needs a code, and the tabs need a sign-in: neither is offered yet.
        XCTAssertFalse(element(in: app, AccessibilityIdentifier.setupConnect).exists)
        XCTAssertFalse(
            app.tabBars.buttons[AppTabs.fleetLabel].exists,
            "a tab was offered before the phone was signed in"
        )
    }

    /// Queried across every element type on purpose: the assertion is about the accessibility
    /// contract, not about which control SwiftUI happened to render.
    private func element(
        in app: XCUIApplication,
        _ identifier: AccessibilityIdentifier
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier.identifier)
            .firstMatch
    }
}
