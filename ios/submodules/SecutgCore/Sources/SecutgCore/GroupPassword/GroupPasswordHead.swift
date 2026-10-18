import Foundation

/// PLAN.md 3.38 — the locked head of a key payload: everything between `secutg://key?` and `&admin_pk=` /
/// `&mode=`. `KeyPayload` splits those two off exactly as it always has, then hands the head here when it
/// starts with `pw=`. Mirrors Web `grouppw/payload.ts`.
///
///   pw=1&kdf=argon2id13&ops=<n>&mem=<n>&salt=<b64url>&wrap=<b64url>[&hist=<b64url>,<b64url>,…]
///
/// Canonical and strict: fields in exactly this order, no repeats, no unknown names, decimal integers without
/// leading zeros, base64url without padding, `hist` omitted (not empty) when there is none. `pw` is the layout
/// version; only `1` is understood. `kdf` is any lowercase token here — an unknown one parses and is refused
/// later by unwrap as `unsupported_kdf`, so a newer KDF reads as "can't open" and not as garbage.
extension GroupPassword {
    public static let lockedHeadPrefix = "pw="
    private static let fieldOrder = ["pw", "kdf", "ops", "mem", "salt", "wrap", "hist"]
    private static let digits = Set("0123456789".utf8)
    private static let kdfChars = Set("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
    private static let b64Chars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".utf8)

    public static func buildLockedHead(_ fields: GroupPasswordLockedFields) -> String {
        let parts = [
            "pw=\(fields.version)",
            "kdf=\(fields.kdf)",
            "ops=\(fields.ops)",
            "mem=\(fields.mem)",
            "salt=\(Base64Url.encode(fields.salt))",
            "wrap=\(Base64Url.encode(fields.wrap))",
        ]
        let hist = fields.hist.isEmpty ? [] : ["hist=" + fields.hist.map(Base64Url.encode).joined(separator: ",")]
        return (parts + hist).joined(separator: "&")
    }

    /// Web `INT_RE = /^[1-9][0-9]{0,9}$/`.
    private static func parseInt(_ text: String) -> Int? {
        let bytes = Array(text.utf8)
        guard (1...10).contains(bytes.count), bytes.allSatisfy(digits.contains), bytes[0] != UInt8(ascii: "0") else {
            return nil
        }
        return Int(text)
    }

    /// Web `KDF_RE = /^[a-z0-9]{1,32}$/`.
    private static func isKdfToken(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (1...32).contains(bytes.count) && bytes.allSatisfy(kdfChars.contains)
    }

    /// Web `B64URL_RE = /^[A-Za-z0-9_-]+$/` then a strict unpadded decode.
    private static func b64(_ text: String) -> [UInt8]? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy(b64Chars.contains) else { return nil }
        return Base64Url.decode(text)
    }

    private static func splitFields(_ head: String) -> [String: String]? {
        var pairs: [(String, String)] = []
        for part in head.components(separatedBy: "&") {
            guard let eq = part.firstIndex(of: "="), eq > part.startIndex else { return nil }
            pairs.append((String(part[..<eq]), String(part[part.index(after: eq)...])))
        }
        let expected = pairs.count == fieldOrder.count ? fieldOrder : Array(fieldOrder.dropLast())
        guard pairs.map({ $0.0 }) == expected else { return nil }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    public static func parseLockedHead(_ head: String) -> GroupPasswordLockedFields? {
        guard head.hasPrefix(lockedHeadPrefix), let f = splitFields(head),
              let pw = f["pw"], let kdf = f["kdf"], let opsText = f["ops"], let memText = f["mem"],
              let saltText = f["salt"], let wrapText = f["wrap"] else { return nil }
        guard pw == String(version), isKdfToken(kdf), let ops = parseInt(opsText), let mem = parseInt(memText) else {
            return nil
        }
        let histParts = f["hist"].map { $0.components(separatedBy: ",") } ?? []
        guard histParts.count <= historyMax else { return nil }
        let hist = histParts.compactMap(b64)
        guard let salt = b64(saltText), let wrap = b64(wrapText), hist.count == histParts.count else { return nil }
        return GroupPasswordLockedFields(version: version, kdf: kdf, ops: ops, mem: mem, salt: salt, wrap: wrap, hist: hist)
    }
}
