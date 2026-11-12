import Foundation
import Observation

/// The composition root.
///
/// It holds the one credential this phone signs in with and builds everything that uses it: the
/// Fleet and Runs models over the orchestrator's routes, notifications, and Chat over the chat
/// service's. All of them reach the server through one address, with one access token, minted
/// from that credential when it is needed. It is still the **only** reader of
/// `ServerProfileResolution.overrideAllowedForCurrentBuild`, which is what keeps the single
/// compile-time branch out of the resolution logic itself.
@MainActor
@Observable
final class AppEnvironment {

    /// Why the phone is signed out, when there is more to say than "not set up yet".
    enum SignedOutNotice: Equatable, Sendable {
        /// The orchestrator refused this phone's credential: it was revoked from the dashboard.
        case revoked
        /// The stored sign-in could not be read, or could not be removed. Nothing on this path
        /// deletes it: a read that failed because the phone is locked must not destroy it.
        case credentialUnavailable
        /// Signed out on this phone, but the server could not be told. The phone stays on the
        /// dashboard's device list until it is revoked there.
        case serverNotTold
    }

    /// The server this launch resolved to, or `nil` when signed out.
    private(set) var serverProfile: FleetServerProfile?

    /// The sign-in, or `nil` when this phone is not signed in.
    private(set) var credential: DeviceCredential?

    private(set) var signedOutNotice: SignedOutNotice?

    /// Signing out is under way: the server is being told before the credential goes.
    private(set) var isSigningOut = false

    var isSignedIn: Bool { credential != nil }

    // MARK: - What the sign-in builds

    /// Agents, runs in progress, gates. Exists exactly when the sign-in does.
    private(set) var controlPlane: ControlPlaneModel?

    /// Closed runs, run history, cancelling and starting. Built and torn down with `controlPlane`.
    private(set) var runs: RunsModel?

    /// Notifications for this sign-in. Built and torn down with `controlPlane`.
    private(set) var pushNotifications: PushNotificationsModel?

    /// Who can be chatted with, and a thread with each. Built and torn down with `controlPlane`.
    private(set) var chat: ChatModel?

    /// Where a tapped notification asked to land. The root view takes it and clears it.
    var requestedDestination: PushDestination?

    /// What the person has typed to each agent and not yet sent, by agent name.
    ///
    /// Held here, above everything sign-out tears down, so signing out cannot silently discard a
    /// message someone typed — and one per agent, so a message typed to one agent is never sitting
    /// in another agent's composer.
    private var drafts: [String: String] = [:]

    // MARK: - Dependencies

    let credentialStore: CredentialStore
    let legacyCredentialStore: LegacyCredentialStore
    let controlAPI: ControlAPIClient
    let controlStream: ControlLiveStream
    let controlLogStream: AgentLogStream
    let pushSystem: PushSystem

    /// Set only under the scripted backend, where it stands in for the camera. `nil` in a real
    /// launch, where the scan button opens the scanner.
    let scriptedSetupCode: String?

    /// Chat doubles, when a test or the scripted backend supplies them. Otherwise the real ones
    /// are built at sign-in, for the address and service token the credential names.
    private let injectedChatAPI: FleetAPIClient?
    private let injectedChatStream: ConversationStream?

    private var signedInAPI: SignedInControlAPI?
    private var signedInLogStream: AgentLogStream?

    /// What an earlier build's Fleet connection said about notifications, kept for this launch
    /// so the first sign-in to the same address carries it over. See `LegacyCredentialStore`.
    private var legacyWish: LegacyNotificationWish?

