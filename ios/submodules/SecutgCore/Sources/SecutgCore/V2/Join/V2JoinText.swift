import Foundation

/// PLAN.md 3.39.2 / 3.39.13: the V2Q text — one 1v1 chat's binding, and this device's identity in it, handed to the
/// user's OWN other device by QR (the "clone" of 3.39.13; the text shell is unchanged from 3.39.2).
///
///   V2Q:<transfer code, 32 Crockford base32 chars, no separators>:<nonce_b64url>:<ct_b64url>
///
/// This file is the crypto-free half (what a scanner needs: "is this frame a V2Q at all, and is it well-formed"),
/// the same split `QuickShare` draws for K1Q. Decrypting and validating the payload is `V2Join`.
///
/// Parsing is strict on purpose (3.14.1's rule, carried over): the code is machine-written into the QR, so anything
/// but 32 canonical upper-case characters is damage, never a typo to forgive; the nonce is exactly 24 bytes (32
/// base64url chars); the ciphertext at least the 16-byte tag. Surrounding whitespace is trimmed, as it is for a
/// pasted K1/K1Q. Mirrors Web A `src/secutg/v2/join/text.ts`.
public enum V2JoinText {
    public static let prefix = "V2Q:"
    /// `blake2b(32, "tg-v2-join-v1" || 20-byte code)` — 3.14's construction with its own context (3.39.2).
    public static let kdfContext = "tg-v2-join-v1"
    /// PLAN.md 3.39.13: the clone payload's constant AAD (`binding_id` is NOT appended — see `V2Join`'s doc).
    public static let aad = "secutg/v2clone/v1"
    /// 3.39.12's AAD. Only ever used to RECOGNISE an add_device code from a device that was not updated
    /// (`old_version`); nothing is built under it any more.
    public static let legacyAad = "secutg/v2join/v1"
    /// 3.39.2: `expires_ms` = the moment the code was shown + 10 minutes.
    public static let ttlMs: Int64 = 10 * 60 * 1000
    /// 3.39.2: a scanner accepts a code up to 2 minutes past its `expires_ms` (clock skew between two devices).
    public static let expiryGraceMs: Int64 = 2 * 60 * 1000

    private static let codeChars = 32
    private static let codeAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let base64UrlAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    /// 24 bytes = exactly 32 base64url characters
    private static let nonceChars = 32
    /// at least the 16-byte Poly1305 tag = 22 characters
    private static let minCiphertextChars = 22

    public struct Parsed: Equatable {
        /// canonical: 32 upper-case Crockford characters, no separators
        public let code: String
        /// base64url, 24 bytes
        public let nonce: String
        /// base64url
        public let ciphertext: String
    }

    /// Cheap prefix test — what the camera scanner uses to decide a frame is worth stopping for.
    public static func isV2JoinText(_ text: String) -> Bool {
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
    }

    /// The transfer code as it goes into the QR: separators dropped, upper case. nil unless exactly 32 canonical
    /// characters remain (no I/L/O/U leniency here — that is for humans typing, not for QR codes).
    public static func canonicalCode(_ code: String) -> String? {
        let plain = String(code.filter { $0 != "-" && !$0.isWhitespace }).uppercased()
        return isCanonicalCode(plain) ? plain : nil
    }

    /// Syntax only, strict (see module doc). nil = `malformed`.
    public static func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let parts = trimmed.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let code = parts[0], nonce = parts[1], ciphertext = parts[2]
        guard isCanonicalCode(code), isNonce(nonce), isCiphertext(ciphertext) else { return nil }
        return Parsed(code: code, nonce: nonce, ciphertext: ciphertext)
    }

    /// Assembles the text from already-encoded parts; nil on a part `parse` would refuse.
    public static func build(code: String, nonceB64: String, ciphertextB64: String) -> String? {
        guard let canonical = canonicalCode(code), isNonce(nonceB64), isCiphertext(ciphertextB64) else { return nil }
        return prefix + canonical + ":" + nonceB64 + ":" + ciphertextB64
    }

    private static func isCanonicalCode(_ code: String) -> Bool {
        return code.count == codeChars && code.allSatisfy { codeAlphabet.contains($0) }
    }

    private static func isNonce(_ text: String) -> Bool {
        return text.count == nonceChars && text.allSatisfy { base64UrlAlphabet.contains($0) }
    }

    private static func isCiphertext(_ text: String) -> Bool {
        return text.count >= minCiphertextChars && text.allSatisfy { base64UrlAlphabet.contains($0) }
    }
}
