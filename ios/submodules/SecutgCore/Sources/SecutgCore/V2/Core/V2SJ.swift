import Foundation

/// SJ — the "strict subset" JSON canonicalization v1.4 section 25 defines in place of full JCS
/// (RFC 8785). Ported from the Web reference implementation (`src/secutg/v2/sj.ts`) and the Android
/// port (`org.telegram.secutg.v2.SJ`) byte-for-byte; keep all three in sync rather than diverging on
/// style.
///
/// Full JCS has to handle every JSON number's IEEE-754 quirks and every Unicode escaping edge case;
/// five languages each writing that from the RFC text is exactly the kind of cross-client divergence
/// this project's xcheck discipline exists to catch, and a signature mismatch from it is silent until
/// two different clients compare notes. SJ sidesteps the whole problem by forbidding the parts that
/// vary: no JSON numbers (integers travel as decimal strings), no booleans, no floats, and a fixed
/// escape set — so canonicalization degenerates to "sort the keys and print them".
///
/// Grammar (v1.4 section 25): a value is a string, null, an object of such values keyed by
/// `^[A-Za-z0-9_]+$` sorted by UTF-8 byte order, or an array of such values. No numbers, no booleans,
/// no whitespace in the output. Strings escape only the quote character, the backslash character, and
/// control characters below 0x20 (as a lowercase-u escape); nothing else is escaped.
///
/// A Swift enum (rather than Java/TS's dynamically-typed `Object`/`unknown`) enforces the "no numbers,
/// no booleans" grammar restriction at compile time — every `V2SJValue` a caller can even construct is
/// already one SJ has a representation for, an invariant the Java/TS ports can only check at runtime.
public indirect enum V2SJValue: Equatable {
    case null
    case string(String)
    case array([V2SJValue])
    case object([String: V2SJValue])
}

extension V2SJValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension V2SJValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: V2SJValue...) {
        self = .array(elements)
    }
}

extension V2SJValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, V2SJValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension V2SJValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

public enum V2SJ {
    private static let keyPattern = "^[A-Za-z0-9_]+$"

    private static func isValidKey(_ key: String) -> Bool {
        return key.range(of: keyPattern, options: .regularExpression) != nil
    }

    /// `nil` on anything SJ cannot represent (an object with a key outside `keyPattern`) — the caller
    /// decides whether that is a bug or refused input.
    public static func serialize(_ value: V2SJValue) -> String? {
        var out = ""
        guard write(value, into: &out) else { return nil }
        return out
    }

