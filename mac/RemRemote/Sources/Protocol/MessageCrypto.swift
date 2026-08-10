import Foundation
import CryptoKit
import CryptoSwift

/// The TeleNVDA/remremote optional message layer: AES-256-GCM over individual JSON
/// messages, keyed with SHA-256 of the pre-shared encryption password. The Windows side
/// (PyCryptodome) uses 16-byte nonces, which CryptoKit cannot process, hence CryptoSwift.
///
/// Wire form: {"type": "encrypted", "nonce": b64, "data": b64, "tag": b64}
enum MessageCrypto {
    /// Message types that are never encrypted (they are meaningful to the relay server).
    static let excludedTypes: Set<String> = [
        "join", "protocol_version", "encrypted", "channel_joined", "motd",
        "nvda_not_connected", "client_left", "ping", "error", "client_joined",
        "generate_key",
    ]

    static func key(fromPassword password: String) -> [UInt8] {
        Array(SHA256.hash(data: Data(password.utf8)))
    }

    static func encrypt(_ plaintext: Data, key: [UInt8]) throws -> [String: Any] {
        var nonce = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else {
            throw CocoaError(.coderInvalidValue)
        }
        let gcm = GCM(iv: nonce, mode: .detached)
        let aes = try AES(key: key, blockMode: gcm, padding: .noPadding)
        let ciphertext = try aes.encrypt(Array(plaintext))
        guard let tag = gcm.authenticationTag else { throw CocoaError(.coderInvalidValue) }
        return [
            "type": "encrypted",
            "nonce": Data(nonce).base64EncodedString(),
            "data": Data(ciphertext).base64EncodedString(),
            "tag": Data(tag).base64EncodedString(),
        ]
    }

    static func decrypt(nonce: String, data: String, tag: String, key: [UInt8]) -> Data? {
        guard let nonceData = Data(base64Encoded: nonce),
              let cipherData = Data(base64Encoded: data),
              let tagData = Data(base64Encoded: tag) else { return nil }
        do {
            let gcm = GCM(iv: Array(nonceData), authenticationTag: Array(tagData), mode: .detached)
            let aes = try AES(key: key, blockMode: gcm, padding: .noPadding)
            let plaintext = try aes.decrypt(Array(cipherData))
            return Data(plaintext)
        } catch {
            return nil
        }
    }
}
