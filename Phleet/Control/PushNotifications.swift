import Foundation
import Observation

/// Whether the person lets this app show notifications.
enum PushPermission: Equatable, Sendable {
    case granted
    case denied
}

/// The operating system's side of notifications, behind a seam.
///
/// Three things only the system can do: ask the person, ask Apple for this install's device
/// token, and stop receiving. The token does not come back from the call that asks for it; it
/// arrives later through `onDeviceToken`, or not at all through `onRegistrationFailed`.
@MainActor
protocol PushSystem: AnyObject {
    var onDeviceToken: ((String) -> Void)? { get set }
    var onRegistrationFailed: (() -> Void)? { get set }
    /// A notification was tapped.
    var onOpened: ((PushDestination) -> Void)? { get set }

    /// Asks the person, the first time. Afterwards answers with what they chose.
    func requestPermission() async -> PushPermission
    func registerForRemoteNotifications()
    func unregisterForRemoteNotifications()
}

/// Where a tapped notification should land.
enum PushDestination: Equatable, Sendable {
    /// A waiting gate or an agent that went down: the Fleet tab shows both first.
    case fleet
    /// A failed run: the Runs tab lists it under what stopped without finishing.
    case runs

    /// Reads the `kind` the orchestrator put in the notification. Anything else — a kind this
    /// build does not know, or no kind at all — opens the fleet: it is where a person looks
    /// first, and a notification must never open nothing.
    static func destination(forKind kind: String?) -> PushDestination {
        kind == "run" ? .runs : .fleet
    }

    /// The `kind` in a notification's payload, if it carries one in the expected place.
    static func kind(in userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["phleet"] as? [String: Any])?["kind"] as? String
    }
}

/// Notifications for one orchestrator connection: on, off, and why not.
///
/// Turning them on is three steps that each can stop it — the person's permission, a device
/// token from Apple, and the orchestrator accepting that token — and every stop has its own
/// state, because each is fixed in a different place.
@MainActor
@Observable
final class PushNotificationsModel {

    enum State: Equatable, Sendable {
        case off
        /// Waiting for the person to answer the system's question.
        case asking
        /// Permission given; waiting for Apple's token, or for the orchestrator to take it.
        case registering
        case on
        /// The person said no. Changed in Settings, not here.
        case denied
        /// This connection has no operator token, and registering is a change.
        case readOnly
        /// The orchestrator has notifications switched off.
        case disabledOnServer
        /// The orchestrator predates notifications.
        case unsupportedServer
        /// Apple gave no device token (no network, or a build without the push entitlement).
        case tokenUnavailable
        /// The orchestrator could not be told. Still wanted, and tried again on the next launch.
        case failed(ControlPlaneModel.ActionFailure)

        /// Whether asking again could change anything. Not after a refusal the person made at
        /// the system prompt (that is changed in Settings), and not on a connection that cannot
        /// write.
        var offersTurnOn: Bool {
            switch self {
            case .off, .disabledOnServer, .unsupportedServer, .tokenUnavailable, .failed:
                return true
            case .asking, .registering, .on, .denied, .readOnly:
                return false
            }
        }
    }

    private let api: ControlAPIClient
    private let system: PushSystem
    private let connection: ControlConnection
    private let persist: (String?) -> Void
    private let newDeviceId: () -> String

    private(set) var state: State = .off

    /// Non-nil while notifications are wanted. Mirrors what is stored with the connection.
    private(set) var deviceId: String?

    /// Moves on with every change of mind and every token from Apple. A registration that
    /// finishes after it has moved on was made for a wish that no longer stands, so it changes
    /// nothing: it cannot turn notifications back on, report a stale failure, or clear a newer
    /// wish.
    private var generation = 0

    /// The registration with the orchestrator now, or the last one waiting for it. They go one at
    /// a time, so the orchestrator stores tokens in the order Apple issued them: an older token
    /// answered late can never replace a newer one.
    private var registration: Task<Void, Never>?

    init(
        api: ControlAPIClient,
        system: PushSystem,
        connection: ControlConnection,
        deviceId: String?,
        persist: @escaping (String?) -> Void,
        newDeviceId: @escaping () -> String = ClientIdentifier.random
    ) {
        self.api = api
        self.system = system
        self.connection = connection
        self.deviceId = deviceId
        self.persist = persist
        self.newDeviceId = newDeviceId
    }

