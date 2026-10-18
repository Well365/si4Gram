import Foundation

/// `L1:` reference message (PLAN.md 3.48.1) — secuTG's own, independent wire format for "this message's real
/// content lives on a relay". Recognised by SHAPE alone, never by the host in `u`: any string beginning with
/// the exact prefix `L1:` is routed here, so an ordinary message that merely happens to start with those three
/// characters still has to fail base64url / JSON / field validation before this module gives up on it (and when
/// it does, the caller shows "unrecognised relay content" and never touches the network — PLAN.md 3.48.1).
///
/// Encoding is one-way deterministic (fixed key order `v,u,id,t,m,n,r,e,k`, `k` omitted when absent, no
/// whitespace) so four independently-written platforms produce byte-identical wires for the same reference;
/// parsing accepts any key order, because nothing requires every producer to be this file.
public enum RelayContentType: String, Equatable, Codable {
    case text
    case image
}

/// One parsed (or about-to-be-encoded) `L1:` reference. All fields are already validated once this type exists.
public struct RelayL1Reference: Equatable {
    public static let version = 1

    /// `https://host[:port]` or `http://host[:port]` — no userinfo, query, fragment, or trailing slash.
    public let relayURL: String
    /// 22-char base64url (128-bit random) — the item id on the relay.
    public let id: String
    public let contentType: RelayContentType
    public let mime: String
    /// Plaintext byte size (before any relay-side encryption envelope).
    public let sizeBytes: Int
    /// Max reads; 0 = unlimited.
    public let maxReads: Int
    /// Unix seconds.
    public let expiresAt: Int64
    /// 43-char base64url (32-byte content key), present only when the content is encrypted.
    public let contentKey: String?

    public init(relayURL: String, id: String, contentType: RelayContentType, mime: String, sizeBytes: Int, maxReads: Int, expiresAt: Int64, contentKey: String?) {
        self.relayURL = relayURL
        self.id = id
        self.contentType = contentType
        self.mime = mime
        self.sizeBytes = sizeBytes
        self.maxReads = maxReads
        self.expiresAt = expiresAt
        self.contentKey = contentKey
    }
}

/// Why `RelayL1.parse` refused a wire, as the exact strings PLAN.md 3.48.1 specifies.
public enum RelayL1ParseError: Error, Equatable {
    case prefix
    case base64
    case json
    case version
    case field(String)

    /// `"prefix" | "base64" | "json" | "version" | "field:<name>"`.
    public var reasonCode: String {
        switch self {
        case .prefix: return "prefix"
        case .base64: return "base64"
        case .json: return "json"
        case .version: return "version"
        case .field(let name): return "field:\(name)"
        }
    }
}

public enum RelayL1 {
    public static let prefix = "L1:"
    public static let maxBytes = 20 * 1024 * 1024
    public static let maxReads = 1000
    public static let allowedMimes: Set<String> = [
        "text/plain;charset=utf-8", "image/jpeg", "image/png", "image/webp", "image/gif",
    ]

    /// Cheap, prefix-only check — the one test the independence rule relies on: a message that does not even
    /// start with `L1:` must never cause a parse attempt, a network call, or a storage read.
    public static func isReference(_ text: String) -> Bool {
        return text.hasPrefix(prefix)
    }

    /// A fresh 128-bit random id, base64url, 22 characters — PLAN.md 3.48.1's `id`.
    public static func newId() -> String {
        return Base64Url.encode(SecutgSodium.randomBytes(16))
    }

    /// A fresh 32-byte content key, base64url, 43 characters — PLAN.md 3.48.2's `k`.
    public static func newContentKey() -> String {
        return Base64Url.encode(SecutgSodium.randomBytes(32))
    }

    // MARK: - Encode

