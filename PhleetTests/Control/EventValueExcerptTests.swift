import XCTest
@testable import Phleet

/// The beginning of a complete value, as the event's own screen shows it before the reader is
/// opened: the most readable form the value has, and never more than a bounded piece of it.
final class EventValueExcerptTests: XCTestCase {

    private func excerpt(_ encoding: String, _ text: String, read: Bool = true) -> EventValueExcerpt {
        let value = EventPayloadText(encoding: encoding, text: text)
        return EventValueExcerpt(value, reading: read && value.isJSONEncoded ? JSONReading.read(text) : nil)
    }

    func testAnObjectShowsItsIndentedText() {
        let shown = excerpt("json/plain", #"{"name":"synthetic","steps":[1,2]}"#)
        XCTAssertTrue(shown.isCode)
        XCTAssertTrue(shown.text.hasPrefix("{\n"), "the object was not laid out: \(shown.text)")
        XCTAssertTrue(shown.text.contains(#""name": "synthetic""#))
    }

    func testAJSONStringShowsTheTextItStandsFor() {
        let shown = excerpt("json/plain", #""line one\nline \"two\"""#)
        XCTAssertFalse(shown.isCode)
        XCTAssertEqual(shown.text, "line one\nline \"two\"")
    }

    func testANumberAndALiteralShowAsStored() {
        XCTAssertEqual(excerpt("json/plain", "12345678901234567890").text, "12345678901234567890")
        XCTAssertEqual(excerpt("json/plain", "1.10").text, "1.10")
        XCTAssertEqual(excerpt("json/plain", "null").text, "null")
        XCTAssertTrue(excerpt("json/plain", "true").isCode)
    }

    func testJSONThatDoesNotParseShowsWhatIsStoredAndNothingLaidOut() {
        let stored = #"{"Decision":"approved""#
        let shown = excerpt("json/plain", stored)
        XCTAssertEqual(shown.text, stored)
        XCTAssertTrue(shown.isCode)
    }

    func testTextThatLooksLikeJSONButIsStoredAsTextIsNotLaidOut() {
        let stored = #"{"a":1}"#
        let value = EventPayloadText(encoding: "text/plain", text: stored)
        // Even handed a reading, a value that is not JSON-encoded is shown as its text.
        let shown = EventValueExcerpt(value, reading: JSONReading.read(stored))
        XCTAssertEqual(shown.text, stored)
        XCTAssertFalse(shown.isCode)
    }

    func testBeforeTheJSONIsReadTheStoredTextStandsIn() {
        let shown = excerpt("json/plain", #"{"a":1}"#, read: false)
        XCTAssertEqual(shown.text, #"{"a":1}"#)
        XCTAssertTrue(shown.isCode)
    }

    func testALongValueIsCutAndSaysSo() {
        let limit = EventValueExcerpt.maximumCharacters
        let long = String(repeating: "é", count: limit + 1)
        let shown = excerpt("text/plain", long)
        XCTAssertEqual(shown.text.count, limit + 1)
        XCTAssertTrue(shown.text.hasSuffix("…"))
        XCTAssertEqual(String(shown.text.dropLast()), String(repeating: "é", count: limit))

        let exact = String(repeating: "é", count: limit)
        XCTAssertEqual(excerpt("text/plain", exact).text, exact, "a value that fits was marked as cut")
        XCTAssertEqual(excerpt("text/plain", "short").text, "short")
    }

    func testALargeJSONStringIsCutFromItsTextNotItsLiteral() {
        let text = String(repeating: "a\n\"", count: 50_000)
        let literal = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        let shown = excerpt("json/plain", literal)
        XCTAssertFalse(shown.isCode)
        XCTAssertEqual(shown.text.count, EventValueExcerpt.maximumCharacters + 1)
        XCTAssertTrue(shown.text.hasPrefix("a\n\"a\n\""), "the escapes were not resolved: \(shown.text.prefix(12))")
    }

    func testTooManyEntriesForAnOutlineStillShowTheIndentedText() {
        let many = "[" + Array(repeating: "0", count: JSONReading.maximumNodes + 1).joined(separator: ",") + "]"
        let shown = excerpt("json/plain", many)
        XCTAssertTrue(shown.isCode)
        XCTAssertTrue(shown.text.hasPrefix("[\n"), "the list was not laid out")
        XCTAssertEqual(shown.text.count, EventValueExcerpt.maximumCharacters + 1)
    }
}
