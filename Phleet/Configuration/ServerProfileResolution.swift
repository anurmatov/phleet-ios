import Foundation

/// Decides which server profile the app should use at launch, if any.
enum ServerProfileResolution {

    /// Launch-environment key carrying a debug-build server override.
    static let overrideEnvironmentKey = "PHLEET_SERVER_URL"

    /// Display name given to a profile that came from the launch environment.
    static let overrideDisplayName = "Launch environment override"

    /// Resolves the profile to use, in precedence order:
    ///
    /// 1. whatever `store` holds — always `nil` in this slice, since nothing persists a profile
    /// 2. the launch-environment override, **only** when `overrideAllowed` is `true`
    /// 3. otherwise `nil`, and the app renders its unenrolled state
    ///
    /// This is a pure function and takes `overrideAllowed` as a plain value rather than reading
    /// a compile-time flag. That is the whole point: both branches are reachable from an
    /// ordinary Debug test bundle, so the rule that release builds ignore the override is
    /// something a test can actually falsify.
    static func resolve(
        store: ServerProfileStore,
        launchEnvironment: [String: String],
        overrideAllowed: Bool
    ) -> FleetServerProfile? {
        if let stored = store.currentProfile {
            return stored
        }

        guard overrideAllowed, let urlString = launchEnvironment[overrideEnvironmentKey] else {
            return nil
        }

        // An override that fails validation is treated as absent. A debugging aid must not be
        // able to trap the app, and must not be a way to smuggle a non-https destination past
        // the same checks a user-supplied address goes through.
        return try? FleetServerProfile(displayName: overrideDisplayName, urlString: urlString)
    }

    /// Whether the launch-environment override applies to the build currently running.
    ///
    /// The only configuration-dependent branch in the codebase. `AppEnvironment` is its only
    /// reader, and the lint step fails the build if a second one appears anywhere under
    /// `Phleet/`.
    static var overrideAllowedForCurrentBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
