import Foundation
@testable import SecutgCore

/// The one comparison rule every client implements for itself (never in the runner, which holds no
/// protocol knowledge). Five platforms serialise the same snapshot in five key orders, wrap bytes in
/// `{"$b": …}` and disagree on integer types, so a literal string compare of two vectors is guaranteed
/// to fail for reasons that mean nothing. Canonicalising first is what makes an inequality mean "the
/// protocol differs" instead of "the JSON library differs".
///
/// The rules, all deliberate:
/// - object keys sort; arrays keep their order, except `chatIds`, which is a set in disguise;
/// - a `masters` *array* becomes an object keyed by `masterId` — Android emits it in insertion order and
///   iOS sorted, and the id is the identity of the record anyway;
/// - `{"$b": "<base64url>"}` becomes the string `"hex:<lowercase hex>"`, so a byte array compares by
///   value and reads in a failure message;
/// - numbers become integers (every number in this protocol is one);
/// - **absent is zero** for `chatPairings`' `verified` / `startedAt` / `pairedAt`: iOS omits a nil
///   timestamp where Android and Windows always write 0, and every decoder already reads a missing one
///   as 0. Treating that as a difference would paint a whole suite red for a formatting habit, and a red
///   that means nothing is a red that gets turned off.
enum XCheckCanonical {
    /// JSON in, a platform-neutral tree of [String: Any] / [Any] / String / Int64 / Bool / NSNull out.
    static func normalize(_ value: Any?) -> Any {
        guard let value = value, !(value is NSNull) else { return NSNull() }
        if let object = value as? [String: Any] { return normalizeObject(object) }
        if let array = value as? [Any] { return array.map { normalize($0) } }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            return number.int64Value
        }
        if let text = value as? String { return text }
        return String(describing: value)
    }

    private static func normalizeObject(_ object: [String: Any]) -> Any {
        if object.count == 1, let wrapped = object["$b"] as? String {
            guard let bytes = Base64Url.decode(wrapped) else { return "hex:?" + wrapped }
            return "hex:" + Hex.encode(bytes[...])
        }
        var out = [String: Any]()
        for (key, value) in object {
            switch key {
            case "masters" where value is [Any]:
                out[key] = masterMap(value as? [Any] ?? [])
            case "chatIds" where value is [Any]:
                let items = (value as? [Any] ?? []).map { normalize($0) }
                out[key] = items.sorted { render($0) < render($1) }
            case "chatPairings" where value is [String: Any]:
                out[key] = pairings(value as? [String: Any] ?? [:])
            default:
                out[key] = normalize(value)
            }
        }
        return out
    }

    /// The masters array keyed by its own identity, so insertion order stops mattering.
    private static func masterMap(_ array: [Any]) -> [String: Any] {
        var out = [String: Any]()
        for (index, item) in array.enumerated() {
            guard var record = item as? [String: Any] else { continue }
            let id = (record["masterId"] as? String) ?? "?\(index)"
            record.removeValue(forKey: "masterId")
            out[id] = normalize(record)
        }
        return out
    }

    /// "absent is zero" for the three optional pairing fields — see the type comment.
    private static func pairings(_ object: [String: Any]) -> [String: Any] {
        var out = [String: Any]()
        for (chatId, value) in object {
            guard var one = value as? [String: Any] else {
                out[chatId] = normalize(value)
                continue
            }
            if one["verified"] == nil { one["verified"] = false }
            if one["startedAt"] == nil { one["startedAt"] = 0 }
            if one["pairedAt"] == nil { one["pairedAt"] = 0 }
            out[chatId] = normalize(one)
        }
        return out
    }

    /// The canonical text of an already-normalised tree. Two equal texts mean two equal protocol values.
    static func render(_ node: Any) -> String {
        if node is NSNull { return "null" }
        if let object = node as? [String: Any] {
            let body = object.keys.sorted().map { quote($0) + ":" + render(object[$0]!) }
            return "{" + body.joined(separator: ",") + "}"
        }
        if let array = node as? [Any] {
            return "[" + array.map { render($0) }.joined(separator: ",") + "]"
        }
        if let text = node as? String { return quote(text) }
        if let flag = node as? Bool { return flag ? "true" : "false" }
        if let number = node as? Int64 { return String(number) }
        return String(describing: node)
    }

    /// `unordered` is an expectation item's `"unordered": true` (README.md, "How an expectation
    /// compares"): that one array is a set, so both sides sort before they are rendered. Ordered stays the
    /// default and this stays the exception, because the failure directions are not symmetric — a client
    /// that never grew the flag goes red on an ordering difference, where one comparing every array as a
    /// set cannot go red on a `trail` that is right in the wrong order.
    static func canonical(_ value: Any?, unordered: Bool = false) -> String {
        let node = normalize(value)
        guard unordered, let array = node as? [Any] else { return render(node) }
        return render(array.sorted { render($0) < render($1) })
    }

    /// `/a/b/c` into a normalised tree; nil when the path does not resolve.
    static func get(_ tree: Any, _ path: String) -> Any? {
        var node: Any = tree
        for segment in path.split(separator: "/") {
            guard let object = node as? [String: Any], let next = object[String(segment)] else { return nil }
            node = next
        }
        return node is NSNull ? nil : node
    }

    /// Whether `path` resolves to anything at all — the check that catches a lenient decoder.
    static func has(_ tree: Any, _ path: String) -> Bool {
        return get(tree, path) != nil
    }

    /// Every leaf path of a normalised tree, for reporting what a decoder actually kept.
    static func leafPaths(_ tree: Any, _ prefix: String) -> [String] {
        guard let object = tree as? [String: Any] else { return [prefix] }
        if object.isEmpty { return [prefix] }
        var out = [String]()
        for key in object.keys.sorted() { out += leafPaths(object[key]!, prefix + "/" + key) }
        return out
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
