import Foundation

/// Launch arguments the app understands.
///
/// Dependency-free and compiled into the UI-test target as well, so a renamed argument breaks
/// the test at compile time instead of leaving it launching an app that quietly ignores it.
enum LaunchArguments {

    /// Selects the in-app scripted backend, so the UI smoke tests can drive
    /// scan → sign in → fleet and thread → send → terminal with no network.
    ///
    /// A launch argument rather than a build gate: this codebase has exactly one `#if DEBUG`,
    /// `make lint` fails on a second, and a UI test runs against the app as built.
    static let scriptedBackend = "-phleet-scripted-backend"

    /// Exact-request journeys through the production gate view, still using synthetic data.
    static let humanInputChoice = "-phleet-human-input-choice"
    static let humanInputText = "-phleet-human-input-text"
    static let humanInputPreset = "-phleet-human-input-preset"
    static let humanInputUnavailable = "-phleet-human-input-unavailable"

    /// Makes the scripted backend seed catch-up with a thread taller than any viewport.
    ///
    /// Seeded on *open* rather than in the reply to the first send, because that is the only
    /// state in which open-at-newest can be observed at all. It also gives the scroll-dismiss
    /// test something to scroll: against a thread that never scrolls, that assertion would pass
    /// without exercising anything.
    static let tallTranscript = "-phleet-tall-transcript"

    /// Makes the scripted backend answer catch-up with history as a fresh install reads it from a
    /// server that keeps the person's words: their messages and the replies, one whose text is
    /// older than the server retains, one sent empty, and the separator for what was pruned.
    static let restoredHistory = "-phleet-restored-history"

    /// Makes the scripted backend's stand-in for the camera "scan" a code that is not a setup
    /// code, so the smoke test can watch the form refuse it. Without this argument the stand-in
    /// scans a valid one.
    static let unreadableSetupCode = "-phleet-unreadable-setup-code"

    /// Makes the stand-in for the camera "scan" a setup code from a dashboard that predates one
    /// sign-in, so the smoke test can watch it refused by name.
    static let olderSetupCode = "-phleet-older-setup-code"
}
