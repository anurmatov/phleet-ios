import XCTest
@testable import Phleet

/// One rule, shared by `externalRef`, `submissionId`, `idempotencyKey` and `clientInstanceId`.
/// Four local copies would be four places for it to drift, so there is one and these are its
/// edges.
final class ClientIdentifierTests: XCTestCase {

    func testAcceptsTheAllowedCharacterSet() {
        XCTAssertTrue(ClientIdentifier.isValid("abcXYZ019_-"))
        XCTAssertTrue(ClientIdentifier.isValid("main"))
    }

    func testRejectsCharactersOutsideTheSet() {
        for candidate in ["has space", "dot.separated", "slash/es", "plus+", "emoji-🙂", "%20"] {
            XCTAssertFalse(ClientIdentifier.isValid(candidate), "\(candidate) should be refused")
        }
    }

    func testLengthBoundaries() {
        XCTAssertFalse(ClientIdentifier.isValid(""), "zero length is refused")
        XCTAssertTrue(ClientIdentifier.isValid("a"))
        XCTAssertTrue(ClientIdentifier.isValid(String(repeating: "a", count: 128)))
        XCTAssertFalse(ClientIdentifier.isValid(String(repeating: "a", count: 129)))
    }

    func testComparisonIsCaseSensitive() {
        // Ordinal, like the server's. Two identifiers differing only in case are two
        // identifiers.
        XCTAssertTrue(ClientIdentifier.isValid("Main"))
        XCTAssertNotEqual("Main", "main")
    }

    func testGeneratedIdentifiersSatisfyTheRule() {
        for _ in 0..<64 {
            let generated = ClientIdentifier.random()
            XCTAssertTrue(
                ClientIdentifier.isValid(generated),
                "\(generated) does not satisfy the identifier rule"
            )
        }
    }

    func testTheFixedExternalRefSatisfiesTheRule() {
        XCTAssertTrue(ClientIdentifier.isValid(ConversationModel.externalRef))
    }

    func testMaximumLengthMatchesTheSessionDefault() {
        // The client generates against the constant; the server reports the limit. They are
        // asserted equal rather than one silently winning.
        XCTAssertEqual(
            ClientIdentifier.maximumLength,
            SessionLimits.documentedDefaults.identifierMaxLength
        )
    }
}
