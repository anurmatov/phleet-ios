import Foundation

/// What a shortcut can do without any of the app's screens: say what is waiting, and send one
/// message to one agent.
///
/// Used by the App Intents, which run with the app in the background or not showing at all. It
/// signs in the way the app does — the stored credential, one fifteen-minute token minted from
/// it, sent in a header — and keeps nothing afterwards.
///
/// It never deletes the credential. A refused mint is reported as "signed out"; ending the
/// sign-in stays with `AccessTokenHolder`, the one place allowed to, the next time the app runs.
struct QuickActions {

    enum Failure: Error, Equatable, Sendable {
        /// No sign-in on this phone, or the server refuses the one there is.
        case signedOut
        /// The server did not answer, or something in front of it turned the request away.
        case unreachable
        /// The agent does not take chat, or is not one this server lists.
        case agentUnavailable
        /// Longer than the server takes in one message.
        case tooLong
        /// The server said no.
        case refused
    }

    /// The fleet in two numbers and a few names.
    struct FleetSummary: Equatable, Sendable {
        /// What each waiting run is waiting for, oldest first.
        let waiting: [String]
        /// Agents that are down or late.
        let needingAttention: [String]
        let agentCount: Int
    }

    let credentialStore: CredentialStore
    let controlAPI: ControlAPIClient
    let makeChatAPI: (AccessServiceToken?) -> FleetAPIClient
    let newIdentifier: () -> String

    /// The real thing: the Keychain, and sessions with the same rules the app's own have.
    static func live() -> QuickActions {
        QuickActions(
            credentialStore: KeychainCredentialStore(),
            controlAPI: URLSessionControlAPIClient(session: ControlTransport.makeSession()),
            makeChatAPI: { serviceToken in
                URLSessionFleetAPIClient(
                    session: ControlTransport.makeSession(
                        requestTimeout: ControlTransport.chatRequestTimeoutSeconds
                    ),
                    serviceToken: serviceToken
                )
            },
            newIdentifier: ClientIdentifier.random
        )
    }

    // MARK: - Signing in

    private struct SignIn {
        let credential: DeviceCredential
        let origin: URL
        let connection: ControlConnection
        let token: String
    }

    private func signIn() async throws -> SignIn {
        let stored: DeviceCredential?
        do {
            stored = try credentialStore.load()
        } catch {
            throw Failure.signedOut
        }
        guard let credential = stored,
              let connection = credential.connection,
              let origin = credential.originURL
        else { throw Failure.signedOut }

        do {
            let minted = try await controlAPI.mintToken(
                connection,
                deviceId: credential.deviceId,
                deviceSecret: credential.deviceSecret
            )
            return SignIn(
                credential: credential,
                origin: origin,
                connection: connection.bearing(minted.accessToken),
                token: minted.accessToken
            )
        } catch ControlAPIError.unauthorized {
            throw Failure.signedOut
        } catch {
            throw Failure.unreachable
        }
    }

    // MARK: - What is waiting

    func fleetSummary() async throws -> FleetSummary {
        let session = try await signIn()
        do {
            let registry = try await controlAPI.signalRegistry(session.connection)
            let agents = try await controlAPI.agents(session.connection)
            let runs = try await controlAPI.workflows(session.connection)

            let gates = PendingGates.derive(runs: runs, registry: registry)
            return FleetSummary(
                waiting: gates.map { $0.heading + " — " + RunSubject.text(for: $0.run) },
                needingAttention: agents
                    .filter { $0.health.needsAttention }
                    .sorted(by: FleetAgent.glanceOrder)
                    .map(\.title),
                agentCount: agents.count
            )
        } catch ControlAPIError.unauthorized {
            throw Failure.signedOut
        } catch {
            throw Failure.unreachable
        }
    }

    // MARK: - Chat

    func chatAgents() async throws -> [ChatAgent] {
        let session = try await signIn()
        do {
            let list = try await controlAPI.chatAgents(session.connection)
            return list.available ? list.agents : []
        } catch ControlAPIError.unauthorized {
            throw Failure.signedOut
        } catch {
            throw Failure.unreachable
        }
    }

    /// Sends one message to one agent's thread — the same thread the app and the dashboard open.
    ///
    /// One attempt. A send that does not complete is reported as not known to have been sent,
    /// and is not tried again here: trying again under new identifiers is how one message
    /// becomes two turns, and a shortcut has no screen on which to show the first.
    func send(_ text: String, toAgentNamed agentName: String) async throws {
        guard text.utf8.count <= SessionLimits.documentedDefaults.inboundTextBytes else {
            throw Failure.tooLong
        }
        let session = try await signIn()
        let chatAPI = makeChatAPI(session.credential.serviceToken)

        do {
            let conversation = try await chatAPI.openConversation(
                origin: session.origin,
                accessToken: session.token,
                externalRef: ConversationModel.externalRef,
                agent: agentName,
                clientInstanceId: session.credential.clientInstanceId
            )
            _ = try await chatAPI.submit(
                origin: session.origin,
                accessToken: session.token,
                conversationId: conversation.conversationId,
                body: SubmissionBody(
                    type: .create,
                    submissionId: newIdentifier(),
                    idempotencyKey: newIdentifier(),
                    text: text
                )
            )
        } catch FleetAPIError.unauthorized {
            throw Failure.signedOut
        } catch FleetAPIError.refused(.agentUnavailable, _, _) {
            throw Failure.agentUnavailable
        } catch FleetAPIError.refused(.payloadTooLarge, _, _) {
            throw Failure.tooLong
        } catch FleetAPIError.refused {
            throw Failure.refused
        } catch {
            throw Failure.unreachable
        }
    }
}

extension QuickActions.FleetSummary {

    /// The summary in a sentence or two, for a voice to read and a banner to show.
    ///
    /// Names what is waiting, not how to answer it: a decision is made on the gate's own screen,
    /// with the run in front of the person, never by voice.
    var spoken: String {
        var sentences: [String] = []

        if waiting.isEmpty {
            sentences.append(String(localized: "shortcut.status.nothingWaiting", bundle: .main))
        } else {
            sentences.append(
                String(localized: "shortcut.status.waiting", bundle: .main) + " "
                    + String(waiting.count) + ": " + waiting.prefix(3).joined(separator: "; ") + "."
            )
        }

        if needingAttention.isEmpty {
            if agentCount > 0 {
                sentences.append(String(localized: "shortcut.status.agentsFine", bundle: .main))
            }
        } else {
            sentences.append(
                String(localized: "shortcut.status.agentsDown", bundle: .main) + " "
                    + needingAttention.joined(separator: ", ") + "."
            )
        }
        return sentences.joined(separator: " ")
    }
}
