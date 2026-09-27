import Foundation
import Security

protocol FrezAccessKeyStoring {
    func read() throws -> String?
    func save(_ key: String) throws
    func delete() throws
}

/// Personal credentials never enter UserDefaults, iCloud, logs, or the web view.
struct FrezAccessKeyStore: FrezAccessKeyStoring {
    private let service: String

    init(service: String = "com.gripgains.companion.frez") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "personal-access-key"]
    }

    func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw FrezError.keychain
        }
        return key
    }

    func save(_ key: String) throws {
        let key = try FrezCoefficientClient.validatedKey(key)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw FrezError.keychain }
        } else if status != errSecSuccess {
            throw FrezError.keychain
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw FrezError.keychain }
    }
}
