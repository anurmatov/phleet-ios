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
/// The operator token is **not** proved here. The orchestrator asks for it only on a request
/// that changes something, and there is no request that changes nothing; inventing one to test a
/// token would be a write made to see whether writes are allowed. A wrong token is reported the
/// first time a decision is sent, in the place it can be acted on.
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
        case credentialWriteFailed
    }

    var address = ""
    var accessClientId = ""
    var accessClientSecret = ""
    var operatorToken = ""

    private(set) var isConnecting = false
    private(set) var addressMessage: Message?
    private(set) var serviceTokenMessage: Message?
    private(set) var formMessage: Message?

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

        do {
            try credentialStore.save(credential)
        } catch {
            formMessage = .credentialWriteFailed
            return nil
        }
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
