import XCTest
@testable import Phleet

/// Every address that reaches `FleetServerProfile` is user input, so every rejection has to be
/// an ordinary reported outcome rather than a trap.
final class FleetServerProfileTests: XCTestCase {

    func testAcceptsHTTPSAddressWithAHost() throws {
        let profile = try FleetServerProfile(displayName: "Home", urlString: "https://example.invalid")
        XCTAssertEqual(profile.displayName, "Home")
        XCTAssertEqual(profile.baseURL.host(), "example.invalid")
    }

    func testRejectsInsecureScheme() {
        assertRejects("http://example.invalid", with: .insecureScheme)
    }

    func testRejectsAddressWithNoHost() {
        // Parses, carries the right scheme, and names no server.
        assertRejects("https:", with: .missingHost)
    }

    func testRejectsEmbeddedUserInfo() {
        assertRejects("https://user:pw@example.invalid", with: .userInfoPresent)
    }

    func testRejectsEmptyDisplayName() {
        XCTAssertThrowsError(
            try FleetServerProfile(displayName: "   ", urlString: "https://example.invalid")
        ) { error in
            XCTAssertEqual(error as? FleetServerProfileError, .emptyDisplayName)
        }
    }

    func testTrimsDisplayName() throws {
        let profile = try FleetServerProfile(displayName: "  Home  ", urlString: "https://example.invalid")
        XCTAssertEqual(profile.displayName, "Home")
    }

    private func assertRejects(
        _ urlString: String,
        with expected: FleetServerProfileError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try FleetServerProfile(displayName: "Home", urlString: urlString),
            "expected \(urlString) to be rejected",
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? FleetServerProfileError, expected, file: file, line: line)
        }
    }
}
