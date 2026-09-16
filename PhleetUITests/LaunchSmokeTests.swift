import XCTest

/// One smoke test: the app launches, says what it is, and its single entry point opens the
/// enrollment placeholder. `AccessibilityIdentifier` is compiled into this target too, so a
/// renamed case breaks the build here rather than silently querying a stale string.
final class LaunchSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsRootAndOpensEnrollmentPlaceholder() throws {
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

        let connect = element(in: app, AccessibilityIdentifier.rootConnectFleet)
        XCTAssertTrue(connect.exists, "the enrollment entry point is missing")
        XCTAssertTrue(connect.isHittable, "the enrollment entry point is not reachable by touch")

        connect.tap()

        let placeholder = element(in: app, AccessibilityIdentifier.enrollmentPlaceholderBody)
        XCTAssertTrue(
            placeholder.waitForExistence(timeout: 10),
            "tapping the entry point did not present the enrollment placeholder"
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
