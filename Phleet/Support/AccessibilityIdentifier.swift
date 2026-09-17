import Foundation

/// Every element the interface exposes to assistive technology and to UI tests.
///
/// The identifier is the stable hook UI tests query; the label is what a person hears. The
/// mapping between them is a fixed convention — `labelKey` is `"a11y." + rawValue` — so there
/// is nothing for a caller to invent and nothing for a view and a test to disagree about.
enum AccessibilityIdentifier: String, CaseIterable {
    case rootTitle = "root.title"
    case rootPurpose = "root.purpose"
    case rootConnectFleet = "root.connectFleet"
    case enrollmentPlaceholderBody = "enrollment.placeholder.body"
    case enrollmentPlaceholderDismiss = "enrollment.placeholder.dismiss"

    /// The UI-test hook. Applied with `.accessibilityIdentifier(_:)`.
    var identifier: String { rawValue }

    /// The catalog key holding this element's spoken label.
    var labelKey: String { "a11y." + rawValue }

    /// The spoken label, resolved from the app bundle's string catalog.
    ///
    /// The single resolution path shared by views and tests. Views must apply this value, not
    /// `Text(labelKey)` — `Text(_: String)` is the verbatim initializer and would speak the raw
    /// key. Because the test asserts on this same property, the two cannot drift apart.
    var localizedLabel: String {
        String(localized: String.LocalizationValue(labelKey), bundle: .main)
    }
}