    /// Fixed key order `v,u,id,t,m,n,r,e,k`; `k` is omitted entirely (not written as `null`) when absent.
    /// No whitespace anywhere — every byte here is part of the wire four platforms must agree on.
    public static func encode(_ ref: RelayL1Reference) -> String {
        var fields: [String] = []
        fields.append("\"v\":\(RelayL1Reference.version)")
        fields.append("\"u\":\(jsonString(ref.relayURL))")
        fields.append("\"id\":\(jsonString(ref.id))")
        fields.append("\"t\":\(jsonString(ref.contentType.rawValue))")
        fields.append("\"m\":\(jsonString(ref.mime))")
        fields.append("\"n\":\(ref.sizeBytes)")
        fields.append("\"r\":\(ref.maxReads)")
        fields.append("\"e\":\(ref.expiresAt)")
        if let key = ref.contentKey {
            fields.append("\"k\":\(jsonString(key))")
        }
        let json = "{" + fields.joined(separator: ",") + "}"
        return prefix + Base64Url.encode([UInt8](json.utf8))
    }

    // MARK: - Parse

    /// Accepts any key order; anything else wrong yields the specific reason PLAN.md 3.48.1 names.
    public static func parse(_ wire: String) -> Result<RelayL1Reference, RelayL1ParseError> {
        guard wire.hasPrefix(prefix) else { return .failure(.prefix) }
        let encoded = String(wire.dropFirst(prefix.count))
        guard let jsonBytes = RelayBase64Url.decode(encoded) else { return .failure(.base64) }
        guard let raw = try? JSONSerialization.jsonObject(with: Data(jsonBytes), options: []),
              let object = raw as? [String: Any] else {
            return .failure(.json)
        }
        guard let v = jsonInt(object["v"]), v == RelayL1Reference.version else { return .failure(.version) }

        guard let u = object["u"] as? String, RelayHost.classify(u) != nil else { return .failure(.field("u")) }
        guard let id = object["id"] as? String, id.utf8.count == 22, let idBytes = RelayBase64Url.decode(id), idBytes.count == 16 else {
            return .failure(.field("id"))
        }
        guard let tRaw = object["t"] as? String, let t = RelayContentType(rawValue: tRaw) else { return .failure(.field("t")) }
        // Deliberately NOT cross-checked against `t` — the Web oracle (`codec.ts`'s `parseL1`) only tests `m`
        // against the fixed MIME list, independent of `t`; matching it exactly matters more than a stricter
        // check this format's own spec never asked for (PLAN.md 3.48.1 lists `m`'s allowed values as one set).
        guard let m = object["m"] as? String, allowedMimes.contains(m) else { return .failure(.field("m")) }
        guard let n = jsonInt(object["n"]), n >= 0, n <= maxBytes else { return .failure(.field("n")) }
        guard let r = jsonInt(object["r"]), r >= 0, r <= maxReads else { return .failure(.field("r")) }
        // `>= 0`, matching the oracle's `isNonNegativeInt` exactly: an already-past `e` is a malformed value by
        // nobody's definition here, it is simply a reference that is already expired, which the render/fetch path
        // handles on its own (PLAN.md 3.48.4 "已失效").
        guard let e = jsonInt64(object["e"]), e >= 0 else { return .failure(.field("e")) }

        var contentKey: String? = nil
        if let kAny = object["k"], !(kAny is NSNull) {
            guard let k = kAny as? String, k.utf8.count == 43, let kBytes = RelayBase64Url.decode(k), kBytes.count == 32 else {
                return .failure(.field("k"))
            }
            contentKey = k
        }

        return .success(RelayL1Reference(relayURL: u, id: id, contentType: t, mime: m, sizeBytes: n, maxReads: r, expiresAt: e, contentKey: contentKey))
    }

    private static func jsonInt(_ any: Any?) -> Int? {
        guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d == d.rounded(), d >= Double(Int.min), d <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func jsonInt64(_ any: Any?) -> Int64? {
        guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d == d.rounded(), d >= Double(Int64.min), d <= Double(Int64.max) else { return nil }
        return number.int64Value
    }

    /// Minimal, correct JSON string escaping (quote, backslash, control chars) — `u` and `m` never contain
    /// anything else, but the encoder must not assume that.
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
