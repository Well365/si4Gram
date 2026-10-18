import Clibsodium
import Foundation

/// Relay content encryption (PLAN.md 3.48.2): XChaCha20-Poly1305 IETF, blob = `nonce(24) || ciphertext`,
/// AAD = `"secutg/relay/v1"` (constant, not the item id — the relay never learns anything content-specific).
///
/// The key `K` is random per message and travels only inside the `L1:` reference's `k` field (itself protected
/// by whatever encrypts that chat, or left in the open in an unpaired chat exactly like the rest of the message
/// — PLAN.md 3.48.0 rule 4: `L1:` takes the chat's existing path, nothing new). The relay only ever sees the
/// opaque blob and reports `application/octet-stream`; this type has no notion of upload/MIME at all.
public enum RelayCrypto {
    public static let keyBytes = 32
    public static let nonceBytes = 24
    private static let aad = [UInt8]("secutg/relay/v1".utf8)
    private static let tagBytes = Int(crypto_aead_xchacha20poly1305_ietf_abytes())

    public static func generateKey() -> [UInt8] {
        return SecutgSodium.randomBytes(keyBytes)
    }

    /// `nonce(24) || ciphertext` under `key`, random nonce.
    public static func seal(_ data: Data, key: [UInt8]) throws -> Data {
        guard key.count == keyBytes else { throw SecutgCryptoError.invalidKey }
        let nonce = SecutgSodium.randomBytes(nonceBytes)
        return try seal(data, key: key, nonce: nonce)
    }

    /// Decrypts a `nonce || ciphertext` blob; nil for anything truncated, tampered with, or under the wrong key.
    /// `>=`, not `>`: an empty plaintext is a valid relay content (PLAN.md 3.48.6's "empty plaintext" vector) and
    /// produces a blob of exactly `nonceBytes + tagBytes` with nothing else — `>` would reject that blob outright.
    public static func open(_ blob: Data, key: [UInt8]) -> Data? {
        guard key.count == keyBytes, blob.count >= nonceBytes + tagBytes else { return nil }
        SecutgSodium.ensureReady()
        let bytes = [UInt8](blob)
        let nonce = Array(bytes[0..<nonceBytes])
        let ciphertext = Array(bytes[nonceBytes...])
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count - tagBytes)
        var ptLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_decrypt(
            &plaintext, &ptLen, nil, ciphertext, UInt64(ciphertext.count), aad, UInt64(aad.count), nonce, key)
        guard rc == 0 else { return nil }
        return Data(plaintext[0..<Int(ptLen)])
    }

    /// Exposed only for deterministic testing (a fixed nonce must never be reused in production — `seal(_:key:)`
    /// is the only entry point the app layer should ever call).
    static func seal(_ data: Data, key: [UInt8], nonce: [UInt8]) throws -> Data {
        guard key.count == keyBytes, nonce.count == nonceBytes else { throw SecutgCryptoError.invalidKey }
        SecutgSodium.ensureReady()
        let plaintext = [UInt8](data)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count + tagBytes)
        var ctLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_encrypt(
            &ciphertext, &ctLen, plaintext, UInt64(plaintext.count), aad, UInt64(aad.count), nil, nonce, key)
        guard rc == 0 else { throw SecutgCryptoError.sodiumFailure("relay seal failed") }
        return Data(nonce + ciphertext[0..<Int(ctLen)])
    }
}
