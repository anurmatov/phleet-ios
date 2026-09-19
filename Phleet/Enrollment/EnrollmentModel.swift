import Foundation
import Observation

/// Derives the name shown for a server from the address the person typed.
///
/// `displayName` is not a third thing to type. It is the host, with a leading `www.` removed and
/// a non-standard port kept, because the port is the part two otherwise-identical addresses
/// differ by.
enum ServerDisplayName {
    static func derive(from components: URLComponents) -> String {
        guard var host = components.host, !host.isEmpty else { return "" }

        let prefix = "www."
        if host.lowercased().hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        if let port = components.port {
            return host + ":" + String(port)
        }
        return host
    }
}

/// What enrollment produced.
struct EnrollmentOutcome: Equatable, Sendable {
    let credential: DeviceCredential
    let displayName: String
    let principalId: String?
    /// Cosmetic and non-authoritative. Absent when `GET /v1/session` did not answer.
    let agentLabel: String?
    let limits: SessionLimits
}

/// Registering this device against a server, and the one branch that matters.
@MainActor
@Observable
final class EnrollmentModel {

    /// What the person is told. One case per distinguishable outcome, and deliberately **one**
    /// case covering every `401`: expired code, already-burned code, unknown code and wrong
    /// secret are indistinguishable by contract, and the interface must not guess which.
    enum Message: Error, Equatable, Sendable {
        case addressEmpty
        case addressInsecure
        case addressMalformed
        case addressMissingHost
        case addressUserInfo
        case codeEmpty
        case codeNotAccepted
        case deviceLimit
        case credentialUnavailable
        case credentialWriteFailed
        case rateLimited(seconds: Int)
        case serverUnavailable
        case deviceRevoked
    }

    enum Phase: Equatable, Sendable {
        case editing
        case connecting
        case connected
    }

    var address = ""
    var enrollmentCode = ""

    private(set) var phase: Phase = .editing
    private(set) var addressMessage: Message?
    private(set) var codeMessage: Message?
    private(set) var formMessage: Message?
    private(set) var outcome: EnrollmentOutcome?

    private let api: FleetAPIClient
    private let credentialStore: CredentialStore
    private let makeTokenHolder: @MainActor (CredentialStore) -> AccessTokenHolder
    private let newClientInstanceId: () -> String

    init(
        api: FleetAPIClient,
        credentialStore: CredentialStore,
        makeTokenHolder: @escaping @MainActor (CredentialStore) -> AccessTokenHolder,
        newClientInstanceId: @escaping () -> String = ClientIdentifier.random
    ) {
        self.api = api
        self.credentialStore = credentialStore
        self.makeTokenHolder = makeTokenHolder
        self.newClientInstanceId = newClientInstanceId
    }

    var isConnecting: Bool { phase == .connecting }

