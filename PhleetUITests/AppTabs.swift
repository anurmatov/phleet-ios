import XCTest

/// The two tabs, as a test reaches them.
///
/// Found by label first, because that is what a person and VoiceOver go by, and by position
/// second: how a tab bar exposes its items has changed between releases, and a miss on the
/// element query would read as "the tab is gone" when it is not.
enum AppTabs {

    static let fleetLabel = "Fleet"
    static let chatLabel = "Chat"

    /// Fleet is the first tab and Chat the second.
    static func select(
        _ label: String,
        position: Int,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let byLabel = app.tabBars.buttons[label]
        if byLabel.waitForExistence(timeout: 30) {
            byLabel.tap()
            return
        }

        let byPosition = app.tabBars.buttons.element(boundBy: position)
        if byPosition.exists {
            byPosition.tap()
            return
        }

        let anywhere = app.buttons[label].firstMatch
        XCTAssertTrue(anywhere.exists, "the \(label) tab is missing", file: file, line: line)
        anywhere.tap()
    }

    static func selectChat(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        select(chatLabel, position: 1, in: app, file: file, line: line)
    }

    static func selectFleet(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        select(fleetLabel, position: 0, in: app, file: file, line: line)
    }
}
