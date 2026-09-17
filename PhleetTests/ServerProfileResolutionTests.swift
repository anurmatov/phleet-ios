import XCTest
@testable import Phleet

/// `resolve` takes `overrideAllowed` as a plain value rather than reading a compile-time flag,
/// so both branches are reachable from this ordinary Debug test bundle. That is what makes the
/// rule "release builds ignore the launch-environment override" something a test can falsify.
final class ServerProfileResolutionTests: XCTestCase {

    private let overrideKey = ServerProfileResolution.overrideEnvironmentKey

    func testFreshInstallHasNoServerConfigured() {
        let resolved = ServerProfileResolution.resolve(
            store: InMemoryServerProfileStore(),
            launchEnvironment: [:],
            overrideAllowed: true
        )
        XCTAssertNil(resolved, "a fresh install must resolve no server, override allowed or not")
    }

    func testOverrideIsIgnoredWhenNotAllowed() {
        let resolved = ServerProfileResolution.resolve(
            store: InMemoryServerProfileStore(),
            launchEnvironment: [overrideKey: "https://example.invalid"],
            overrideAllowed: false
        )
        XCTAssertNil(resolved)
    }

    func testOverrideAppliesWhenAllowed() throws {
        let resolved = ServerProfileResolution.resolve(
            store: InMemoryServerProfileStore(),
            launchEnvironment: [overrideKey: "https://example.invalid"],
            overrideAllowed: true
        )
        let profile = try XCTUnwrap(resolved)
        XCTAssertEqual(profile.baseURL.host(), "example.invalid")
    }

    func testOverrideThatFailsValidationResolvesToNoProfile() {
        let resolved = ServerProfileResolution.resolve(
            store: InMemoryServerProfileStore(),
            launchEnvironment: [overrideKey: "http://example.invalid"],
            overrideAllowed: true
        )
        XCTAssertNil(resolved, "a debugging aid must not be a way past https validation")
    }

    func testOverrideIsAllowedForThisBuild() {
        // Documents that the single compile-time branch in the codebase is the only thing that
        // decides this, and that a test bundle is built with it on.
        XCTAssertTrue(ServerProfileResolution.overrideAllowedForCurrentBuild)
    }
}
