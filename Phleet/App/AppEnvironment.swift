import Foundation
import Observation

/// The composition root.
///
/// It resolves the server profile once at launch and holds the result. It is the **only**
/// reader of `ServerProfileResolution.overrideAllowedForCurrentBuild`, which is what keeps the
/// single compile-time branch out of the resolution logic itself.
///
/// No view consumes this yet — this slice renders the same unenrolled shell regardless. It is
/// injected into the SwiftUI environment so the slice that adds enrollment has somewhere to
/// read from without restructuring the app.
@Observable
final class AppEnvironment {

    /// The server this launch resolved to, or `nil` when unenrolled. Always `nil` in a release
    /// build of this slice, because nothing persists a profile and the override does not apply.
    let serverProfile: FleetServerProfile?

    init(
        store: ServerProfileStore = InMemoryServerProfileStore(),
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.serverProfile = ServerProfileResolution.resolve(
            store: store,
            launchEnvironment: launchEnvironment,
            overrideAllowed: ServerProfileResolution.overrideAllowedForCurrentBuild
        )
    }
}
