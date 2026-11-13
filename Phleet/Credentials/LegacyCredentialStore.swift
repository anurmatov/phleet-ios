import Foundation
import Security

/// Whether notifications were on under an earlier build, and for which server.
struct LegacyNotificationWish: Equatable, Sendable {
    let origin: String
    let pushDeviceId: String
}

/// What earlier builds kept in the Keychain, taken away.
///
/// Before one sign-in, the app kept two items: a chat credential, enrolled with a sign-in the
/// chat service no longer has, and a Fleet connection holding the fleet-wide operator token.
/// Neither is used again, and the operator token must not outlive the build that needed it, so
/// both are deleted at launch.
///
/// One thing in the Fleet connection is still worth keeping: the identifier the orchestrator
/// knows this phone by for notifications. The orchestrator's list of phones to notify is keyed by
/// it, so a new identifier would leave the old row behind and the phone would be told everything
/// twice. It is handed back so the first sign-in to the same address can carry it over.
protocol LegacyCredentialStore {
    /// Deletes both items and returns the notification wish one of them held.
    ///
    /// An item that cannot be read for a reason other than "not there" is left alone, to be taken
    /// on a later launch: a read that failed because the phone is locked must not throw away the
    /// one thing worth keeping.
    func takeNotificationWish() -> LegacyNotificationWish?
}

/// Holds an answer for the lifetime of the process. Used by the tests and the scripted backend.
final class InMemoryLegacyCredentialStore: LegacyCredentialStore {

    private var wish: LegacyNotificationWish?
    private(set) var takeCount = 0

    init(wish: LegacyNotificationWish? = nil) {
        self.wish = wish
    }

    func takeNotificationWish() -> LegacyNotificationWish? {
        takeCount += 1
        defer { wish = nil }
        return wish
    }
}

/// The two items earlier builds wrote, by the names they wrote them under.
final class KeychainLegacyCredentialStore: LegacyCredentialStore {

    static let chatService = "com.anvarlab.phleet.device-credential"
    static let chatAccount = "device"
    static let fleetService = "com.anvarlab.phleet.control-credential"
    static let fleetAccount = "orchestrator"

    private let chatService: String
    private let chatAccount: String
    private let fleetService: String
    private let fleetAccount: String

    init(
        chatService: String = KeychainLegacyCredentialStore.chatService,
        chatAccount: String = KeychainLegacyCredentialStore.chatAccount,
        fleetService: String = KeychainLegacyCredentialStore.fleetService,
        fleetAccount: String = KeychainLegacyCredentialStore.fleetAccount
    ) {
        self.chatService = chatService
        self.chatAccount = chatAccount
        self.fleetService = fleetService
        self.fleetAccount = fleetAccount
    }

    /// The part of the old Fleet connection that is read. Its operator token is never decoded.
    private struct FleetConnectionItem: Decodable {
        let origin: String?
        let pushDeviceId: String?
    }

    func takeNotificationWish() -> LegacyNotificationWish? {
        // Nothing in the chat item is kept: its secret belongs to a sign-in that no longer exists.
        SecItemDelete(
            KeychainCredentialStore.baseQuery(service: chatService, account: chatAccount)
                as CFDictionary
        )

        var query = KeychainCredentialStore.baseQuery(service: fleetService, account: fleetAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            // Not there, or not readable now. Either way nothing is deleted here.
            return nil
        }

        SecItemDelete(
            KeychainCredentialStore.baseQuery(service: fleetService, account: fleetAccount)
                as CFDictionary
        )

        guard
            let data = item as? Data,
            let decoded = try? JSONDecoder().decode(FleetConnectionItem.self, from: data),
            let origin = decoded.origin,
            let pushDeviceId = decoded.pushDeviceId,
            !pushDeviceId.isEmpty
        else { return nil }
        return LegacyNotificationWish(origin: origin, pushDeviceId: pushDeviceId)
    }
}
