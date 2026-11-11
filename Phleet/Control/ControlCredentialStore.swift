import Foundation
import Security

/// Where the control-plane credential lives.
///
/// The same three outcomes as `CredentialStore`, for the same reason: "there is none" is an
/// ordinary answer, and every other failure must stay distinguishable from it so a read that
/// fails while the device is locked is never mistaken for a fresh install.
protocol ControlCredentialStore {
    func load() throws -> ControlCredential?
    func save(_ credential: ControlCredential) throws
    func delete() throws
}

/// A store that holds a credential for the lifetime of the process and nothing longer.
///
/// Used by the tests and by the launch-argument-driven double. Not a fallback for the Keychain.
final class InMemoryControlCredentialStore: ControlCredentialStore {

    private var credential: ControlCredential?

    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(credential: ControlCredential? = nil) {
        self.credential = credential
    }

    func load() throws -> ControlCredential? { credential }

    func save(_ credential: ControlCredential) throws {
        self.credential = credential
        saveCount += 1
    }

    func delete() throws {
        credential = nil
        deleteCount += 1
    }
}

/// The control-plane credential at rest.
///
/// A second Keychain item, separate from the device credential, so removing one never touches
/// the other. The query and the write attributes come from `KeychainCredentialStore`, which keeps
/// the one security decision here — `AfterFirstUnlockThisDeviceOnly` — in a single place: this
/// item is likewise excluded from iCloud Keychain and from backups, so a restore to a new device
/// arrives without an operator token on it.
final class KeychainControlCredentialStore: ControlCredentialStore {

    static let defaultService = "com.anvarlab.phleet.control-credential"
    static let defaultAccount = "orchestrator"

    private let service: String
    private let account: String

    init(
        service: String = KeychainControlCredentialStore.defaultService,
        account: String = KeychainControlCredentialStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> ControlCredential? {
        var query = KeychainCredentialStore.baseQuery(service: service, account: account)
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
                return try JSONDecoder().decode(ControlCredential.self, from: data)
            } catch {
                throw CredentialStoreError.malformedPayload
            }
        case errSecItemNotFound:
            return nil
        default:
            // Fail closed, and do not delete: see `KeychainCredentialStore.load()`.
            throw CredentialStoreError.unavailable(status: status)
        }
    }

    func save(_ credential: ControlCredential) throws {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(credential)
        } catch {
            throw CredentialStoreError.malformedPayload
        }

        let deleteStatus = SecItemDelete(
            KeychainCredentialStore.baseQuery(service: service, account: account) as CFDictionary
        )
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw CredentialStoreError.writeFailed(status: deleteStatus)
        }

        let attributes = KeychainCredentialStore.writeAttributes(
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
            KeychainCredentialStore.baseQuery(service: service, account: account) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.writeFailed(status: status)
        }
    }
}