    var isWanted: Bool { deviceId != nil }

    /// Whether the control should offer "turn off" rather than "turn on".
    var offersTurnOff: Bool {
        switch state {
        case .on, .registering, .failed, .tokenUnavailable: return isWanted
        case .off, .asking, .denied, .readOnly, .disabledOnServer, .unsupportedServer: return false
        }
    }

    /// Called when the connection is adopted. If notifications were on, asks Apple for the
    /// token again: it can change between launches, and the orchestrator must hear the new one.
    func resume() {
        guard isWanted else { return }
        state = .registering
        system.registerForRemoteNotifications()
    }

    func turnOn() async {
        guard connection.operatorToken != nil else {
            state = .readOnly
            return
        }

        state = .asking
        guard await system.requestPermission() == .granted else {
            state = .denied
            return
        }

        // A new wish always gets a new identifier, so taking back a registration made for an
        // older one can never remove this one.
        let id = deviceId ?? newDeviceId()
        deviceId = id
        // Stored before the token arrives: the wish to be notified is the person's, and it
        // survives a launch in which Apple or the orchestrator could not be reached.
        persist(id)
        state = .registering
        system.registerForRemoteNotifications()
    }

    /// Apple issued a token. Tells the orchestrator, if notifications are wanted, once every
    /// earlier registration has been answered.
    func handleDeviceToken(_ token: String) async {
        guard deviceId != nil else { return }
        generation += 1
        let sent = generation
        let previous = registration
        let current = Task {
            await previous?.value
            await self.register(token, generation: sent)
        }
        registration = current
        await current.value
    }

    /// Sends one token. One overtaken while it waited — by a newer token or a change of mind — is
    /// not sent at all.
    private func register(_ token: String, generation sent: Int) async {
        guard sent == generation, let deviceId else { return }
        do {
            try await api.registerPushDevice(connection, deviceId: deviceId, token: token)
            guard sent == generation else {
                await withdrawLateRegistration(of: deviceId)
                return
            }
            state = .on
        } catch {
            guard sent == generation else { return }
            switch error as? ControlAPIError {
            case .refused(let status, let message)? where status == 503 && message == "push_disabled":
                // Not a failure to retry: the orchestrator will not send. Saying "on" here
                // would be a promise nobody keeps.
                giveUp(.disabledOnServer)
            case .refused(let status, _)? where status == 404 || status == 405:
                giveUp(.unsupportedServer)
            case .readOnly?:
                giveUp(.readOnly)
            default:
                state = .failed(ControlPlaneModel.ActionFailure.from(error))
            }
        }
    }

    func handleRegistrationFailed() {
        guard isWanted else { return }
        state = .tokenUnavailable
    }

    /// Turns notifications off. The phone stops receiving at once, whether or not the
    /// orchestrator could be told to forget it. The wish goes before anything is awaited, so a
    /// registration finishing meanwhile finds it already gone.
    func turnOff() async {
        let unwanted = deviceId
        generation += 1
        deviceId = nil
        persist(nil)
        state = .off
        system.unregisterForRemoteNotifications()
        if let unwanted {
            try? await api.unregisterPushDevice(connection, deviceId: unwanted)
        }
    }

    /// The connection is being removed. Best effort: without the connection there is no way to
    /// try again, and the phone has already stopped receiving.
    func forget() async {
        guard let deviceId else { return }
        generation += 1
        self.deviceId = nil
        state = .off
        system.unregisterForRemoteNotifications()
        try? await api.unregisterPushDevice(connection, deviceId: deviceId)
    }

    /// The orchestrator accepted a registration after the wish behind it had changed. Its
    /// "forget this device" may have arrived first, so it is told again — unless the device is
    /// still the one wanted, in which case the newer registration decides.
    private func withdrawLateRegistration(of lateId: String) async {
        guard lateId != deviceId else { return }
        try? await api.unregisterPushDevice(connection, deviceId: lateId)
    }

    private func giveUp(_ reason: State) {
        system.unregisterForRemoteNotifications()
        deviceId = nil
        persist(nil)
        state = reason
    }
}
