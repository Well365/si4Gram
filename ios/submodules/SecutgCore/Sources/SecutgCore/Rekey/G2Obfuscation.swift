import Clibsodium
import Foundation

/// PLAN.md 3.35.8: the shared-secret wrapper around a `G2` payload (2026-09-20 用户定).
///
/// # This is obfuscation. It is NOT encryption, and nothing may present it as encryption.
///
/// The passphrase below ships inside every client — it has to, or two secuTG builds could not read each
/// other's broadcasts. That means it is on every device that has the app, and `strings` on an APK or an IPA
/// prints it. Anyone who wants the key can have it in about five minutes, Telegram's servers included.
///
/// What it does buy, which is real but small:
///
/// - a member of the group running a stock Telegram client sees an opaque blob instead of something that
///   announces itself as `secutg://key?…`;
/// - server-side pattern scanning for that prefix finds nothing;
/// - the cost of reading a group's key goes from zero effort to a deliberate act.
///
/// What it does not buy, and what the UI must never imply it buys: confidentiality against the platform.
/// CLAUDE.md's amended hard constraint stands in full — 自动配对模式对平台不提供保密性. The mode that does is
/// 当面配对, which never puts a key on the wire at all.
///
/// Named `obfuscate` / `deobfuscate` for that reason. A reviewer who later finds `encrypt` here, or a status
/// line that says 「已加密」 because this ran, should treat it as a bug.
public enum G2Obfuscation {
    private static let passphrase = "io9Wtw18YvuD2dB"
    /// XChaCha20-Poly1305: the same primitive as `E1`, per CLAUDE.md's libsodium-only constraint.
    private static let nonceBytes = 24
    private static let keyBytes = 32
    private static let tagBytes = Int(crypto_aead_xchacha20poly1305_ietf_abytes())

    /// The passphrase is a fixed, public constant, so a slow password hash would be theatre: there is no
    /// guessing to slow down when the answer ships with the binary. A plain generic hash to 32 bytes is what
    /// this is — a deterministic way for every port to turn one shared string into the same key.
    private static func obfuscationKey() -> [UInt8]? {
        SecutgSodium.ensureReady()
        let input = [UInt8](passphrase.utf8)
        var out = [UInt8](repeating: 0, count: keyBytes)
        guard crypto_generichash(&out, keyBytes, input, UInt64(input.count), nil, 0) == 0 else { return nil }
        return out
    }

    /// Wraps a `secutg://key?…` payload. Returns `nonce || ciphertext`. `nonce` is TEST / VECTOR USE ONLY
    /// (PLAN.md 3.38.2's `GP1` vectors fix it); anything not given is random.
    public static func obfuscate(_ payload: String, nonce fixedNonce: [UInt8]? = nil) -> [UInt8]? {
        guard let key = obfuscationKey() else { return nil }
        if let fixedNonce, fixedNonce.count != nonceBytes { return nil }
        let plaintext = [UInt8](payload.utf8)
        let nonce = fixedNonce ?? SecutgSodium.randomBytes(nonceBytes)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count + tagBytes)
        var ctLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_encrypt(
            &ciphertext, &ctLen, plaintext, UInt64(plaintext.count), nil, 0, nil, nonce, key)
        guard rc == 0 else { return nil }
        return nonce + ciphertext[0..<Int(ctLen)]
    }

    /// Unwraps it. nil for anything this build cannot open — a broadcast from a different fork, a truncated
    /// one, or a tampered one (the Poly1305 tag is checked, so a flipped bit fails here rather than turning
    /// into a wrong key).
    public static func deobfuscate(_ bytes: [UInt8]) -> String? {
        guard bytes.count > nonceBytes + tagBytes, let key = obfuscationKey() else { return nil }
        let nonce = Array(bytes[0..<nonceBytes])
        let ciphertext = Array(bytes[nonceBytes...])
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count - tagBytes)
        var ptLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_decrypt(
            &plaintext, &ptLen, nil, ciphertext, UInt64(ciphertext.count), nil, 0, nonce, key)
        guard rc == 0 else { return nil }
        return String(bytes: plaintext[0..<Int(ptLen)], encoding: .utf8)
    }
}
