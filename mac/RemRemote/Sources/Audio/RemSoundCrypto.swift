import Foundation
import CryptoKit
import CommonCrypto

/// RemSound's audio encryption: AES-256-GCM with a key derived from the shared password
/// via PBKDF2-HMAC-SHA256 (100 000 iterations — a cross-implementation contract).
/// Sealed packet layout: nonce(12) ‖ tag(16) ‖ ciphertext.
enum RemSoundCrypto {
    static let keySalt = "RemSound.v1.audio-key"
    static let fingerprintSalt = "RemSound.v1.fingerprint"
    static let iterations: UInt32 = 100_000
    static let overheadBytes = 28

    static func deriveKey(password: String) -> SymmetricKey {
        SymmetricKey(data: pbkdf2(password: password, salt: keySalt, length: 32))
    }

    static func fingerprint(password: String) -> Data {
        pbkdf2(password: password, salt: fingerprintSalt, length: 8)
    }

    private static func pbkdf2(password: String, salt: String, length: Int) -> Data {
        var output = Data(count: length)
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt.utf8)
        output.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                buffer.bindMemory(to: UInt8.self).baseAddress, length
            )
        }
        return output
    }

    static func seal(_ plaintext: Data, key: SymmetricKey) -> Data? {
        guard let sealed = try? AES.GCM.seal(plaintext, using: key) else { return nil }
        var packet = Data(capacity: overheadBytes + plaintext.count)
        packet.append(contentsOf: sealed.nonce)
        packet.append(sealed.tag)
        packet.append(sealed.ciphertext)
        return packet
    }

    static func open(_ packet: Data, key: SymmetricKey) -> Data? {
        guard packet.count >= overheadBytes else { return nil }
        let start = packet.startIndex
        let nonce = packet[start..<(start + 12)]
        let tag = packet[(start + 12)..<(start + 28)]
        let ciphertext = packet[(start + 28)...]
        guard let gcmNonce = try? AES.GCM.Nonce(data: nonce),
              let box = try? AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag) else {
            return nil
        }
        return try? AES.GCM.open(box, using: key)
    }
}
