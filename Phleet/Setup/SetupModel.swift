import Foundation
import Observation

/// What signing in produced: the stored credential, and the token holder that already has a
/// token in it, so the first request after setup does not mint a second one.
struct SetupOutcome {
    let credential: DeviceCredential
    let tokens: AccessTokenHolder
}

/// Signing this phone in: scan the dashboard's setup code, check the address, connect.
///
/// One step for the Fleet, Runs and Chat tabs alike. Connecting registers the phone with the
/// code's one-time enrollment code, stores the device credential it is given, and mints the first
/// access token. Scanning connects to nothing: the address the code named is on screen for a
/// person to check, and connecting is a separate tap.
@MainActor
@Observable
final class SetupModel {

    /// What the person is told. One case per thing they would do differently.
    enum Message: Error, Equatable, Sendable {
        // About what was scanned.
        case notASetupCode
        case olderDashboard
        case newerFormat
        case incomplete
        case insecureAddress
        case invalidAddress

        // About connecting.
        /// `401` from registering: the code was used, expired, or never issued. One message for
        /// all of them — the orchestrator answers each the same way on purpose.
        case codeNotAccepted
        /// `409 device_limit`: the person has as many signed-in devices as the fleet allows.
        case deviceLimit
        /// The access proxy in front of the address turned the request away.
        case accessDenied
        case unreachable
        case rateLimited
        /// The server answered, and has no sign-in for the app: one from before it existed.
        case serverTooOld
        /// The server could not sign anyone in just now.
        case serverUnavailable
        /// Something answered, and it was not a Fleet server.
        case notAFleet
        case credentialWriteFailed
        /// Registered, and then the first token was refused: the phone was revoked in between.
        case signInRefused
    }

    /// The code that was read, waiting for the person to connect. Cleared by signing in.
    private(set) var code: SetupCode?
    private(set) var message: Message?
    private(set) var isConnecting = false

    private let api: ControlAPIClient
    private let credentialStore: CredentialStore
    private let deviceName: String?
    private let makeTokenHolder: @MainActor (CredentialStore) -> AccessTokenHolder
    private let newClientInstanceId: () -> String

    init(
        api: ControlAPIClient,
        credentialStore: CredentialStore,
        deviceName: String?,
        makeTokenHolder: @escaping @MainActor (CredentialStore) -> AccessTokenHolder,
        newClientInstanceId: @escaping () -> String = ClientIdentifier.random
    ) {
        self.api = api
        self.credentialStore = credentialStore
        self.deviceName = deviceName
        self.makeTokenHolder = makeTokenHolder
        self.newClientInstanceId = newClientInstanceId
    }

    /// Reads a scanned setup code. **Never connects.**
    ///
    /// A code that cannot be used replaces nothing: one read earlier stays ready to connect, and
    /// the message says why this one was refused.
    @discardableResult
    func apply(scanned text: String) -> Bool {
        guard !isConnecting else { return false }
        switch SetupCode.parse(text) {
        case .success(let parsed):
            code = parsed
            message = nil
            return true
        case .failure(let failure):
            message = Self.message(for: failure)
            return false
        }
    }

    /// Registers, stores, mints. Returns the outcome, or `nil` with a message set.
    func connect() async -> SetupOutcome? {
        guard let code, !isConnecting else { return nil }
        message = nil

        guard let origin = URL(string: code.origin) else {
            message = .invalidAddress
            return nil
        }
        let connection = ControlConnection(origin: origin, serviceToken: code.serviceToken)

        isConnecting = true
        defer { isConnecting = false }

        let device: RegisteredDevice
        do {
            device = try await api.registerDevice(
                connection,
                enrollmentCode: code.enrollmentCode,
                deviceName: deviceName
            )
        } catch {
            message = Self.message(forRegistration: error)
            return nil
        }

        // Stored **before** the first token is asked for. The orchestrator commits the device
        // before it can know its answer arrived; a phone that stored the secret only after a
        // successful mint could lose it to a dropped packet, leaving a device it cannot use.
        let credential = credentialToStore(for: device, code: code)
        do {
            try credentialStore.save(credential)
        } catch {
            message = .credentialWriteFailed
            return nil
        }

        let tokens = makeTokenHolder(credentialStore)
        do {
            _ = try await tokens.accessToken()
        } catch AccessTokenHolder.Failure.deviceRevoked {
            // The holder has already deleted the credential: it is no use to anyone.
            message = .signInRefused
            return nil
        } catch {
            // Registered and stored, and the code is spent. A token that could not be had this
            // minute is asked for again when it is needed; making the person scan a new code
            // would not help.
        }

        self.code = nil
        return SetupOutcome(credential: credential, tokens: tokens)
    }

    /// A rotated secret for the device already stored, or a new credential.
    ///
    /// Presenting the same code again before the first token is minted answers with the same
    /// `deviceId` and a **rotated** secret, so an existing credential for that device is
    /// overwritten and keeps its cursor bookkeeping and its notification wish.
    private func credentialToStore(for device: RegisteredDevice, code: SetupCode) -> DeviceCredential {
        if let existing = try? credentialStore.load(),
           existing.deviceId == device.deviceId,
           existing.origin == code.origin {
            return existing.rotatingSecret(to: device.deviceSecret)
        }
        return DeviceCredential(
            origin: code.origin,
            accessClientId: code.accessClientId,
            accessClientSecret: code.accessClientSecret,
            deviceId: device.deviceId,
            deviceSecret: device.deviceSecret,
            clientInstanceId: newClientInstanceId()
        )
    }

    static func message(for failure: SetupCode.Failure) -> Message {
        switch failure {
        case .notASetupCode: return .notASetupCode
        case .olderDashboard: return .olderDashboard
        case .unsupportedVersion: return .newerFormat
        case .incomplete: return .incomplete
        case .insecureAddress: return .insecureAddress
        case .invalidAddress: return .invalidAddress
        }
    }

    static func message(forRegistration error: Error) -> Message {
        switch error as? ControlAPIError {
        case .unauthorized?:
            return .codeNotAccepted
        case .gateChanged(let code)? where code == "device_limit":
            // The orchestrator's `409` carries its code; this is the only one registering gives.
            return .deviceLimit
        case .accessDenied?:
            return .accessDenied
        case .transport?:
            return .unreachable
        case .refused(let status, _)? where status == 429:
            return .rateLimited
        case .refused(let status, _)? where status == 404 || status == 405:
            return .serverTooOld
        case .refused(let status, _)? where status >= 500:
            return .serverUnavailable
        case .gateChanged?, .refused?, .decoding?, nil:
            return .notAFleet
        }
    }
}
