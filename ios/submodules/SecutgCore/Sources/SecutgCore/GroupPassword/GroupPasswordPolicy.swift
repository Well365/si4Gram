import Clibsodium
import Foundation

/// PLAN.md 3.38.2 — the group password as an ACCESS GATE, separate from the message keys. Supersedes the
/// 3.38 / 3.38.1 "password wraps the group master" model: opening, changing or closing the password never
/// touches a master, never sends `N1` or `G2`. The group's masters keep travelling in the ordinary plain `G2`.
///
/// Wire: its own control message, shaped and obfuscated exactly like `G2` (3.35.8):
///
///   GP1:<group_id>:<at>:<obfuscated_payload_b64url>:<publisher_user_id>
///
/// payload before obfuscation, fields in exactly this order, decimal integers without leading zeros, base64url
/// without padding:
///
///   on:  secutg://grouppw?v=1&on=1&kdf=argon2id13&ops=<n>&mem=<n>&salt=<b64url16>&verifier=<b64url32>
///   off: secutg://grouppw?v=1&on=0
///
/// `verifier = BLAKE2b-256(key = KEK, msg = "secutg/grouppw/verify/v1" ‖ 0x00 ‖ group_id)` with
/// `KEK = GroupPassword.deriveKek(NFC(password), salt, ops, mem)`. The KEK itself never leaves the device.
public struct GroupPasswordPolicyParams: Equatable {
    public let kdf: String
    public let ops: Int
    public let mem: Int
    public let salt: [UInt8]
    public let verifier: [UInt8]

    public init(kdf: String, ops: Int, mem: Int, salt: [UInt8], verifier: [UInt8]) {
        self.kdf = kdf
        self.ops = ops
        self.mem = mem
        self.salt = salt
        self.verifier = verifier
    }

    /// Something this build could ever check a password against. A policy that fails this is refused on
    /// receive: adopting it would shut the group behind a gate no password opens.
    public var isUsable: Bool {
        return kdf == GroupPassword.kdfArgon2id13 && GroupPassword.paramsInRange(ops: ops, mem: mem)
            && salt.count == GroupPassword.saltBytes && verifier.count == GroupPassword.verifierBytes
    }
}

public enum GroupPasswordPolicyPayload: Equatable {
    case off
    case on(GroupPasswordPolicyParams)

    public var isOn: Bool {
        if case .on = self { return true }
        return false
    }

    public var params: GroupPasswordPolicyParams? {
        if case let .on(params) = self { return params }
        return nil
    }
}

/// What a device keeps per group (persisted): the newest adopted policy and the `at` it carried.
public struct GroupPasswordPolicy: Equatable {
    public let payload: GroupPasswordPolicyPayload
    public let at: Int64

    public init(payload: GroupPasswordPolicyPayload, at: Int64) {
        self.payload = payload
        self.at = at
    }

    public var isOn: Bool { return payload.isOn }

    public var isValid: Bool {
        guard at >= 0 else { return false }
        if let params = payload.params { return params.isUsable }
        return true
    }
}

extension GroupPassword {
    public static let policyPrefix = "secutg://grouppw?"
    public static let policyVersion = 1
    public static let verifierBytes = 32
    public static let verifierContext = "secutg/grouppw/verify/v1"

