import XCTest

/// Signing in, as every journey after setup begins.
///
/// The scripted backend's stand-in for the camera "scans" a valid setup code, so nothing here
/// types: a journey that merely needs to be signed in should not depend on the keyboard.
enum SignIn {

    /// Launches with the scripted backend, scans, connects, and waits for the fleet.
    static func launch(
        extraArguments: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [LaunchArguments.scriptedBackend] + extraArguments
        app.launch()

        let scan = element(in: app, .setupScan)
        XCTAssertTrue(
            scan.waitForExistence(timeout: 30),
            "the setup screen never appeared",
            file: file,
            line: line
        )
        scan.tap()

        let connect = element(in: app, .setupConnect)
        XCTAssertTrue(
            connect.waitForExistence(timeout: 10),
            "the setup code was not read",
            file: file,
            line: line
        )
        connect.tap()

        XCTAssertTrue(
            element(in: app, .fleetAgent).waitForExistence(timeout: 30),
            "the fleet never appeared after signing in",
            file: file,
            line: line
        )
        return app
    }

    /// Queried across every element type on purpose: the assertion is about the accessibility
    /// contract, not about which control SwiftUI happened to render.
    static func element(
        in app: XCUIApplication,
        _ identifier: AccessibilityIdentifier
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier.identifier)
            .firstMatch
    }
}
