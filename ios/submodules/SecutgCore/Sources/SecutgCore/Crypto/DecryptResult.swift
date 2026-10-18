import Foundation

/// Outcome of `E1Codec.decrypt`; never an error for hostile input.
public struct DecryptResult: Equatable {
    public enum Reason: String, Equatable {
        case notEncrypted = "not_encrypted"
        case malformed
        case unknownKey = "unknown_key"
        case invalidKey = "invalid_key"
        case authFailed = "auth_failed"
        case badPlaintext = "bad_plaintext"
    }

    public let ok: Bool
    public let keyId: String?
    public let text: String?
    /// Entity objects exactly as carried in the envelope (Telegram entity JSON), or nil.
    public let entities: [E1Entity]?
    public let reason: Reason?

    static func success(keyId: String, text: String, entities: [E1Entity]?) -> DecryptResult {
        return DecryptResult(ok: true, keyId: keyId, text: text, entities: entities, reason: nil)
    }

    static func failure(_ reason: Reason, keyId: String?) -> DecryptResult {
        return DecryptResult(ok: false, keyId: keyId, text: nil, entities: nil, reason: reason)
    }
}

/// One entity of the envelope: `type` / `offset` / `length` (UTF-16 units) plus type-specific extras
/// (`url`, `user_id`, `language`, …) kept as JSON-compatible values.
public struct E1Entity: Equatable {
    public let type: String
    public let offset: Int
    public let length: Int
    public let extras: [String: JSONValue]

    public init(type: String, offset: Int, length: Int, extras: [String: JSONValue] = [:]) {
        self.type = type
        self.offset = offset
        self.length = length
        self.extras = extras
    }
}

/// Minimal JSON value model so entities survive a round trip without touching `Any`.
public indirect enum JSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init?(any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case is NSNull: self = .null
        case let a as [Any]:
            var items = [JSONValue]()
            for item in a { guard let v = JSONValue(any: item) else { return nil }; items.append(v) }
            self = .array(items)
        case let o as [String: Any]:
            var out = [String: JSONValue]()
            for (k, v) in o { guard let jv = JSONValue(any: v) else { return nil }; out[k] = jv }
            self = .object(out)
        default: return nil
        }
    }

    var any: Any {
        switch self {
        case .string(let s): return s
        case .number(let d): return d == d.rounded() && abs(d) < 9e15 ? NSNumber(value: Int64(d)) : NSNumber(value: d)
        case .bool(let b): return NSNumber(value: b)
        case .null: return NSNull()
        case .array(let a): return a.map { $0.any }
        case .object(let o): return o.mapValues { $0.any }
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? { if case .number(let d) = self, d == d.rounded() { return Int(d) }; return nil }
}
