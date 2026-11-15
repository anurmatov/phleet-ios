import XCTest

/// Reading an event's complete values — end to end, against the in-app scripted orchestrator.
///
/// Scripted, so this is the app reading synthetic answers shaped as the documented contract
/// describes them. It is not a check against a real orchestrator, and passing it says nothing
/// about one.
final class EventValueSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The failed run's first event: a JSON object, laid out, then shown as stored. Its value
    /// names the run it was read from, so a screen reading another run would show another name.
    func testAJSONValueOpensAsAnOutlineOfTheRunsOwnEventAndCopiesTheOriginal() throws {
        let app = openEvent(titled: "Workflow started")

        XCTAssertFalse(
            element(in: app, .eventValueOpen).exists,
            "a complete value was read before anyone asked for it"
        )
        tapLoad(in: app)
        open(in: app)

        // An outline, collapsed: the nested object's entries wait until it is opened.
        XCTAssertTrue(element(in: app, .eventReaderMode).waitForExistence(timeout: 30))
        let topic = node(containing: "topic", in: app)
        XCTAssertTrue(topic.waitForExistence(timeout: 30), "the outline never appeared")
        XCTAssertTrue(
            node(containing: "scripted \"topic\"", in: app).exists,
            "a string reads as its text, quotes resolved"
        )
        XCTAssertTrue(node(containing: "12345678901234567890", in: app).exists, "a number lost digits")
        XCTAssertTrue(node(containing: "1.10", in: app).exists, "a number was rewritten")
        XCTAssertTrue(
            node(containing: "scripted-failed-1", in: app).exists,
            "the value is not the selected run's own"
        )
        XCTAssertFalse(node(containing: "flags", in: app).exists, "a nested object opened by itself")
        node(containing: "nested", in: app).tap()
        XCTAssertTrue(
            node(containing: "flags", in: app).waitForExistence(timeout: 10),
            "opening the nested object showed nothing"
        )
        attach(app, "Outline")

        // As stored: the system's own text, selectable.
        app.buttons["Raw"].tap()
        let text = element(in: app, .eventReaderText)
        XCTAssertTrue(text.waitForExistence(timeout: 10), "the raw text is not on screen")
        text.press(forDuration: 1.2)
        XCTAssertTrue(selectionMenuAppeared(in: app), "a long press on the value raised no selection menu")
        dismissAnyMenu(in: app)

        app.buttons["Pretty"].tap()
        XCTAssertTrue(element(in: app, .eventReaderText).waitForExistence(timeout: 10))

        let copy = element(in: app, .eventReaderCopy)
        XCTAssertTrue(copy.exists, "nothing offers to copy the value")
        copy.tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Copied")).firstMatch
                .waitForExistence(timeout: 10),
            "copying said nothing"
        )
        attach(app, "Pretty")
    }

    /// A value of 100,000 Unicode scalars arrives whole and waits to be opened.
    ///
    /// The test stops short of opening it on purpose. With that value in the system text view,
    /// every accessibility snapshot the runner takes carries all of it: on CI run 43690030109 the
    /// runner could not compute the view's activation point, and on 43693230008 a plain query
    /// timed out. Selecting and copying the whole value is proven against the same `UITextView`
    /// in `EventValueRenderingTests`, and selection in the reader by a long press is proven here
    /// on a smaller value.
    func testALargeUnicodeValueArrivesWholeAndIsNotOpenedByItself() throws {
        let app = openEvent(titled: "Activity completed")

        tapLoad(in: app, field: "Read the complete output")

        // The read returns the stored JSON literal, quotes and escapes included, so the count
        // on screen is the literal's characters, not those of the text it stands for.
        let characters = ScriptedValues.largeUnicodeLiteral.count
        let offered = app.descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.eventValueOpen.identifier)
            .matching(NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "json/plain",
                characters.formatted() + " characters"
            ))
            .firstMatch
        XCTAssertTrue(offered.waitForExistence(timeout: 30), "the large value did not arrive whole")
        XCTAssertFalse(
            element(in: app, .eventReaderText).exists,
            "a large value was opened before anyone asked"
        )
        attach(app, "Large value offered")
    }

    /// Plain text stays text, and text stored as JSON that is not valid JSON says so instead of
    /// becoming an object.
    func testPlainTextAndMalformedJSONAreShownAsStored() throws {
        let app = openEvent(titled: "Activity completed")
        tapLoad(in: app, field: "Read the complete input")
        XCTAssertTrue(
            labelled("Read from event 2", in: app).waitForExistence(timeout: 30),
            "a completed activity's input did not name the event that scheduled it"
        )
        open(in: app)
        XCTAssertTrue(
            notice(containing: "Plain text", in: app).waitForExistence(timeout: 30),
            "plain text did not say it is shown as stored"
        )
        XCTAssertFalse(element(in: app, .eventReaderMode).exists, "plain text was offered as JSON")
        XCTAssertTrue(element(in: app, .eventReaderText).exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let signal = row(titled: "Signal received", in: app)
        scrollTo(signal, in: app)
        signal.tap()
        tapLoad(in: app)
        open(in: app)
        XCTAssertTrue(
            notice(containing: "isn't valid JSON", in: app).waitForExistence(timeout: 30),
            "truncated JSON was not named as such"
        )
        XCTAssertFalse(element(in: app, .eventReaderMode).exists, "truncated JSON was laid out")
        attach(app, "Malformed JSON")
    }

    /// An orchestrator with no complete-value route: said in words, and the history stays.
    func testAnOlderServerSaysCompleteValuesAreUnavailable() throws {
        let app = openEvent(
            titled: "Workflow started",
            extraArguments: [
                LaunchArguments.eventValuesUnavailable,
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        )
        let load = element(in: app, .eventValueLoad)
        scrollTo(load, in: app)
        XCTAssertTrue(load.isHittable, "reading in full is not reachable at the largest text size")
        load.tap()

        let state = app.descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.eventValueState.identifier)
            .matching(NSPredicate(format: "label CONTAINS %@", "doesn't offer complete values"))
            .firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 30), "an older server was not named")
        XCTAssertFalse(element(in: app, .eventValueOpen).exists, "something was shown as the value")
        attach(app, "Older server")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            element(in: app, .runEvent).waitForExistence(timeout: 10),
            "the history did not survive the failed read"
        )
    }

    /// A read in flight can be stopped, and stopping leaves a way to read again.
    func testAReadCanBeStopped() throws {
        let app = openEvent(titled: "Workflow started", extraArguments: [LaunchArguments.slowEventValues])
        tapLoad(in: app)

        let stop = element(in: app, .eventValueStop)
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "a read in flight offered no stop")
        stop.tap()

        let stopped = app.descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.eventValueState.identifier)
            .matching(NSPredicate(format: "label CONTAINS %@", "Stopped"))
            .firstMatch
        XCTAssertTrue(stopped.waitForExistence(timeout: 10), "the stop was not said")
        XCTAssertTrue(element(in: app, .eventValueLoad).exists, "a stopped read cannot be read again")
    }

    // MARK: - Journey

    /// Signed in, on the failed run's screen, into one history event.
    private func openEvent(titled title: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = SignIn.launch(extraArguments: extraArguments)
        AppTabs.selectRuns(in: app)

        // Lists build their rows as they scroll into view, so at the largest text sizes an entry
        // below the fold does not exist until the list is scrolled to it.
        XCTAssertTrue(element(in: app, .runsRun).waitForExistence(timeout: 30), "no run is listed")
        let failed = labelled("scripted/project · PR #41", in: app)
        scrollTo(failed, in: app)
        XCTAssertTrue(failed.waitForExistence(timeout: 10), "the failed run is not listed")
        failed.tap()
        XCTAssertTrue(element(in: app, .runStatus).waitForExistence(timeout: 30), "the run never opened")

        let entry = row(titled: title, in: app)
        scrollTo(entry, in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "no history entry says \(title)")
        entry.tap()
        return app
    }

    private func tapLoad(in app: XCUIApplication, field: String? = nil) {
        let load: XCUIElement
        if let field {
            load = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", field)).firstMatch
        } else {
            load = element(in: app, .eventValueLoad)
        }
        XCTAssertTrue(load.waitForExistence(timeout: 30), "reading in full is not offered")
        scrollTo(load, in: app)
        load.tap()
    }

    private func open(in app: XCUIApplication) {
        let open = element(in: app, .eventValueOpen)
        XCTAssertTrue(open.waitForExistence(timeout: 30), "the complete value never arrived")
        scrollTo(open, in: app)
        open.tap()
    }

    private func row(titled title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.runEvent.identifier)
            .matching(NSPredicate(format: "label BEGINSWITH %@", title))
            .firstMatch
    }

    private func node(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.eventReaderNode.identifier)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    private func notice(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: AccessibilityIdentifier.eventReaderNotice.identifier)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    private func selectionMenuAppeared(in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        if app.menuItems["Copy"].waitForExistence(timeout: timeout) { return true }
        return app.buttons["Copy"].exists
    }

    private func dismissAnyMenu(in app: XCUIApplication) {
        app.navigationBars.firstMatch.tap()
    }

    /// Scrolls until the element is on screen. One that does not exist yet is below the fold.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !(element.exists && element.isHittable) {
            if element.exists && element.frame.minY < app.frame.midY { app.swipeDown() }
            else { app.swipeUp() }
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = name
        screen.lifetime = .keepAlways
        add(screen)
    }

    private func labelled(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
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
