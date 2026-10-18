import Foundation

/// Minimal ORDERED JSON for the V2Q payload (PLAN.md 3.39.2, 3.39.13). The payload is plain JSON — not SJ — with a FIXED key
/// order that the Web reference (`join/payload.ts`) checks with `Object.keys`, and `JSONSerialization` can neither
/// emit nor report an order. So this file does both halves itself: a serializer that writes members in the order
/// given (escaping exactly as `JSON.stringify` does, so the bytes match the shared vectors), and a strict
/// recursive-descent parser that keeps member order and refuses duplicate keys, non-integer numbers, and anything
/// outside the JSON grammar. Values are only what the payload needs: strings, integers, arrays, objects.
indirect enum V2JoinJSON: Equatable {
    case string(String)
    /// A JSON number that is a safe integer (|n| <= 2^53 - 1); any other number is refused by the parser.
    case int(Int64)
    case null
    case array([V2JoinJSON])
    case object([Member])

    struct Member: Equatable {
        let key: String
        let value: V2JoinJSON

        init(_ key: String, _ value: V2JoinJSON) {
            self.key = key
            self.value = value
        }
    }

    static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    // MARK: accessors

    var members: [Member]? {
        if case .object(let m) = self { return m }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    var arrayValue: [V2JoinJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Exactly these keys, in exactly this order — what "fixed field order, no extra fields" means on the way in.
    func hasKeysInOrder(_ keys: [String]) -> Bool {
        guard let members = members, members.count == keys.count else { return false }
        for (member, key) in zip(members, keys) where member.key != key { return false }
        return true
    }

    subscript(key: String) -> V2JoinJSON? {
        return members?.first { $0.key == key }?.value
    }

    // MARK: serialize (JSON.stringify-compatible, no whitespace)

    static func serialize(_ value: V2JoinJSON) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    private static func write(_ value: V2JoinJSON, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .int(let n):
            out += String(n)
        case .string(let s):
            writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (i, member) in members.enumerated() {
                if i > 0 { out += "," }
                writeString(member.key, into: &out)
                out += ":"
                write(member.value, into: &out)
            }
            out += "}"
        }
    }

    /// `JSON.stringify`'s escaping: `"` `\` and the controls below 0x20 (the five short forms, `\u00xx` lowercase
    /// for the rest); everything else — including non-ASCII — verbatim. Swift strings hold no lone surrogates, so
    /// the well-formed-stringify rule for those never applies.
    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
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
    }

    // MARK: parse (strict)

    static func parse(_ text: String) -> V2JoinJSON? {
        var parser = Parser(text)
        parser.skipWhitespace()
        guard let value = parser.readValue() else { return nil }
        parser.skipWhitespace()
        return parser.atEnd ? value : nil
    }

    private struct Parser {
        private let scalars: [Unicode.Scalar]
        private var i = 0

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
        }

        var atEnd: Bool { return i >= scalars.count }

        private func peek() -> Unicode.Scalar? {
            return i < scalars.count ? scalars[i] : nil
        }

        mutating func skipWhitespace() {
            while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1 }
        }

        mutating func readValue() -> V2JoinJSON? {
            guard let c = peek() else { return nil }
            switch c {
            case "\"": return readString().map { .string($0) }
            case "{": return readObject()
            case "[": return readArray()
            case "-", "0"..."9": return readNumber()
            default:
                if matchLiteral("null") { return .null }
                return nil // true/false are not values the payload ever carries — refused rather than modelled
            }
        }

        private mutating func matchLiteral(_ literal: String) -> Bool {
            let wanted = Array(literal.unicodeScalars)
            guard i + wanted.count <= scalars.count, Array(scalars[i..<i + wanted.count]) == wanted else { return false }
            i += wanted.count
            return true
        }

        private mutating func readNumber() -> V2JoinJSON? {
            let start = i
            if peek() == "-" { i += 1 }
            guard let first = peek(), first >= "0" && first <= "9" else { return nil }
            if first == "0" {
                i += 1
            } else {
                while let d = peek(), d >= "0" && d <= "9" { i += 1 }
            }
            var integral = true
            if peek() == "." {
                integral = false
                i += 1
                guard let d = peek(), d >= "0" && d <= "9" else { return nil }
                while let d = peek(), d >= "0" && d <= "9" { i += 1 }
            }
            if let e = peek(), e == "e" || e == "E" {
                integral = false
                i += 1
                if let sign = peek(), sign == "+" || sign == "-" { i += 1 }
                guard let d = peek(), d >= "0" && d <= "9" else { return nil }
                while let d = peek(), d >= "0" && d <= "9" { i += 1 }
            }
            let text = String(String.UnicodeScalarView(scalars[start..<i]))
            if integral {
                guard let n = Int64(text), abs(n) <= V2JoinJSON.maxSafeInteger else { return nil }
                return .int(n)
            }
            // `JSON.parse` would accept 1.0 / 1e3 as the integers 1 / 1000; so does this, and nothing else.
            guard let d = Double(text), d.rounded() == d, abs(d) <= Double(V2JoinJSON.maxSafeInteger) else { return nil }
            return .int(Int64(d))
        }

        private mutating func readHex4() -> UInt32? {
            guard i + 4 <= scalars.count else { return nil }
            let hex = String(String.UnicodeScalarView(scalars[i..<i + 4]))
            guard hex.unicodeScalars.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") || ($0 >= "A" && $0 <= "F") }),
                  let code = UInt32(hex, radix: 16) else { return nil }
            i += 4
            return code
        }

        private mutating func readString() -> String? {
            guard peek() == "\"" else { return nil }
            i += 1
            var out = String.UnicodeScalarView()
            while true {
                guard let c = peek() else { return nil }
                i += 1
                if c == "\"" { return String(out) }
                if c == "\\" {
                    guard let esc = peek() else { return nil }
                    i += 1
                    switch esc {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        guard let code = readHex4() else { return nil }
                        if (0xD800...0xDBFF).contains(code) {
                            // a surrogate pair: the low half must follow as another \u escape
                            guard peek() == "\\" else { return nil }
                            i += 1
                            guard peek() == "u" else { return nil }
                            i += 1
                            guard let low = readHex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
                            let combined = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            guard let scalar = Unicode.Scalar(combined) else { return nil }
                            out.append(scalar)
                        } else {
                            guard let scalar = Unicode.Scalar(code) else { return nil }
                            out.append(scalar)
                        }
                    default:
                        return nil
                    }
                } else if c.value < 0x20 {
                    return nil // a raw control character is never valid inside a JSON string
                } else {
                    out.append(c)
                }
            }
        }

        private mutating func readArray() -> V2JoinJSON? {
            i += 1 // [
            var out: [V2JoinJSON] = []
            skipWhitespace()
            if peek() == "]" {
                i += 1
                return .array(out)
            }
            while true {
                skipWhitespace()
                guard let item = readValue() else { return nil }
                out.append(item)
                skipWhitespace()
                guard let sep = peek() else { return nil }
                i += 1
                if sep == "," { continue }
                if sep == "]" { return .array(out) }
                return nil
            }
        }

        private mutating func readObject() -> V2JoinJSON? {
            i += 1 // {
            var out: [Member] = []
            var seen: Set<String> = []
            skipWhitespace()
            if peek() == "}" {
                i += 1
                return .object(out)
            }
            while true {
                skipWhitespace()
                guard let key = readString(), !seen.contains(key) else { return nil }
                seen.insert(key)
                skipWhitespace()
                guard peek() == ":" else { return nil }
                i += 1
                skipWhitespace()
                guard let value = readValue() else { return nil }
                out.append(Member(key, value))
                skipWhitespace()
                guard let sep = peek() else { return nil }
                i += 1
                if sep == "," { continue }
                if sep == "}" { return .object(out) }
                return nil
            }
        }
    }
}
