import Clibsodium
import Foundation

/// PLAN.md 3.38 — wrap / unwrap the group master (and its history) under a password-derived KEK.
/// Mirrors Web `grouppw/wrap.ts`; failure names are the wire-visible contract and must stay identical.
public enum GroupPasswordUnwrapFailure: String, Error, Equatable {
    case wrongPassword = "wrong_password"
    case malformed
    case unsupportedKdf = "unsupported_kdf"
    case paramsOutOfRange = "params_out_of_range"
}

/// What a password-protected key payload carries instead of a master. Never contains a key in the clear.
public struct GroupPasswordLockedFields: Equatable {
    public let version: Int
    public let kdf: String
    public let ops: Int
    public let mem: Int
    public let salt: [UInt8]
    public let wrap: [UInt8]
    public let hist: [[UInt8]]

    public init(version: Int, kdf: String, ops: Int, mem: Int, salt: [UInt8], wrap: [UInt8], hist: [[UInt8]]) {
        self.version = version
        self.kdf = kdf
        self.ops = ops
        self.mem = mem
        self.salt = salt
        self.wrap = wrap
        self.hist = hist
    }

    /// Copy with some fields replaced (tests and callers never mutate a received payload in place).
    public func with(
        version: Int? = nil, kdf: String? = nil, ops: Int? = nil, mem: Int? = nil,
        salt: [UInt8]? = nil, wrap: [UInt8]? = nil, hist: [[UInt8]]? = nil
    ) -> GroupPasswordLockedFields {
        return GroupPasswordLockedFields(
            version: version ?? self.version, kdf: kdf ?? self.kdf, ops: ops ?? self.ops, mem: mem ?? self.mem,
            salt: salt ?? self.salt, wrap: wrap ?? self.wrap, hist: hist ?? self.hist
        )
    }
}

public enum GroupPasswordUnwrapResult: Equatable {
    case ok(current: [UInt8], history: [[UInt8]])
    case failure(GroupPasswordUnwrapFailure)
}

extension GroupPassword {
    public static let version = 1
    public static let aadPrefix = "secutg/grouppw/v1"
    static let histAadTag = "\u{0}hist\u{0}"
    public static let nonceBytes = 24
    public static let tagBytes = 16
    public static let wrapBytes = nonceBytes + KeyDerivation.masterKeyBytes + tagBytes // 72
    public static let historyMax = 16

    static func currentAad(groupId: String) -> [UInt8] {
        return Array(aadPrefix.utf8) + Array(groupId.utf8)
    }

    static func historyAad(groupId: String, index: Int) -> [UInt8] {
        return currentAad(groupId: groupId) + Array(histAadTag.utf8) + Array(String(index).utf8)
    }

    /// Drop copies of `current`, keep the first occurrence of each repeat (order preserved), then the newest 16.
    public static func normaliseHistory(current: [UInt8], history: [[UInt8]]) -> [[UInt8]] {
        let kept = history.reduce(into: [[UInt8]]()) { acc, key in
            if key != current && !acc.contains(key) { acc.append(key) }
        }
        return Array(kept.suffix(historyMax))
    }

    private static func seal(kek: [UInt8], master: [UInt8], aad: [UInt8], nonce: [UInt8]) throws -> [UInt8] {
        guard nonce.count == nonceBytes else { throw Failure.badNonceSize }
        var ct = [UInt8](repeating: 0, count: master.count + tagBytes)
        var ctLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_encrypt(
            &ct, &ctLen, master, UInt64(master.count), aad, UInt64(aad.count), nil, nonce, kek
        )
        guard rc == 0 else { throw Failure.sodiumFailure }
        return nonce + ct[0..<Int(ctLen)]
    }

    private static func open(kek: [UInt8], wrap: [UInt8], aad: [UInt8]) -> [UInt8]? {
        guard wrap.count == wrapBytes else { return nil }
        let nonce = Array(wrap[0..<nonceBytes])
        let ct = Array(wrap[nonceBytes...])
        var pt = [UInt8](repeating: 0, count: ct.count - tagBytes)
        var ptLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_decrypt(
            &pt, &ptLen, nil, ct, UInt64(ct.count), aad, UInt64(aad.count), nonce, kek
        )
        guard rc == 0, Int(ptLen) == KeyDerivation.masterKeyBytes else { return nil }
        return Array(pt[0..<Int(ptLen)])
    }

