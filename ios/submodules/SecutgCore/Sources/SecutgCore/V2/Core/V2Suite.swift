import Clibsodium
import Foundation

/// v2 crypto suite (v1.4 section 8, section 13): the primitives every v2 module builds on. Ported
/// from the Web reference implementation (`src/secutg/v2/suite.ts`) and cross-checked against the
/// Android port (`secutg-core/src/main/java/org/telegram/secutg/v2/Suite.java`); keep all three in
/// sync.
///
/// Calls `Clibsodium`'s raw C API directly, the same convention every other file in this module
/// already uses (see `Crypto/E1Codec.swift`, `Rekey/Rekey.swift`) — never the higher-level
/// `swift-sodium` wrapper, which this package does not even declare as a dependency.
public enum V2Suite {
    // MARK: sizes (v1.4 section 7/8/13) — named here so a call site reads as a check against the spec.
    public static let x25519PkBytes = 32
    public static let x25519SkBytes = 32
    public static let ed25519PkBytes = 32
    public static let ed25519SkBytes = 64 // libsodium's Ed25519 secret key is seed||pk, 64 bytes
    public static let signatureBytes = 64
    public static let digestBytes = 32 // SHA-256
    public static let hmacBytes = 32
    public static let xchacha20NonceBytes = 24
    public static let xchacha20KeyBytes = 32
    private static let aeadABytes = Int(crypto_aead_xchacha20poly1305_ietf_abytes())
    private static let boxSealBytes = Int(crypto_box_sealbytes())

    // SECUTG-HOOK (fix E1): `Codable` so an in-flight `V2Processor.PendingTxn` — whose
    // `ownEphemeral` is exactly this type — can round-trip through `V2PersistedState`'s snapshot
    // the same way every other byte-array field in this codebase's `Codable` snapshots already
    // does (plain `[UInt8]` arrays, synthesized field-by-field — see `V2Binding`'s own snapshot
    // doc comment for why that is already JSON-safe with no extra encoding step needed).
    public struct KeyPair: Codable {
        public let publicKey: [UInt8]
        public let secretKey: [UInt8]

        public init(publicKey: [UInt8], secretKey: [UInt8]) {
            self.publicKey = publicKey
            self.secretKey = secretKey
        }
    }

    public static func generateX25519() -> KeyPair {
        SecutgSodium.ensureReady()
        var pk = [UInt8](repeating: 0, count: x25519PkBytes)
        var sk = [UInt8](repeating: 0, count: x25519SkBytes)
        guard crypto_box_keypair(&pk, &sk) == 0 else {
            fatalError("[secutg v2] X25519 keypair generation failed")
        }
        return KeyPair(publicKey: pk, secretKey: sk)
    }

    public static func generateEd25519() -> KeyPair {
        SecutgSodium.ensureReady()
        var pk = [UInt8](repeating: 0, count: ed25519PkBytes)
        var sk = [UInt8](repeating: 0, count: ed25519SkBytes)
        guard crypto_sign_keypair(&pk, &sk) == 0 else {
            fatalError("[secutg v2] Ed25519 keypair generation failed")
        }
        return KeyPair(publicKey: pk, secretKey: sk)
    }

    /// libsodium's Ed25519 secret key is `seed || pk` (64 bytes); the 32-byte seed alone regenerates both halves.
    /// PLAN.md 3.39.12: a V2Q carries the new device's identity as its seed, and the scanner rebuilds the pair.
    public static let ed25519SeedBytes = 32

    public static func ed25519Seed(ofSecretKey secretKey: [UInt8]) -> [UInt8]? {
        guard secretKey.count == ed25519SkBytes else { return nil }
        return Array(secretKey.prefix(ed25519SeedBytes))
    }

    public static func ed25519KeyPair(seed: [UInt8]) -> KeyPair? {
        guard seed.count == ed25519SeedBytes else { return nil }
        SecutgSodium.ensureReady()
        var pk = [UInt8](repeating: 0, count: ed25519PkBytes)
        var sk = [UInt8](repeating: 0, count: ed25519SkBytes)
        guard crypto_sign_seed_keypair(&pk, &sk, seed) == 0 else { return nil }
        return KeyPair(publicKey: pk, secretKey: sk)
    }