    private static let policyOnFields = ["v", "on", "kdf", "ops", "mem", "salt", "verifier"]
    private static let policyOffFields = ["v", "on"]
    private static let policyDigits = Set("0123456789".utf8)
    private static let policyKdfChars = Set("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
    private static let policyB64Chars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".utf8)

    // MARK: payload

    public static func buildPolicyPayload(_ payload: GroupPasswordPolicyPayload) -> String {
        switch payload {
        case .off:
            return policyPrefix + "v=\(policyVersion)&on=0"
        case let .on(p):
            return policyPrefix + "v=\(policyVersion)&on=1&kdf=\(p.kdf)&ops=\(p.ops)&mem=\(p.mem)"
                + "&salt=\(Base64Url.encode(p.salt))&verifier=\(Base64Url.encode(p.verifier))"
        }
    }

    /// Strict, as Web `parseGp1Payload` (the shared vectors' `payload_parse_fail` cases): exact field order, no
    /// repeats, no unknown names, `v=1` only, integers `[1-9][0-9]{0,9}`, canonical unpadded base64url, and an
    /// "on" policy must be usable — `kdf=argon2id13`, ops/mem inside 3.38's bounds, a 16-byte salt and a 32-byte
    /// verifier. Anything else is not a policy at all.
    public static func parsePolicyPayload(_ text: String) -> GroupPasswordPolicyPayload? {
        guard text.hasPrefix(policyPrefix) else { return nil }
        let query = String(text.dropFirst(policyPrefix.count))
        var names: [String] = []
        var values: [String: String] = [:]
        for part in query.components(separatedBy: "&") {
            guard let eq = part.firstIndex(of: "="), eq > part.startIndex else { return nil }
            let name = String(part[..<eq])
            names.append(name)
            values[name] = String(part[part.index(after: eq)...])
        }
        guard names.count == values.count, values["v"] == String(policyVersion) else { return nil }
        switch values["on"] {
        case "0":
            return names == policyOffFields ? .off : nil
        case "1":
            guard names == policyOnFields, let kdf = values["kdf"], isPolicyKdf(kdf),
                  let ops = values["ops"].flatMap(parsePolicyInt), let mem = values["mem"].flatMap(parsePolicyInt),
                  let salt = values["salt"].flatMap(policyB64), salt.count == saltBytes,
                  let verifier = values["verifier"].flatMap(policyB64), verifier.count == verifierBytes else { return nil }
            let params = GroupPasswordPolicyParams(kdf: kdf, ops: ops, mem: mem, salt: salt, verifier: verifier)
            return params.isUsable ? .on(params) : nil
        default:
            return nil
        }
    }

    private static func parsePolicyInt(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard (1...10).contains(bytes.count), bytes.allSatisfy(policyDigits.contains), bytes[0] != UInt8(ascii: "0") else {
            return nil
        }
        return Int(text)
    }

    private static func isPolicyKdf(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (1...32).contains(bytes.count) && bytes.allSatisfy(policyKdfChars.contains)
    }

    private static func policyB64(_ text: String) -> [UInt8]? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy(policyB64Chars.contains) else { return nil }
        return Base64Url.decode(text)
    }

    // MARK: verifier

    /// `BLAKE2b-256(key = KEK, msg = "secutg/grouppw/verify/v1" ‖ 0x00 ‖ groupId)`.
    public static func computeVerifier(kek: [UInt8], groupId: String) throws -> [UInt8] {
        guard kek.count == kekBytes else { throw Failure.badKeySize }
        guard !groupId.isEmpty else { throw Failure.missingGroupId }
        guard SecutgSodium.ensureReady() else { throw Failure.sodiumFailure }
        let message = Array(verifierContext.utf8) + [0] + Array(groupId.utf8)
        var out = [UInt8](repeating: 0, count: verifierBytes)
        let rc = crypto_generichash(&out, verifierBytes, message, UInt64(message.count), kek, kek.count)
        guard rc == 0 else { throw Failure.sodiumFailure }
        return out
    }

