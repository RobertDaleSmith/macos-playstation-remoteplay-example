import Foundation
import Security

/// Persists the PSN account and linked consoles in the app's keychain. The registration keys
/// grant control of a console to anyone on its LAN, so they don't belong in UserDefaults.
final class RPStore {
    struct Contents: Codable, Equatable {
        var account: RPAccount?
        var hosts: [RPRegisteredHost] = []
    }

    private let service: String
    private let accountName = "remoteplay"

    init(service: String = "com.example.psremoteplay.credentials") {
        self.service = service
    }

    func load() -> Contents {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
            let contents = try? JSONDecoder().decode(Contents.self, from: data)
        else {
            return Contents()
        }
        return contents
    }

    @discardableResult
    func save(_ contents: Contents) -> Bool {
        guard let data = try? JSONEncoder().encode(contents) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            rpLogger.error("Keychain save failed: \(status)")
            return false
        }
        return true
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
