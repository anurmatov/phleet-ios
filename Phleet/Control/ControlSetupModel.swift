import Foundation
import Observation

/// Connecting this device to an orchestrator.
///
/// There is no enrollment here, because the orchestrator's operator API has none: the address,
/// the service token for whatever proxy sits in front, and the operator token are all things an
/// operator already holds. What this does is prove the first two before storing anything — one
/// read of the agent list, which only an orchestrator behind a proxy that let the request
/// through can answer.
///
/// The operator token is proved with the one read that checks it, when the orchestrator has that
/// read. A token it rejects is refused here, where it can be retyped, rather than at the first
/// approval. An older orchestrator has no such read; there the token is stored unverified and
/// `tokenVerification` says so, because a write made to see whether writes are allowed is not a
/// check this app will make.
@MainActor
@Observable
final class ControlSetupModel {

    enum Message: Error, Equatable, Sendable {
        case addressEmpty
        case addressInsecure
        case addressMalformed
        case addressMissingHost
        case addressUserInfo
        /// One half of the service token was given without the other.
        case serviceTokenIncomplete
        /// The proxy in front refused: wrong service token, or a policy that does not admit one.
        case accessDenied
        case unreachable
        /// Something answered at that address and it was not an orchestrator.
        case notAnOrchestrator
        /// The orchestrator said the operator token is not its token.
        case operatorTokenRejected
        case credentialWriteFailed
    }

    /// What is known about the operator token that was stored.
    enum TokenVerification: Equatable, Sendable {
        /// No token was entered: a read-only connection. Named so rather than `none`, which
        /// an optional of this type would confuse with its own absence.
        case noToken
        /// The orchestrator accepted it.
        case verified
        /// The orchestrator does not gate writes, so the token was not checked against anything.
        case notRequired
        /// The orchestrator could not be asked. A wrong token will surface at the first write.
        case unverified
    }

    var address = ""
    var accessClientId = ""
    var accessClientSecret = ""
    var operatorToken = ""

    private(set) var isConnecting = false
    private(set) var addressMessage: Message?
    private(set) var serviceTokenMessage: Message?
    private(set) var formMessage: Message?
    private(set) var tokenMessage: Message?

    /// Set by a successful `connect()`.
    private(set) var tokenVerification: TokenVerification = .noToken

    private let api: ControlAPIClient
    private let credentialStore: ControlCredentialStore

    init(api: ControlAPIClient, credentialStore: ControlCredentialStore) {
        self.api = api
        self.credentialStore = credentialStore
    }

    /// Validates, probes, stores. Returns the stored credential, or `nil` with a message set.
    @discardableResult
    func connect() async -> ControlCredential? {
        addressMessage = nil
        serviceTokenMessage = nil
        formMessage = nil
        tokenMessage = nil
        tokenVerification = .noToken

        let origin: String
        switch Self.validatedOrigin(address) {
        case .success(let value):
            origin = value
        case .failure(let message):
            addressMessage = message
            return nil
        }

        let clientId = accessClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = accessClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientId.isEmpty == clientSecret.isEmpty else {
            serviceTokenMessage = .serviceTokenIncomplete
            return nil
        }

        let credential = ControlCredential(
            origin: origin,
            accessClientId: clientId,
            accessClientSecret: clientSecret,
            operatorToken: operatorToken
        )
        guard let connection = credential.connection else {
            addressMessage = .addressMalformed
            return nil
        }

        isConnecting = true
        defer { isConnecting = false }

        do {
            _ = try await api.agents(connection)
        } catch {
            formMessage = Self.message(forProbe: error)
            return nil
        }

        let verification: TokenVerification
        if credential.canDecide {
            do {
                switch try await api.checkOperatorToken(connection) {
                case .accepted:
                    verification = .verified
                case .notRequired:
                    verification = .notRequired
                case .unsupported:
                    verification = .unverified
                case .rejected:
                    // Nothing is stored. The address and the proxy are fine; the one thing that
                    // is wrong is the thing the person can retype right here.
                    tokenMessage = .operatorTokenRejected
                    return nil
                }
            } catch {
                // The read of the agent list just succeeded, so the orchestrator is there. A
                // check that could not complete is "not known", and does not block setup.
                verification = .unverified
            }
        } else {
            verification = .noToken
        }

        do {
            try credentialStore.save(credential)
        } catch {
            formMessage = .credentialWriteFailed
            return nil
        }
        tokenVerification = verification
        return credential
    }

    /// The same rules enrollment applies to an address, because it is the same kind of value: a
    /// bare host gets `https://`, and an explicit `http://` is refused rather than upgraded.
    static func validatedOrigin(_ raw: String) -> Result<String, Message> {
        let normalized: String
        switch EnrollmentModel.normalizedAddress(raw) {
        case .success(let value):
            normalized = value
        case .failure(.addressInsecure):
            return .failure(.addressInsecure)
        case .failure:
            return .failure(.addressEmpty)
        }

        guard let components = URLComponents(string: normalized) else {
            return .failure(.addressMalformed)
        }
        let displayName = ServerDisplayName.derive(from: components)
        guard !displayName.isEmpty else {
            return .failure(.addressMissingHost)
        }

        do {
            let profile = try FleetServerProfile(displayName: displayName, urlString: normalized)
            return .success(profile.baseURL.absoluteString)
        } catch FleetServerProfileError.insecureScheme {
            return .failure(.addressInsecure)
        } catch FleetServerProfileError.missingHost {
            return .failure(.addressMissingHost)
        } catch FleetServerProfileError.userInfoPresent {
            return .failure(.addressUserInfo)
        } catch {
            return .failure(.addressMalformed)
        }
    }

    private static func message(forProbe error: Error) -> Message {
        switch error as? ControlAPIError {
        case .accessDenied?:
            return .accessDenied
        case .transport?:
            return .unreachable
        case .decoding?, .unauthorized?, .gateChanged?, .refused?, .readOnly?, nil:
            return .notAnOrchestrator
        }
    }
}
