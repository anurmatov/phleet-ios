import Foundation
import Observation

/// The composition root.
///
/// It resolves the server profile once at launch, holds the credential store, the API client and
/// the stream, and owns the routing decision between enrollment and the thread. It is still the
/// **only** reader of `ServerProfileResolution.overrideAllowedForCurrentBuild`, which is what
/// keeps the single compile-time branch out of the resolution logic itself.
@MainActor
@Observable
final class AppEnvironment {

    enum Route: Equatable {
        case enrollment
        case agent
    }

    /// The server this launch resolved to, or `nil` when unenrolled.
    private(set) var serverProfile: FleetServerProfile?

    private(set) var route: Route = .enrollment

    /// The credential store answered with something other than "there is no credential".
    ///
    /// Treated as unenrolled and shown as its own message, because it is not the same thing as a
    /// fresh install — and nothing on this path deletes the item.
    private(set) var credentialUnavailable = false

    /// This device's access was revoked. Cleared by a successful enrollment.
    private(set) var wasRevoked = false

    private(set) var agentSummary: AgentSummary?
    private(set) var limits: SessionLimits = .documentedDefaults
    private(set) var conversation: ConversationModel?

    /// The composer's contents, held here rather than in the conversation.
    ///
    /// Sign-out tears down the token, the transcript and the conversation — and must **not**
    /// silently discard a message the person typed. Holding the draft above all of that is what
    /// makes "it is still there after re-enrollment" structural rather than remembered.
    var composerDraft = ""

    let credentialStore: CredentialStore
    let api: FleetAPIClient
    let stream: ConversationStream

    private var tokens: AccessTokenHolder?

    init(
        credentialStore: CredentialStore? = nil,
        api: FleetAPIClient? = nil,
        stream: ConversationStream? = nil,
        launchArguments: [String] = ProcessInfo.processInfo.arguments,
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        // A launch-argument-driven double, never a build-gated one: the single `#if DEBUG` in
        // this codebase stays where it is, and `make lint` fails on a second.
        let double = LaunchDouble.make(from: launchArguments)

        self.credentialStore = credentialStore ?? double?.credentialStore
            ?? KeychainCredentialStore()
        self.api = api ?? double?.api ?? URLSessionFleetAPIClient()
        self.stream = stream ?? double?.stream ?? URLSessionConversationStream()

        self.serverProfile = ServerProfileResolution.resolve(
            store: CredentialBackedServerProfileStore(credentialStore: self.credentialStore),
            launchEnvironment: launchEnvironment,
            overrideAllowed: ServerProfileResolution.overrideAllowedForCurrentBuild
        )

        restoreEnrollment()
    }

    // MARK: - Routing

    private func restoreEnrollment() {
        do {
            guard let credential = try credentialStore.load() else {
                route = .enrollment
                return
            }
            adopt(credential)
            route = .agent
        } catch {
            credentialUnavailable = true
            route = .enrollment
        }
    }

    func makeEnrollmentModel() -> EnrollmentModel {
        EnrollmentModel(
            api: api,
            credentialStore: credentialStore,
            makeTokenHolder: { [weak self] store in
                guard let self else {
                    // Unreachable in practice — the environment outlives every screen — but a
                    // holder that cannot mint is a truthful answer, and better than a crash.
                    return AccessTokenHolder(credentialStore: store) { _ in
                        throw FleetAPIError.transport("no environment")
                    }
                }
                return self.makeTokenHolder(store)
            }
        )
    }

    /// Adopts the result of a successful enrollment.
    func finishEnrollment(_ outcome: EnrollmentOutcome) {
        limits = outcome.limits
        agentSummary = AgentSummary(
            label: outcome.agentLabel,
            principalId: outcome.principalId,
            serverDisplayName: outcome.displayName
        )
        wasRevoked = false
        credentialUnavailable = false
        adopt(outcome.credential)
        route = .agent
    }

    private func adopt(_ credential: DeviceCredential) {
        guard let origin = credential.originURL else {
            credentialUnavailable = true
            return
        }

        if let components = URLComponents(string: credential.origin) {
            serverProfile = try? FleetServerProfile(
                displayName: ServerDisplayName.derive(from: components),
                urlString: credential.origin
            )
        }
        if agentSummary == nil {
            agentSummary = AgentSummary(
                label: nil,
                principalId: nil,
                serverDisplayName: serverProfile?.displayName ?? ""
            )
        }

        let holder = makeTokenHolder(credentialStore)
        tokens = holder
        conversation = ConversationModel(
            api: api,
            stream: stream,
            tokens: holder,
            origin: origin,
            clientInstanceId: credential.clientInstanceId,
            limits: limits
        )
    }

    private func makeTokenHolder(_ store: CredentialStore) -> AccessTokenHolder {
        let api = self.api
        let holder = AccessTokenHolder(credentialStore: store) { credential in
            guard let origin = credential.originURL else {
                throw FleetAPIError.transport("malformed stored origin")
            }
            return try await api.mintToken(
                origin: origin,
                deviceId: credential.deviceId,
                deviceSecret: credential.deviceSecret
            )
        }
        holder.onDeviceRevoked = { [weak self] in
            self?.handleDeviceRevoked()
        }
        return holder
    }

    /// The sign-out path.
    ///
    /// The credential has **already** been deleted, by the one place allowed to delete it: the
    /// token mint answering `401`. Nothing here deletes anything, which is what keeps "exactly
    /// one path removes the credential" true.
    ///
    /// `composerDraft` is deliberately untouched.
    private func handleDeviceRevoked() {
        tokens = nil
        conversation = nil
        agentSummary = nil
        serverProfile = nil
        wasRevoked = true
        route = .enrollment
    }
}
