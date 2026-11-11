import XCTest

/// One smoke test: the app launches, a fresh install has nothing configured on either tab, and
/// each tab says what it needs. `AccessibilityIdentifier` is compiled into this target too, so a
/// renamed case breaks the build here rather than silently querying a stale string.
final class LaunchSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsRootAndTheEnrollmentForm() throws {
        let app = XCUIApplication()
        app.launch()

        // The app opens on the fleet. With no connection stored it asks for one: an address,
        // and one action.
        let fleetAddress = element(in: app, AccessibilityIdentifier.controlSetupAddressField)
        XCTAssertTrue(
            fleetAddress.waitForExistence(timeout: 30),
            "a fresh install did not open on the control-plane setup"
        )
        XCTAssertTrue(
            element(in: app, AccessibilityIdentifier.controlSetupConnect).exists,
            "the control-plane connect control is missing"
        )

        AppTabs.selectChat(in: app)

        let title = element(in: app, AccessibilityIdentifier.rootTitle)
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the root title never appeared")
        XCTAssertEqual(title.label, "Phleet")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Launch"
        // The default lifetime is .deletedWhenTestCompletes, which discards the attachment on
        // exactly the passing run this is meant to be evidence of.
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // A fresh install has no credential, so it resolves to the enrollment screen: two fields
        // and one action.
        let address = element(in: app, AccessibilityIdentifier.enrollmentAddressField)
        XCTAssertTrue(address.exists, "the server address field is missing")

        let code = element(in: app, AccessibilityIdentifier.enrollmentCodeField)
        XCTAssertTrue(code.exists, "the enrollment code field is missing")

        let connect = element(in: app, AccessibilityIdentifier.enrollmentConnect)
        XCTAssertTrue(connect.exists, "the connect control is missing")
        XCTAssertTrue(connect.isHittable, "the connect control is not reachable by touch")
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
