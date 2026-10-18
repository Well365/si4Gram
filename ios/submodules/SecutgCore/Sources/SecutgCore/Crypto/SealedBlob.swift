import Clibsodium
import Foundation

/// Local-storage envelope for the keyring file: `nonce(24) || xchacha20poly1305(json)` under a device key that
/// lives in the Keychain. Not a wire format; never leaves the device.
public enum SealedBlob {
    public static let keyBytes = 32
    private static let nonceBytes = 24
    private static let tagBytes = Int(crypto_aead_xchacha20poly1305_ietf_abytes())

    public static func generateKey() -> [UInt8] {
        return SecutgSodium.randomBytes(keyBytes)
    }

    public static func seal(_ data: Data, key: [UInt8]) throws -> Data {
        guard key.count == keyBytes else { throw SecutgCryptoError.invalidKey }
        SecutgSodium.ensureReady()
        let plaintext = [UInt8](data)
        let nonce = SecutgSodium.randomBytes(nonceBytes)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count + tagBytes)
        var ctLen: UInt64 = 0
        guard crypto_aead_xchacha20poly1305_ietf_encrypt(&ciphertext, &ctLen, plaintext, UInt64(plaintext.count), nil, 0, nil, nonce, key) == 0 else {
            throw SecutgCryptoError.sodiumFailure("seal failed")
        }
        return Data(nonce + ciphertext[0..<Int(ctLen)])
    }

    /// nil when the blob is truncated, tampered with, or sealed under another key.
    public static func open(_ blob: Data, key: [UInt8]) -> Data? {
        guard key.count == keyBytes, blob.count > nonceBytes + tagBytes else { return nil }
        SecutgSodium.ensureReady()
        let bytes = [UInt8](blob)
        let nonce = Array(bytes[0..<nonceBytes])
        let ciphertext = Array(bytes[nonceBytes...])
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count - tagBytes)
        var ptLen: UInt64 = 0
        guard crypto_aead_xchacha20poly1305_ietf_decrypt(&plaintext, &ptLen, nil, ciphertext, UInt64(ciphertext.count), nil, 0, nonce, key) == 0 else { return nil }
        return Data(plaintext[0..<Int(ptLen)])
    }
}
