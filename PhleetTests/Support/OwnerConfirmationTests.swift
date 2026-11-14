import XCTest
@testable import Phleet

/// A stand-in for Face ID: answers what a test tells it to, and counts how often it was asked.
final class FakeOwnerCheck: OwnerCheck {
    var canEvaluate = true
    var answer = true
    private(set) var reasons: [String] = []

    func evaluate(reason: String) async -> Bool {
        reasons.append(reason)
        return answer
    }
}

/// The optional second look before something that cannot be undone from the phone.
@MainActor
final class OwnerConfirmationTests: XCTestCase {

    func testItIsOffUntilTurnedOnAndThenAsksNobody() async {
        let check = FakeOwnerCheck()
        let model = OwnerConfirmation(check: check, preferences: InMemoryPreferenceStore())

        let allowed = await model.confirm(reason: "a decision")

        XCTAssertFalse(model.isRequired)
        XCTAssertTrue(allowed)
        XCTAssertTrue(check.reasons.isEmpty, "with the switch off the phone is not asked")
    }

    func testWhenOnAnActionGoesAheadOnlyIfTheOwnerConfirms() async {
        let check = FakeOwnerCheck()
        let model = OwnerConfirmation(check: check, preferences: InMemoryPreferenceStore())
        await model.setRequired(true, reason: "the setting")

        check.answer = false
        let refused = await model.confirm(reason: "a decision")
        check.answer = true
        let allowed = await model.confirm(reason: "a decision")

        XCTAssertFalse(refused)
        XCTAssertTrue(allowed)
        XCTAssertEqual(check.reasons, ["the setting", "a decision", "a decision"])
    }

    func testTurningItOffTakesTheSameCheckItGuardsWith() async {
        let check = FakeOwnerCheck()
        let model = OwnerConfirmation(check: check, preferences: InMemoryPreferenceStore())
        await model.setRequired(true, reason: "the setting")

        // Whoever picked up the unlocked phone declines, or is not the owner.
        check.answer = false
        let changed = await model.setRequired(false, reason: "the setting")

        XCTAssertFalse(changed)
        XCTAssertTrue(model.isRequired, "a switch anyone could turn off would guard nothing")
    }

    func testTheSwitchIsRememberedAcrossLaunches() async {
        let preferences = InMemoryPreferenceStore()
        let first = OwnerConfirmation(check: FakeOwnerCheck(), preferences: preferences)
        await first.setRequired(true, reason: "the setting")

        let second = OwnerConfirmation(check: FakeOwnerCheck(), preferences: preferences)

        XCTAssertTrue(second.isRequired)
    }

    func testAPhoneWithNoPasscodeIsNotOfferedTheSwitch() {
        let check = FakeOwnerCheck()
        check.canEvaluate = false
        let model = OwnerConfirmation(check: check, preferences: InMemoryPreferenceStore())

        XCTAssertFalse(model.isAvailable)
    }

    func testTheUserDefaultsStoreRoundTripsWhatItIsGiven() throws {
        let suite = "phleet.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPreferenceStore(defaults: defaults)

        XCTAssertFalse(store.bool(forKey: "switch"))
        XCTAssertTrue(store.integers(forKey: "positions").isEmpty)

        store.setBool(true, forKey: "switch")
        store.setIntegers(["builder": 41], forKey: "positions")

        XCTAssertTrue(store.bool(forKey: "switch"))
        XCTAssertEqual(store.integers(forKey: "positions"), ["builder": 41])

        store.remove(forKey: "positions")
        XCTAssertTrue(store.integers(forKey: "positions").isEmpty)
    }
}
