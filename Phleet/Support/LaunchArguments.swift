import Foundation

/// Launch arguments the app understands.
///
/// Dependency-free and compiled into the UI-test target as well, so a renamed argument breaks
/// the test at compile time instead of leaving it launching an app that quietly ignores it.
enum LaunchArguments {

    /// Selects the in-app scripted backend, so the UI smoke test can drive
    /// enroll → thread → send → terminal with no network.
    ///
    /// A launch argument rather than a build gate: this codebase has exactly one `#if DEBUG`,
    /// `make lint` fails on a second, and a UI test runs against the app as built.
    static let scriptedBackend = "-phleet-scripted-backend"
}