    /// Throws on caller bugs (bad password, bad key size, out-of-range params); never on user data.
    /// `salt` / `nonces` are TEST / VECTOR USE ONLY: `nonces[0]` wraps `current`, `nonces[1 + i]` wraps
    /// normalised history entry i; anything not given is random.
    public static func wrapGroupKeys(
        password: String, groupId: String, current: [UInt8], history: [[UInt8]] = [],
        ops: Int = defaultOps, mem: Int = defaultMem, salt: [UInt8]? = nil, nonces: [[UInt8]] = []
    ) throws -> GroupPasswordLockedFields {
        let check = validatePassword(password)
        guard check == .ok else { throw Failure.passwordRejected(check) }
        guard !groupId.isEmpty else { throw Failure.missingGroupId }
        guard paramsInRange(ops: ops, mem: mem) else { throw Failure.paramsOutOfRange }
        guard ([current] + history).allSatisfy({ $0.count == KeyDerivation.masterKeyBytes }) else {
            throw Failure.badKeySize
        }

        let normalised = normaliseHistory(current: current, history: history)
        let nonceAt = { (i: Int) -> [UInt8] in i < nonces.count ? nonces[i] : SecutgSodium.randomBytes(nonceBytes) }
        let usedSalt = salt ?? SecutgSodium.randomBytes(saltBytes)
        var kek = try deriveKek(password: password, salt: usedSalt, ops: ops, mem: mem)
        defer { sodium_memzero(&kek, kek.count) }
        let wrap = try seal(kek: kek, master: current, aad: currentAad(groupId: groupId), nonce: nonceAt(0))
        let hist = try normalised.enumerated().map { i, key in
            try seal(kek: kek, master: key, aad: historyAad(groupId: groupId, index: i), nonce: nonceAt(1 + i))
        }
        return GroupPasswordLockedFields(
            version: version, kdf: kdfArgon2id13, ops: ops, mem: mem, salt: usedSalt, wrap: wrap, hist: hist
        )
    }

    private static func precheck(_ fields: GroupPasswordLockedFields, groupId: String) -> GroupPasswordUnwrapFailure? {
        if fields.version != version || fields.kdf != kdfArgon2id13 { return .unsupportedKdf }
        if !paramsInRange(ops: fields.ops, mem: fields.mem) { return .paramsOutOfRange }
        if groupId.isEmpty || fields.salt.count != saltBytes || fields.wrap.count != wrapBytes
            || fields.hist.count > historyMax || fields.hist.contains(where: { $0.count != wrapBytes }) {
            return .malformed
        }
        return nil
    }

    /// The AEAD on `wrap` is the password check: failing it is `wrong_password` (a tampered salt, params or
    /// wrap looks exactly the same, by design). Once `current` opens, the password is right, so a history
    /// entry that fails to open was tampered with or reordered and the whole payload is `malformed`.
    public static func unwrapGroupKeys(
        _ fields: GroupPasswordLockedFields, password: String, groupId: String
    ) -> GroupPasswordUnwrapResult {
        if let failure = precheck(fields, groupId: groupId) { return .failure(failure) }
        // precheck guarantees the only way deriveKek can still throw is libsodium refusing (e.g. out of memory);
        // there is no better name for that on the wire than "could not open".
        guard var kek = try? deriveKek(password: password, salt: fields.salt, ops: fields.ops, mem: fields.mem) else {
            return .failure(.wrongPassword)
        }
        defer { sodium_memzero(&kek, kek.count) }
        guard let current = open(kek: kek, wrap: fields.wrap, aad: currentAad(groupId: groupId)) else {
            return .failure(.wrongPassword)
        }
        let history = fields.hist.enumerated().map { i, h in
            open(kek: kek, wrap: h, aad: historyAad(groupId: groupId, index: i))
        }
        let opened = history.compactMap { $0 }
        guard opened.count == history.count else { return .failure(.malformed) }
        return .ok(current: current, history: opened)
    }
}
