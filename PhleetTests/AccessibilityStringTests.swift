import XCTest
@testable import Phleet

/// A missing catalog entry does not throw — the lookup returns the key verbatim, which is
/// non-empty. So "resolves to a non-empty string" alone would pass whether or not the catalog
/// shipped. The inequality assertion is the one that can actually go red.
final class AccessibilityStringTests: XCTestCase {

    func testTestBundleIsAppHosted() {
        // Load-bearing. In a non-hosted logic bundle `.main` is the xctest runner, the app's
        // string catalog is not in it, every lookup below returns its own key, and the whole
        // suite passes vacuously.
        XCTAssertEqual(
            Bundle.main.bundleIdentifier,
            "com.anvarlab.phleet",
            "PhleetTests must run hosted by the app; see TEST_HOST in project.yml"
        )
    }

    func testEveryIdentifierHasALabelInTheCatalog() {
        for identifier in AccessibilityIdentifier.allCases {
            let label = identifier.localizedLabel

            XCTAssertFalse(
                label.isEmpty,
                "\(identifier.labelKey) resolved to an empty label"
            )
            XCTAssertNotEqual(
                label,
                identifier.labelKey,
                "\(identifier.labelKey) is missing from Localizable.xcstrings: the lookup "
                    + "returned the key itself"
            )
        }
    }

    func testRootTitleLabelIsTheProductName() {
        // Pinned so this and the launch smoke test assert against one value.
        XCTAssertEqual(AccessibilityIdentifier.rootTitle.localizedLabel, "Phleet")
    }

    func testIdentifierAndLabelKeyConventionHolds() {
        for identifier in AccessibilityIdentifier.allCases {
            XCTAssertEqual(identifier.identifier, identifier.rawValue)
            XCTAssertEqual(identifier.labelKey, "a11y." + identifier.rawValue)
        }
    }
}
