import Foundation
import Security

/// The device credential at rest.
///
/// One `kSecClassGenericPassword` item holding the whole `DeviceCredential` as JSON, with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
///
/// - `AfterFirstUnlock`, not `WhenUnlocked`, because a reconnect — and later an APNs-woken fetch
///   — must be able to read the credential while the screen is locked.
/// - `ThisDeviceOnly` is the load-bearing half. It excludes the item from iCloud Keychain and
///   from encrypted backups, so a restore to a new device arrives with **no** credential. That
///   is precisely what the contract requires: a secure-store loss is recovered by
///   revoke-and-re-enroll, never a silent re-issue. Making the item non-migratable enforces the
///   rule on the client instead of hoping for it.
final class KeychainCredentialStore: CredentialStore {

    private let service: String
    private let account: String

    init(
        service: String = "com.anvarlab.phleet.device-credential",
        account: String = "device"
    ) {
        self.service = service
        self.account = account
    }

    /// The query identifying this app's one credential item.
    static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// The attributes a write uses.
    ///
    /// Exposed so the accessibility attribute is assertable without touching a real keychain —
    /// the one thing about this file that is a security decision rather than plumbing.
    static func writeAttributes(
        service: String,
        account: String,
        payload: Data
    ) -> [String: Any] {
        var attributes = baseQuery(service: service, account: account)
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return attributes
    }

    func load() throws -> DeviceCredential? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw CredentialStoreError.malformedPayload
            }
            do {
                return try JSONDecoder().decode(DeviceCredential.self, from: data)
            } catch {
                throw CredentialStoreError.malformedPayload
            }
        case errSecItemNotFound:
            // A fresh install. Not a failure, and explicitly distinct from the case below.
            return nil
        default:
            // Fail closed: treated as unenrolled and surfaced as its own message, and the item
            // is **not** deleted. A read that fails because the device is locked must not
            // destroy a working credential.
            throw CredentialStoreError.unavailable(status: status)
        }
    }

    func save(_ credential: DeviceCredential) throws {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(credential)
        } catch {
            throw CredentialStoreError.malformedPayload
        }

        // Delete-then-add rather than update, so a rotated secret replaces the item wholesale
        // and cannot leave a half-updated one behind.
        let deleteStatus = SecItemDelete(
            Self.baseQuery(service: service, account: account) as CFDictionary
        )
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw CredentialStoreError.writeFailed(status: deleteStatus)
        }

        let attributes = Self.writeAttributes(
            service: service,
            account: account,
            payload: payload
        )
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.writeFailed(status: addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(
            Self.baseQuery(service: service, account: account) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.writeFailed(status: status)
        }
    }
}
