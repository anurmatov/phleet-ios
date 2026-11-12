import XCTest

extension XCUIElement {

    /// Taps a field and types into it, but only once the field really has keyboard focus.
    ///
    /// `tap()` followed straight away by `typeText(_:)` fails on a slow runner with "Neither
    /// element nor any descendant has keyboard focus": the tap was delivered, the focus had not
    /// moved yet, and the keystrokes had nowhere to go. That is the test racing the simulator,
    /// not a defect in the form, so this waits for the focus it asked for and asks again if it
    /// does not arrive.
    func focusAndType(
        _ text: String,
        attempts: Int = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<attempts {
            tap()
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasKeyboardFocus == true"),
                object: self
            )
            if XCTWaiter().wait(for: [focused], timeout: 5) == .completed {
                typeText(text)
                return
            }
        }
        XCTFail("the field never took keyboard focus", file: file, line: line)
    }
}