    init(
        credentialStore: CredentialStore? = nil,
        legacyCredentialStore: LegacyCredentialStore? = nil,
        api: FleetAPIClient? = nil,
        stream: ConversationStream? = nil,
        controlAPI: ControlAPIClient? = nil,
        controlStream: ControlLiveStream? = nil,
        controlLogStream: AgentLogStream? = nil,
        pushSystem: PushSystem? = nil,
        launchArguments: [String] = ProcessInfo.processInfo.arguments,
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        // A launch-argument-driven double, never a build-gated one: the single `#if DEBUG` in
        // this codebase stays where it is, and `make lint` fails on a second.
        let double = LaunchDouble.make(from: launchArguments)

        self.credentialStore = credentialStore ?? double?.credentialStore
            ?? KeychainCredentialStore()
        self.legacyCredentialStore = legacyCredentialStore ?? double?.legacyCredentialStore
            ?? KeychainLegacyCredentialStore()
        self.injectedChatAPI = api ?? double?.api
        self.injectedChatStream = stream ?? double?.stream

        self.scriptedSetupCode = double?.scannedSetupCode
        self.pushSystem = pushSystem ?? double?.pushSystem ?? SystemPushSystem.shared
        if let controlAPI = controlAPI ?? double?.controlAPI,
           let controlStream = controlStream ?? double?.controlStream,
           let controlLogStream = controlLogStream ?? double?.controlLogStream {
            self.controlAPI = controlAPI
            self.controlStream = controlStream
            self.controlLogStream = controlLogStream
        } else {
            // One session for the three, so a request and the sockets share the same rules: no
            // redirects followed, no cookies kept, nothing cached.
            let session = ControlTransport.makeSession()
            self.controlAPI = controlAPI ?? URLSessionControlAPIClient(session: session)
            self.controlStream = controlStream ?? URLSessionControlLiveStream(session: session)
            self.controlLogStream = controlLogStream ?? URLSessionAgentLogStream(session: session)
        }

        self.serverProfile = ServerProfileResolution.resolve(
            store: CredentialBackedServerProfileStore(credentialStore: self.credentialStore),
            launchEnvironment: launchEnvironment,
            overrideAllowed: ServerProfileResolution.overrideAllowedForCurrentBuild
        )

        // Set before anything is restored: restoring a sign-in with notifications on asks Apple
        // for the token again, and the answer has to have somewhere to go.
        self.pushSystem.onDeviceToken = { [weak self] token in
            Task { await self?.pushNotifications?.handleDeviceToken(token) }
        }
        self.pushSystem.onRegistrationFailed = { [weak self] in
            self?.pushNotifications?.handleRegistrationFailed()
        }
        self.pushSystem.onOpened = { [weak self] destination in
            self?.requestedDestination = destination
        }

        restore()
    }

    // MARK: - Signing in

    private func restore() {
        // First, whatever an earlier build left behind: its operator token must not outlive it.
        legacyWish = legacyCredentialStore.takeNotificationWish()

        let stored: DeviceCredential?
        do {
            stored = try credentialStore.load()
        } catch {
            signedOutNotice = .credentialUnavailable
            return
        }
        if let stored {
            adopt(stored, tokens: makeTokenHolder(credentialStore))
        }
    }

    func makeSetupModel(deviceName: String?) -> SetupModel {
        SetupModel(
            api: controlAPI,
            credentialStore: credentialStore,
            deviceName: deviceName,
            makeTokenHolder: { [weak self] store in
                guard let self else {
                    // Unreachable in practice — the environment outlives every screen — but a
                    // holder that cannot mint is a truthful answer, and better than a crash.
                    return AccessTokenHolder(credentialStore: store) { _ in
                        throw ControlAPIError.transport("no environment")
                    }
                }
                return self.makeTokenHolder(store)
            }
        )
    }

    /// Adopts a sign-in that setup has already stored.
    func finishSetup(_ outcome: SetupOutcome) {
        var credential = outcome.credential
        if credential.pushDeviceId == nil,
           let wish = legacyWish,
           Self.sameOrigin(wish.origin, credential.origin) {
            // Notifications were on for this server under the earlier build, and the
            // orchestrator knows this phone by that identifier. Keeping it means turning them
            // back on replaces that row instead of adding a second one beside it.
            credential = credential.withPushDeviceId(wish.pushDeviceId)
            try? credentialStore.save(credential)
        }
        legacyWish = nil
        signedOutNotice = nil
        adopt(credential, tokens: outcome.tokens)
    }

    private func adopt(_ credential: DeviceCredential, tokens: AccessTokenHolder) {
        guard let connection = credential.connection, let origin = credential.originURL else {
            signedOutNotice = .credentialUnavailable
            return
        }
        controlPlane?.stop()

        tokens.onDeviceRevoked = { [weak self] in
            self?.handleDeviceRevoked()
        }
        self.credential = credential
        serverProfile = try? FleetServerProfile(
            displayName: ServerDisplayName.derive(fromOrigin: credential.origin),
            urlString: credential.origin
        )

        let api = SignedInControlAPI(base: controlAPI, tokens: tokens)
        signedInAPI = api
        controlPlane = ControlPlaneModel(
            api: api,
            stream: SignedInControlLiveStream(base: controlStream, tokens: tokens),
            connection: connection
        )
        runs = RunsModel(api: api, connection: connection)
        signedInLogStream = SignedInAgentLogStream(base: controlLogStream, tokens: tokens)

        let chatAPI: FleetAPIClient
        let chatStream: ConversationStream
        if let injectedChatAPI, let injectedChatStream {
            chatAPI = injectedChatAPI
            chatStream = injectedChatStream
        } else {
            // The chat service is behind the same address and the same proxy, on a session with
            // the same rules and a longer wait between a socket's frames.
            let session = ControlTransport.makeSession(
                requestTimeout: ControlTransport.chatRequestTimeoutSeconds
            )
            chatAPI = injectedChatAPI
                ?? URLSessionFleetAPIClient(session: session, serviceToken: credential.serviceToken)
            chatStream = injectedChatStream
                ?? URLSessionConversationStream(
                    session: session,
                    serviceToken: credential.serviceToken
                )
        }
        let clientInstanceId = credential.clientInstanceId
        chat = ChatModel(
            api: api,
            connection: connection,
            chatAPI: chatAPI,
            tokens: tokens
        ) { agent, limits in
            ConversationModel(
                api: chatAPI,
                stream: chatStream,
                tokens: tokens,
                origin: origin,
                agent: agent,
                clientInstanceId: clientInstanceId,
                limits: limits
            )
        }

        let push = PushNotificationsModel(
            api: api,
            system: pushSystem,
            connection: connection,
            deviceId: credential.pushDeviceId,
            persist: { [weak self] deviceId in
                self?.persistPushDeviceId(deviceId)
            }
        )
        pushNotifications = push
        push.resume()
    }

