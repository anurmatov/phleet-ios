import XCTest
@testable import Phleet

/// The one rule worth pinning about copy: an action is offered only when there is something to
/// put on the pasteboard, and what it puts there is verbatim.
final class TranscriptCopyTests: XCTestCase {

    func testTextIsCopiedVerbatim() {
        XCTAssertEqual(TranscriptCopy.copyable("hello"), "hello")
    }

    func testInternalAndEdgeWhitespaceSurvives() {
        // Whitespace decides whether the action appears; it is not edited out of the person's
        // own message. A trimmed copy would silently differ from what they can select by hand.
        XCTAssertEqual(TranscriptCopy.copyable("  indented\n\nblank line  "),
                       "  indented\n\nblank line  ")
    }

    func testNothingToCopyOffersNoAction() {
        // `completion: "idle"` legitimately carries empty reply text. An action that writes an
        // empty string is a control that silently does nothing.
        XCTAssertNil(TranscriptCopy.copyable(nil))
        XCTAssertNil(TranscriptCopy.copyable(""))
        XCTAssertNil(TranscriptCopy.copyable("   \n\t  "))
    }
}