    /// Normalises a typed address.
    ///
    /// A bare host gets `https://`. An explicit `http://` is **rejected, not silently upgraded** —
    /// upgrading hides that the person was handed the wrong address, and the address is the one
    /// value here that a human is expected to retype.
    static func normalizedAddress(_ raw: String) -> Result<String, Message> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.addressEmpty) }

        guard let separator = trimmed.range(of: "://") else {
            return .success("https://" + trimmed)
        }

        let scheme = trimmed[trimmed.startIndex..<separator.lowerBound].lowercased()
        guard scheme == "https" else { return .failure(.addressInsecure) }
        return .success(trimmed)
    }

    /// Trims the outside of a pasted code and nothing else.
    ///
    /// A value pasted out of a chat message frequently carries a trailing newline. Internal
    /// whitespace is left alone: that is a different value, not a formatting artefact, and
    /// "helpfully" removing it sends something the person did not paste.
    static func normalizedCode(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs register → mint → session.
    @discardableResult
    func connect() async -> EnrollmentOutcome? {
        addressMessage = nil
        codeMessage = nil
        formMessage = nil

        let normalizedAddress: String
        switch Self.normalizedAddress(address) {
        case .success(let value):
            normalizedAddress = value
        case .failure(let message):
            addressMessage = message
            return nil
        }

        guard let components = URLComponents(string: normalizedAddress) else {
            addressMessage = .addressMalformed
            return nil
        }
        let displayName = ServerDisplayName.derive(from: components)
        guard !displayName.isEmpty else {
            addressMessage = .addressMissingHost
            return nil
        }

        let profile: FleetServerProfile
        do {
            profile = try FleetServerProfile(
                displayName: displayName,
                urlString: normalizedAddress
            )
        } catch {
            addressMessage = Self.message(for: error as? FleetServerProfileError)
            return nil
        }

        let code = Self.normalizedCode(enrollmentCode)
        guard !code.isEmpty else {
            codeMessage = .codeEmpty
            return nil
        }

        phase = .connecting
        defer { if phase == .connecting { phase = .editing } }

        let registration: RegisterDeviceResponse
        do {
            registration = try await api.registerDevice(
                origin: profile.baseURL,
                enrollmentCode: code
            )
        } catch {
            formMessage = Self.message(forRegistration: error)
            return nil
        }

        // Persisted **before** the mint is attempted. The server commits the device record
        // before it can know its response arrived; a client that persists only after a
        // successful mint can lose the secret to a dropped packet while the server holds an
        // active device that blocks re-registration — locking the owner out with no path back
        // except operator intervention.
        let credential = credentialToStore(for: registration, origin: profile.baseURL)
        do {
            try credentialStore.save(credential)
        } catch {
            formMessage = .credentialWriteFailed
            return nil
        }

        let tokens = makeTokenHolder(credentialStore)
        let accessToken: String
        do {
            accessToken = try await tokens.accessToken()
        } catch AccessTokenHolder.Failure.deviceRevoked {
            formMessage = .deviceRevoked
            return nil
        } catch {
            // The credential is retained. A mint that failed for any reason other than a `401`
            // says nothing about whether the device record is alive.
            formMessage = Self.message(forRegistration: error)
            return nil
        }

        // A failed session read does not fail enrollment: the credential is what matters. The
        // contract's documented defaults stand in until the next foreground retries it.
        let session = try? await api.session(origin: profile.baseURL, accessToken: accessToken)

        let result = EnrollmentOutcome(
            credential: credential,
            displayName: profile.displayName,
            principalId: session?.principalId,
            agentLabel: session?.agentLabel,
            limits: session?.limits ?? SessionLimits.documentedDefaults
        )
        outcome = result
        phase = .connected
        return result
    }

    /// Reuses the existing `clientInstanceId` when the server returned the same device.
    ///
    /// Re-presenting the same code inside the re-presentation window answers with the same
    /// `deviceId` and a **rotated** `deviceSecret`. An existing credential is therefore not a
    /// reason to refuse — it is overwritten — and the cursor bookkeeping stays continuous
    /// because it belongs to the same device. Once a token has been minted the window is closed
    /// server-side; the client does not track it and must not try to predict which side of it a
    /// retry falls on.
    private func credentialToStore(
        for registration: RegisterDeviceResponse,
        origin: URL
    ) -> DeviceCredential {
        let existing = try? credentialStore.load()
        let isSameDevice = existing?.deviceId == registration.deviceId
            && existing?.origin == origin.absoluteString

        return DeviceCredential(
            origin: origin,
            deviceId: registration.deviceId,
            deviceSecret: registration.deviceSecret,
            clientInstanceId: isSameDevice && existing != nil
                ? existing!.clientInstanceId
                : newClientInstanceId()
        )
    }

    private static func message(for error: FleetServerProfileError?) -> Message {
        switch error {
        case .insecureScheme: return .addressInsecure
        case .missingHost: return .addressMissingHost
        case .userInfoPresent: return .addressUserInfo
        case .emptyDisplayName, .malformedURL, .none: return .addressMalformed
        }
    }

    private static func message(forRegistration error: Error) -> Message {
        guard let apiError = error as? FleetAPIError else { return .serverUnavailable }

        if apiError.isDeviceLimit {
            // Another device is already active. The resolution is operator revocation plus a
            // fresh code — there is deliberately no "replace it" control, because no north route
            // can do that and an unauthenticated one would be a one-request denial of service
            // against the only way in.
            return .deviceLimit
        }
        switch apiError {
        case .unauthorized:
            return .codeNotAccepted
        case .rateLimited(let seconds):
            return .rateLimited(seconds: seconds)
        default:
            return .serverUnavailable
        }
    }
}