    private func makeTokenHolder(_ store: CredentialStore) -> AccessTokenHolder {
        let api = controlAPI
        return AccessTokenHolder(credentialStore: store) { credential in
            guard let connection = credential.connection else {
                throw ControlAPIError.transport("malformed stored origin")
            }
            return try await api.mintToken(
                connection,
                deviceId: credential.deviceId,
                deviceSecret: credential.deviceSecret
            )
        }
    }

    // MARK: - Signing out

    /// The orchestrator refused this phone's credential, and the token holder has **already**
    /// deleted it: that is the one place allowed to on this path.
    ///
    /// Notifications are stopped on the phone. The orchestrator cannot be told any more, but
    /// Apple tells it the token is gone the next time it sends, and it drops the row then.
    private func handleDeviceRevoked() {
        if pushNotifications?.isWanted == true {
            pushSystem.unregisterForRemoteNotifications()
        }
        tearDown()
        signedOutNotice = .revoked
    }

    /// Signs this phone out of the server and deletes its credential.
    ///
    /// The server is told first, while there is still a credential to tell it with: forget this
    /// phone for notifications, then revoke it. The credential is deleted whatever the answers
    /// were — the person asked to be signed out of this phone — and a server that could not be
    /// told is said so, because the phone then stays on the dashboard's device list until it is
    /// revoked there.
    func signOut() async {
        guard !isSigningOut, let credential, let api = signedInAPI else { return }
        isSigningOut = true
        defer { isSigningOut = false }

        if let push = pushNotifications {
            await push.forget()
        }

        var serverTold = false
        if let connection = credential.connection {
            do {
                try await api.revokeDevice(connection, deviceId: credential.deviceId)
                serverTold = true
            } catch ControlAPIError.unauthorized {
                // The orchestrator already refuses this phone: there is nothing left to revoke.
                serverTold = true
            } catch ControlAPIError.refused(let status, _) where status == 404 {
                serverTold = true
            } catch {
                serverTold = false
            }
        }

        tearDown()
        do {
            try credentialStore.delete()
            signedOutNotice = serverTold ? nil : .serverNotTold
        } catch {
            signedOutNotice = .credentialUnavailable
        }
    }

    private func tearDown() {
        controlPlane?.stop()
        controlPlane = nil
        runs = nil
        chat = nil
        pushNotifications = nil
        signedInAPI = nil
        signedInLogStream = nil
        credential = nil
        serverProfile = nil
    }

    // MARK: - Drafts

    func draft(for agentName: String) -> String {
        drafts[agentName] ?? ""
    }

    func setDraft(_ text: String, for agentName: String) {
        drafts[agentName] = text.isEmpty ? nil : text
    }

    // MARK: - Notifications

    /// Records, with the credential, whether notifications are wanted.
    ///
    /// The models are not rebuilt: this changes nothing about how the server is reached. A failed
    /// write is not surfaced. The worst outcome is that the wish is forgotten on the next launch
    /// and has to be stated again, which the notifications control then shows.
    private func persistPushDeviceId(_ deviceId: String?) {
        guard let current = credential else { return }
        let updated = current.withPushDeviceId(deviceId)
        credential = updated
        try? credentialStore.save(updated)
    }

    // MARK: - Logs

    /// A log model for one agent's log screen, or `nil` when signed out.
    func makeAgentLogModel(agentName: String) -> AgentLogModel? {
        guard let connection = credential?.connection, let stream = signedInLogStream else {
            return nil
        }
        return AgentLogModel(stream: stream, connection: connection, agentName: agentName)
    }

    /// Two spellings of the same address: a trailing slash and the case of the scheme and host
    /// are not differences.
    static func sameOrigin(_ first: String, _ second: String) -> Bool {
        normalizedOrigin(first) == normalizedOrigin(second)
    }

    private static func normalizedOrigin(_ origin: String) -> String {
        var trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? trimmed
    }
}