    /// The X25519 public key of a secret key (`crypto_scalarmult_base`) — PLAN.md 3.39.12: a V2Q carries the new
    /// device's encapsulation secret only.
    public static func x25519PublicKey(secretKey: [UInt8]) -> [UInt8]? {
        guard secretKey.count == x25519SkBytes else { return nil }
        SecutgSodium.ensureReady()
        var pk = [UInt8](repeating: 0, count: x25519PkBytes)
        guard crypto_scalarmult_base(&pk, secretKey) == 0 else { return nil }
        return pk
    }

    /// `X25519(ephemeral_sk, peer_ephemeral_pk)` (v1.4 section 8). `nil` on the documented low-order
    /// point rejection — `crypto_scalarmult` returns nonzero rather than throwing, so that return
    /// code IS the abort signal here, matching Android's own `DiffieHellman.Native.cryptoScalarMult`
    /// boolean-return behavior (a real, documented difference from the Web reference's
    /// libsodium-wrappers-sumo binding, which throws instead).
    public static func x25519(secretKey: [UInt8], peerPublicKey: [UInt8]) -> [UInt8]? {
        guard secretKey.count == x25519SkBytes, peerPublicKey.count == x25519PkBytes else { return nil }
        var shared = [UInt8](repeating: 0, count: x25519PkBytes)
        guard crypto_scalarmult(&shared, secretKey, peerPublicKey) == 0 else { return nil }
        return shared
    }

    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        SecutgSodium.ensureReady()
        var out = [UInt8](repeating: 0, count: digestBytes)
        guard crypto_hash_sha256(&out, bytes, UInt64(bytes.count)) == 0 else {
            fatalError("[secutg v2] sha256 failed")
        }
        return out
    }

    public static func sign(secretKey: [UInt8], message: [UInt8]) -> [UInt8] {
        var sig = [UInt8](repeating: 0, count: signatureBytes)
        guard crypto_sign_detached(&sig, nil, message, UInt64(message.count), secretKey) == 0 else {
            fatalError("[secutg v2] sign failed")
        }
        return sig
    }

    public static func verify(publicKey: [UInt8], message: [UInt8], signature: [UInt8]) -> Bool {
        guard publicKey.count == ed25519PkBytes, signature.count == signatureBytes else { return false }
        return crypto_sign_verify_detached(signature, message, UInt64(message.count), publicKey) == 0
    }

    /// HMAC-SHA256 for a key of EXACTLY 32 BYTES — see the Web reference's own module doc for why
    /// this restriction is enforced rather than left to whichever caller violates it first.
    private static func hmacSha256(key32: [UInt8], data: [UInt8]) -> [UInt8] {
        precondition(key32.count == hmacBytes, "[secutg v2] hmacSha256 requires an exactly \(hmacBytes)-byte key, got \(key32.count)")
        var out = [UInt8](repeating: 0, count: hmacBytes)
        guard crypto_auth_hmacsha256(&out, data, UInt64(data.count), key32) == 0 else {
            fatalError("[secutg v2] hmacSha256 failed")
        }
        return out
    }

    /// HKDF-Extract (RFC 5869), via libsodium's own `crypto_kdf_hkdf_sha256_extract` — the real
    /// primitive, not a hand-rolled HMAC chain (unlike the Android port, whose LazySodium binding at
    /// the time exposed no HKDF entry point at all). `salt` is always `th` or a K2 backup salt (32
    /// bytes by construction), never an arbitrary-length secret.
    public static func hkdfExtract(salt32: [UInt8], ikm: [UInt8]) -> [UInt8] {
        var prk = [UInt8](repeating: 0, count: hmacBytes)
        guard crypto_kdf_hkdf_sha256_extract(&prk, salt32, salt32.count, ikm, ikm.count) == 0 else {
            fatalError("[secutg v2] hkdfExtract failed")
        }
        return prk
    }

    /// HKDF-Expand (RFC 5869), via libsodium's own `crypto_kdf_hkdf_sha256_expand`.
    public static func hkdfExpand(prk: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        var okm = [UInt8](repeating: 0, count: length)
        guard crypto_kdf_hkdf_sha256_expand(&okm, length, info, info.count, prk) == 0 else {
            fatalError("[secutg v2] hkdfExpand failed")
        }
        return okm
    }

    /// `HMAC(kc, "A" || th)` and friends (v1.4 section 8): a thin, named alias so call sites read
    /// like the spec.
    public static func hmac(key32: [UInt8], data: [UInt8]) -> [UInt8] {
        return hmacSha256(key32: key32, data: data)
    }

    /// Constant-time comparison for MACs and derived confirmation bytes (v1.4 section 8: "use
    /// constant time comparison for MACs"), via libsodium's own `sodium_memcmp` — unlike the Android
    /// port (whose LazySodium version exposed no memcmp/compare binding, forcing a hand-written
    /// XOR-accumulate fallback), this Clibsodium build exposes `sodium_memcmp` directly, so no
    /// self-implemented comparison is needed here at all.
    public static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return sodium_memcmp(a, b, a.count) == 0
    }

    /// XChaCha20-Poly1305-IETF AEAD (v1.4 section 8's suite, and section 15's E2 data key).
    public static func aeadEncrypt(key: [UInt8], nonce: [UInt8], plaintext: [UInt8], aad: [UInt8]?) -> [UInt8] {
        precondition(key.count == xchacha20KeyBytes && nonce.count == xchacha20NonceBytes, "[secutg v2] aeadEncrypt: bad key or nonce length")
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count + aeadABytes)
        var ctLen: UInt64 = 0
        let aadBytes = aad ?? []
        let rc = crypto_aead_xchacha20poly1305_ietf_encrypt(
            &ciphertext, &ctLen, plaintext, UInt64(plaintext.count),
            aad == nil ? nil : aadBytes, UInt64(aadBytes.count), nil, nonce, key
        )
        guard rc == 0 else { fatalError("[secutg v2] aeadEncrypt failed") }
        return Array(ciphertext[0..<Int(ctLen)])
    }

    public static func aeadDecrypt(key: [UInt8], nonce: [UInt8], ciphertext: [UInt8], aad: [UInt8]?) -> [UInt8]? {
        guard key.count == xchacha20KeyBytes, nonce.count == xchacha20NonceBytes else { return nil }
        guard ciphertext.count >= aeadABytes else { return nil }
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count - aeadABytes)
        var ptLen: UInt64 = 0
        let aadBytes = aad ?? []
        let rc = crypto_aead_xchacha20poly1305_ietf_decrypt(
            &plaintext, &ptLen, nil, ciphertext, UInt64(ciphertext.count),
            aad == nil ? nil : aadBytes, UInt64(aadBytes.count), nonce, key
        )
        guard rc == 0 else { return nil }
        return Array(plaintext[0..<Int(ptLen)])
    }

    public static func randomBytes(_ length: Int) -> [UInt8] {
        return SecutgSodium.randomBytes(length)
    }

    /// Sealed box: `crypto_box_seal` (v1.4 section 13's replacement for HPKE — PLAN.md 3.36.2).
    /// Anonymous sender (a fresh ephemeral X25519 key per call, generated internally by libsodium);
    /// callers add their own Ed25519 signature around the sealed bytes for sender authentication,
    /// which sealed box does not provide on its own.
    public static func sealFor(recipientX25519Pk: [UInt8], bytes: [UInt8]) -> [UInt8] {
        var sealed = [UInt8](repeating: 0, count: bytes.count + boxSealBytes)
        guard crypto_box_seal(&sealed, bytes, UInt64(bytes.count), recipientX25519Pk) == 0 else {
            fatalError("[secutg v2] sealFor failed")
        }
        return sealed
    }

    public static func openSealed(recipientPk: [UInt8], recipientSk: [UInt8], sealed: [UInt8]) -> [UInt8]? {
        guard sealed.count >= boxSealBytes else { return nil }
        var out = [UInt8](repeating: 0, count: sealed.count - boxSealBytes)
        let rc = crypto_box_seal_open(&out, sealed, UInt64(sealed.count), recipientPk, recipientSk)
        return rc == 0 ? out : nil
    }

    public static func utf8(_ text: String) -> [UInt8] {
        return Array(text.utf8)
    }

    /// `nil` on invalid UTF-8 — matches the Web reference's fatal `TextDecoder` and Android's own
    /// `fromUtf8`, never silently substituting the replacement character.
    public static func fromUtf8(_ bytes: [UInt8]) -> String? {
        return String(bytes: bytes, encoding: .utf8)
    }

    public static func concatBytes(_ parts: [UInt8]...) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts { out.append(contentsOf: part) }
        return out
    }
}
