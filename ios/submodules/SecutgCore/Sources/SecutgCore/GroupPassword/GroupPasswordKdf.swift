import Clibsodium
import Foundation

/// PLAN.md 3.38 群密码 — protocol core, ported from Web `src/secutg/grouppw/`. Pure functions only: nothing in
/// this folder touches G2, the keyring, storage or UI.
///
/// Cross-client contract (Web `grouppw/index.ts` is authoritative; `vectors-grouppw.json` is the oracle):
///
/// - KDF: `KEK = crypto_pwhash(32, UTF-8(NFC(password)), salt(16), ops, mem, ALG_ARGON2ID13)`. Defaults ops=2,
///   mem=67108864 (INTERACTIVE). Accepted on send AND receive: 1...10 ops, 8 MiB...256 MiB mem, mem % 1024 == 0;
///   anything else is `params_out_of_range`, checked BEFORE deriving (DoS guard).
/// - AEAD: XChaCha20-Poly1305-IETF under the KEK; wrap = nonce(24) ‖ ciphertext(32) ‖ tag(16).
///   AAD(current) = "secutg/grouppw/v1" ‖ groupId; AAD(hist[i]) = AAD(current) ‖ "\0hist\0" ‖ decimal(i).
/// - History: oldest → newest, drop copies of current, keep first of repeats, then the newest 16.
/// - Password: 6...256 Unicode scalars after NFC.
public enum GroupPassword {
    public static let kdfArgon2id13 = "argon2id13"
    public static let kekBytes = 32
    public static let saltBytes = 16

    /// libsodium's OPSLIMIT_INTERACTIVE / MEMLIMIT_INTERACTIVE, as plain numbers so every port matches.
    public static let defaultOps = 2
    public static let defaultMem = 67_108_864

    /// Upper bounds are the DoS guard (params arrive from the network); lower bounds stop a build from
    /// emitting a payload that is cheap to guess offline. `mem` must be whole KiB: libsodium hands Argon2
    /// `mem / 1024`, so a port that rounded differently would derive a different KEK.
    public static let opsMin = 1
    public static let opsMax = 10
    public static let memMin = 8 * 1024 * 1024
    public static let memMax = 256 * 1024 * 1024

    public enum Failure: Error, Equatable {
        case passwordRejected(PasswordCheck)
        case missingGroupId
        case paramsOutOfRange
        case badSaltSize
        case badNonceSize
        case badKeySize
        case sodiumFailure
    }

    public static func paramsInRange(ops: Int, mem: Int) -> Bool {
        return ops >= opsMin && ops <= opsMax && mem >= memMin && mem <= memMax && mem % 1024 == 0
    }

    /// Every client MUST NFC-normalise before UTF-8 encoding: iOS and Android keyboards disagree on é vs e+◌́.
    static func passwordBytes(_ password: String) -> [UInt8] {
        return Array(password.precomposedStringWithCanonicalMapping.utf8)
    }

    /// Throws on out-of-range params or a salt of the wrong size — callers validate first and never rely on this.
    public static func deriveKek(password: String, salt: [UInt8], ops: Int = defaultOps, mem: Int = defaultMem) throws -> [UInt8] {
        guard salt.count == saltBytes else { throw Failure.badSaltSize }
        guard paramsInRange(ops: ops, mem: mem) else { throw Failure.paramsOutOfRange }
        guard SecutgSodium.ensureReady() else { throw Failure.sodiumFailure }
        // A Swift array (never nil, even when empty) bridges straight to libsodium's `const char *`.
        var pw = passwordBytes(password).map { CChar(bitPattern: $0) }
        defer { sodium_memzero(&pw, pw.count) }
        var kek = [UInt8](repeating: 0, count: kekBytes)
        let rc = crypto_pwhash(
            &kek, UInt64(kekBytes), pw, UInt64(pw.count), salt, UInt64(ops), mem, crypto_pwhash_alg_argon2id13()
        )
        guard rc == 0 else {
            sodium_memzero(&kek, kek.count)
            throw Failure.sodiumFailure
        }
        return kek
    }
}