    private static func write(_ value: V2SJValue, into out: inout String) -> Bool {
        switch value {
        case .null:
            out += "null"
            return true
        case .string(let text):
            writeString(text, into: &out)
            return true
        case .array(let list):
            out += "["
            for (index, item) in list.enumerated() {
                if index > 0 { out += "," }
                guard write(item, into: &out) else { return false }
            }
            out += "]"
            return true
        case .object(let map):
            var keys: [String] = []
            for key in map.keys {
                guard isValidKey(key) else { return false }
                keys.append(key)
            }
            // Byte-order sort. Every accepted key is ASCII, where UTF-8 byte order and Swift's
            // natural String order agree — so this needs no special comparator, but the reason it is
            // safe belongs in a comment, not left for the next reader to re-derive.
            keys.sort()
            out += "{"
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                guard write(map[key]!, into: &out) else { return false }
            }
            out += "}"
            return true
        }
    }

    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            if scalar == "\"" {
                out += "\\\""
            } else if scalar == "\\" {
                out += "\\\\"
            } else if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    /// Parses SJ text back into a value, rejecting anything the grammar does not allow — a JSON
    /// number, a duplicate key, an out-of-order key, an unknown escape, or a value SJ has no rule
    /// for. Hand-written recursive-descent, deliberately not "parse with a lenient library then
    /// validate": a lenient parser could accept `1e0`/`1.0` as equal, or silently keep only the LAST
    /// of a duplicate key — exactly the leniency that lets two clients compute different bytes for
    /// what they both call the same signed object.
    public static func parse(_ text: String) -> V2SJValue? {
        var parser = Parser(text)
        guard let value = parser.readValue(), parser.atEnd else { return nil }
        return value
    }

    private struct Parser {
        private let scalars: [Unicode.Scalar]
        private var i = 0

        init(_ text: String) {
            self.scalars = Array(text.unicodeScalars)
        }

        var atEnd: Bool {
            return i >= scalars.count
        }

        private func peek() -> Unicode.Scalar? {
            return i < scalars.count ? scalars[i] : nil
        }

        mutating func readValue() -> V2SJValue? {
            guard let ch = peek() else { return nil }
            if ch == "\"" { return readString().map { .string($0) } }
            if ch == "{" { return readObject() }
            if ch == "[" { return readArray() }
            if i + 4 <= scalars.count, String(String.UnicodeScalarView(scalars[i..<i + 4])) == "null" {
                i += 4
                return .null
            }
            return nil
        }

        /// `nil` on failure — a real SJ string is never confused with a parse failure by the caller,
        /// which always wraps a successful result in `.string(...)` before returning it.
        private mutating func readString() -> String? {
            guard peek() == "\"" else { return nil }
            i += 1
            var out = String.UnicodeScalarView()
            while true {
                guard let ch = peek() else { return nil }
                i += 1
                if ch == "\"" { return String(out) }
                if ch == "\\" {
                    guard let esc = peek() else { return nil }
                    if esc == "\"" {
                        out.append("\"")
                        i += 1
                    } else if esc == "\\" {
                        out.append("\\")
                        i += 1
                    } else if esc == "u" {
                        guard i + 5 <= scalars.count else { return nil }
                        let hex = String(String.UnicodeScalarView(scalars[(i + 1)..<(i + 5)]))
                        guard hex.range(of: "^[0-9a-fA-F]{4}$", options: .regularExpression) != nil,
                              let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
                        out.append(scalar)
                        i += 5
                    } else {
                        return nil
                    }
                } else if ch.value < 0x20 {
                    // A literal control byte, never emitted by writeString and never accepted on the
                    // way back in — a control character in an SJ string is always the escaped
                    // lowercase-u form.
                    return nil
                } else {
                    out.append(ch)
                }
            }
        }

        private mutating func readArray() -> V2SJValue? {
            i += 1 // '['
            var out: [V2SJValue] = []
            if peek() == "]" {
                i += 1
                return .array(out)
            }
            while true {
                guard let item = readValue() else { return nil }
                out.append(item)
                guard let sep = peek() else { return nil }
                if sep == "," {
                    i += 1
                    continue
                }
                if sep == "]" {
                    i += 1
                    return .array(out)
                }
                return nil
            }
        }

        private mutating func readObject() -> V2SJValue? {
            i += 1 // '{'
            var out: [String: V2SJValue] = [:]
            var lastKey: String? = nil
            if peek() == "}" {
                i += 1
                return .object(out)
            }
            while true {
                guard let key = readString(), V2SJ.isValidKey(key) else { return nil }
                // Both checks matter and neither substitutes for the other: a duplicate key is
                // unambiguous but still forbidden (two clients must not have to agree on "which one
                // wins"), and an out-of-order key means these bytes were never produced by
                // V2SJ.serialize() — accepting them would let a signature verify against a canonical
                // form this device does not itself produce.
                if let last = lastKey, key <= last { return nil }
                lastKey = key
                guard peek() == ":" else { return nil }
                i += 1
                guard let value = readValue() else { return nil }
                out[key] = value
                guard let sep = peek() else { return nil }
                if sep == "," {
                    i += 1
                    continue
                }
                if sep == "}" {
                    i += 1
                    return .object(out)
                }
                return nil
            }
        }
    }
}
