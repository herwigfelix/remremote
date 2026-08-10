import Foundation
import Security

/// Minimal wrapper around the macOS keychain for one generic-password item per saved
/// computer. The item's data is a JSON blob holding the connection secrets.
enum KeychainStore {
    private static let service = "org.remremote.mac.computers"

    struct Secrets: Codable {
        var key: String
        var encryptionPassword: String?
    }

    enum KeychainError: Error {
        case status(OSStatus)
    }

    static func save(_ secrets: Secrets, for id: UUID) throws {
        let data = try JSONEncoder().encode(secrets)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "remremote computer"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func load(for id: UUID) -> Secrets? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let secrets = try? JSONDecoder().decode(Secrets.self, from: data) else {
            return nil
        }
        return secrets
    }

    static func delete(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
