import Foundation
import Security

struct LiveChatKeychainError: Error {
    let status: OSStatus
    var message: String { "无法访问手机 Keychain（\(status)），请解锁手机后重试。" }
}

@MainActor
struct LiveChatCredentialStore {
    let service: String

    func load(account: String) throws -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw LiveChatKeychainError(status: status) }
        return value
    }

    func save(_ key: String, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query(account: account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account: account)
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw LiveChatKeychainError(status: added) }
        } else if status != errSecSuccess { throw LiveChatKeychainError(status: status) }
    }

    func remove(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LiveChatKeychainError(status: status) }
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
}