    /// The admin's side: a fresh policy for `password`. Argon2id — keep it OFF the main thread.
    /// `salt` is TEST / VECTOR USE ONLY; anything not given is random.
    public static func makePolicyParams(password: String, groupId: String, ops: Int = defaultOps, mem: Int = defaultMem,
                                        salt: [UInt8]? = nil) throws -> GroupPasswordPolicyParams {
        let check = validatePassword(password)
        guard check == .ok else { throw Failure.passwordRejected(check) }
        guard !groupId.isEmpty else { throw Failure.missingGroupId }
        guard paramsInRange(ops: ops, mem: mem) else { throw Failure.paramsOutOfRange }
        let usedSalt = salt ?? SecutgSodium.randomBytes(saltBytes)
        var kek = try deriveKek(password: password, salt: usedSalt, ops: ops, mem: mem)
        defer { sodium_memzero(&kek, kek.count) }
        let verifier = try computeVerifier(kek: kek, groupId: groupId)
        return GroupPasswordPolicyParams(kdf: kdfArgon2id13, ops: ops, mem: mem, salt: usedSalt, verifier: verifier)
    }

    /// Everybody's side: does `password` open this policy? nil = yes. Wrong password, a tampered salt or
    /// parameters, and the wrong group all read `wrongPassword` — indistinguishable by design, as in 3.38.
    /// The comparison is constant-time (`sodium_memcmp`).
    public static func verifyPolicy(_ params: GroupPasswordPolicyParams, password: String, groupId: String) -> GroupPasswordUnwrapFailure? {
        if params.kdf != kdfArgon2id13 { return .unsupportedKdf }
        if !paramsInRange(ops: params.ops, mem: params.mem) { return .paramsOutOfRange }
        if groupId.isEmpty || params.salt.count != saltBytes || params.verifier.count != verifierBytes { return .malformed }
        guard var kek = try? deriveKek(password: password, salt: params.salt, ops: params.ops, mem: params.mem) else {
            return .wrongPassword
        }
        defer { sodium_memzero(&kek, kek.count) }
        guard let computed = try? computeVerifier(kek: kek, groupId: groupId), computed.count == params.verifier.count else {
            return .wrongPassword
        }
        return sodium_memcmp(computed, params.verifier, computed.count) == 0 ? nil : .wrongPassword
    }
}

/// PLAN.md 3.38.2: the `GP1` control message. Same outer shape and the same 3.35.8 obfuscation layer as `G2`.
public enum GP1 {
    public struct Parsed: Equatable {
        public let chatId: String
        public let at: Int64
        public let payload: GroupPasswordPolicyPayload
        public let publisherId: String
    }

    private static let regex = try! NSRegularExpression(
        pattern: "^GP1:(-\\d{1,20}):(\\d{1,20}):([A-Za-z0-9_-]+):(\\d{1,20})$")
    private static let maxChars = 4096
    private static let maxSafeAt: Int64 = 9_007_199_254_740_991

    public static func isGP1(_ text: String) -> Bool {
        return text.utf16.count <= maxChars && regex.wholeMatch(text) != nil
    }

    /// nil for anything `parse` would refuse (a policy no client could use included). `obfuscationNonce` is
    /// TEST / VECTOR USE ONLY.
    public static func build(chatId: String, at: Int64, payload: GroupPasswordPolicyPayload, publisherId: String,
                             obfuscationNonce: [UInt8]? = nil) -> String? {
        if let params = payload.params, !params.isUsable { return nil }
        guard chatId.hasPrefix("-"), at >= 0, at <= maxSafeAt,
              let wrapped = G2Obfuscation.obfuscate(GroupPassword.buildPolicyPayload(payload), nonce: obfuscationNonce)
        else { return nil }
        let text = "GP1:\(chatId):\(at):\(Base64Url.encode(wrapped)):\(publisherId)"
        return isGP1(text) ? text : nil
    }

    public static func parse(_ text: String) -> Parsed? {
        guard text.utf16.count <= maxChars, let match = regex.wholeMatch(text) else { return nil }
        let g = match.groups(in: text)
        guard g.count == 4, let at = Int64(g[1]), at <= maxSafeAt else { return nil }
        guard let bytes = Base64Url.decode(g[2]), let plain = G2Obfuscation.deobfuscate(bytes),
              let payload = GroupPassword.parsePolicyPayload(plain) else { return nil }
        return Parsed(chatId: g[0], at: at, payload: payload, publisherId: g[3])
    }
}
