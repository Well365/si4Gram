import Foundation

/// PLAN.md 3.45.2: the JSON value every line of the assistant's local control socket is made of.
///
/// A value type of our own rather than `JSONSerialization` / `Codable`, for three reasons that all come from the
/// protocol being a contract with another program (secuTG-smart-mate, Python):
/// - the encoding is deterministic (keys sorted, no whitespace, no escaped slashes), so a fixture line produced
///   here is byte-for-byte what the client puts on the wire;
/// - a boolean is never confused with a number (`NSNumber` bridging makes that a platform question);
/// - the parser is bounded (nesting depth) and never throws on input it was not built for — a peer on the socket
///   is untrusted input, and a bad line must turn into an error reply, never a crash.
public enum AssistantJSON: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AssistantJSON])
    case object([String: AssistantJSON])

    public static let maxDepth = 64

    // MARK: accessors

    public subscript(key: String) -> AssistantJSON? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// Integers only. A double is accepted when it is integral and in range, because some JSON writers emit `5.0`.
    public var int64Value: Int64? {
        switch self {
        case let .int(value):
            return value
        case let .double(value):
            guard value.isFinite, value.rounded() == value, abs(value) < 9.0e15 else { return nil }
            return Int64(value)
        default:
            return nil
        }
    }

    public var objectValue: [String: AssistantJSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [AssistantJSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// `.string(x)` or `.null`: the shape of an optional text field.
    public static func optionalString(_ value: String?) -> AssistantJSON {
        return value.map { .string($0) } ?? .null
    }

    /// `.int(x)` or `.null`.
    public static func optionalInt(_ value: Int64?) -> AssistantJSON {
        return value.map { .int($0) } ?? .null
    }

    // MARK: encoding

    /// Compact, keys sorted by their UTF-8 bytes, never contains a raw newline — one NDJSON line.
    public func encoded() -> String {
        var out = ""
        AssistantJSON.write(self, into: &out)
        return out
    }

    public func encodedData() -> Data {
        return Data(encoded().utf8)
    }

    private static func write(_ value: AssistantJSON, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case let .bool(flag):
            out += flag ? "true" : "false"
        case let .int(number):
            out += String(number)
        case let .double(number):
            out += number.isFinite ? String(format: "%.17g", number) : "null"
        case let .string(text):
            writeString(text, into: &out)
        case let .array(items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case let .object(fields):
            out += "{"
            let keys = fields.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                write(fields[key] ?? .null, into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: parsing

    public enum ParseError: Error, Equatable {
        case invalidUTF8
        case unexpectedEnd
        case unexpectedCharacter(offset: Int)
        case tooDeep
        case trailingData(offset: Int)
    }

    public static func parse(_ data: Data) throws -> AssistantJSON {
        guard String(data: data, encoding: .utf8) != nil else { throw ParseError.invalidUTF8 }
        var parser = Parser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    public static func parse(_ text: String) throws -> AssistantJSON {
        return try parse(Data(text.utf8))
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func parseDocument() throws -> AssistantJSON {
            skipWhitespace()
            let value = try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { throw ParseError.trailingData(offset: index) }
            return value
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func peek() throws -> UInt8 {
            guard index < bytes.count else { throw ParseError.unexpectedEnd }
            return bytes[index]
        }

        mutating func expect(_ literal: String, value: AssistantJSON) throws -> AssistantJSON {
            let expected = Array(literal.utf8)
            guard index + expected.count <= bytes.count else { throw ParseError.unexpectedEnd }
            guard Array(bytes[index..<index + expected.count]) == expected else {
                throw ParseError.unexpectedCharacter(offset: index)
            }
            index += expected.count
            return value
        }

        mutating func parseValue(depth: Int) throws -> AssistantJSON {
            guard depth < AssistantJSON.maxDepth else { throw ParseError.tooDeep }
            switch try peek() {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): return try expect("true", value: .bool(true))
            case UInt8(ascii: "f"): return try expect("false", value: .bool(false))
            case UInt8(ascii: "n"): return try expect("null", value: .null)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw ParseError.unexpectedCharacter(offset: index)
            }
        }

        mutating func parseObject(depth: Int) throws -> AssistantJSON {
            index += 1
            var fields: [String: AssistantJSON] = [:]
            skipWhitespace()
            if try peek() == UInt8(ascii: "}") { index += 1; return .object(fields) }
            while true {
                skipWhitespace()
                guard try peek() == UInt8(ascii: "\"") else { throw ParseError.unexpectedCharacter(offset: index) }
                let key = try parseString()
                skipWhitespace()
                guard try peek() == UInt8(ascii: ":") else { throw ParseError.unexpectedCharacter(offset: index) }
                index += 1
                skipWhitespace()
                fields[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                let next = try peek()
                index += 1
                if next == UInt8(ascii: "}") { return .object(fields) }
                guard next == UInt8(ascii: ",") else { throw ParseError.unexpectedCharacter(offset: index - 1) }
            }
        }

        mutating func parseArray(depth: Int) throws -> AssistantJSON {
            index += 1
            var items: [AssistantJSON] = []
            skipWhitespace()
            if try peek() == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                let next = try peek()
                index += 1
                if next == UInt8(ascii: "]") { return .array(items) }
                guard next == UInt8(ascii: ",") else { throw ParseError.unexpectedCharacter(offset: index - 1) }
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw ParseError.unexpectedEnd }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw ParseError.unexpectedCharacter(offset: index)
                }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        mutating func parseString() throws -> String {
            index += 1
            var raw: [UInt8] = []
            while true {
                let byte = try peek()
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let text = String(bytes: raw, encoding: .utf8) else { throw ParseError.invalidUTF8 }
                    return text
                case UInt8(ascii: "\\"):
                    let escape = try peek()
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): raw.append(0x22)
                    case UInt8(ascii: "\\"): raw.append(0x5C)
                    case UInt8(ascii: "/"): raw.append(0x2F)
                    case UInt8(ascii: "b"): raw.append(0x08)
                    case UInt8(ascii: "f"): raw.append(0x0C)
                    case UInt8(ascii: "n"): raw.append(0x0A)
                    case UInt8(ascii: "r"): raw.append(0x0D)
                    case UInt8(ascii: "t"): raw.append(0x09)
                    case UInt8(ascii: "u"):
                        raw.append(contentsOf: try parseUnicodeEscape())
                    default:
                        throw ParseError.unexpectedCharacter(offset: index - 1)
                    }
                default:
                    guard byte >= 0x20 else { throw ParseError.unexpectedCharacter(offset: index - 1) }
                    raw.append(byte)
                }
            }
        }

        /// `\uXXXX`, joining a surrogate pair; a lone surrogate becomes U+FFFD rather than an error.
        mutating func parseUnicodeEscape() throws -> [UInt8] {
            var code = try parseHex4()
            if (0xD800...0xDBFF).contains(code) {
                if index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    let save = index
                    index += 2
                    let low = try parseHex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = save
                        code = 0xFFFD
                    }
                } else {
                    code = 0xFFFD
                }
            } else if (0xDC00...0xDFFF).contains(code) {
                code = 0xFFFD
            }
            let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
            return Array(String(Character(scalar)).utf8)
        }

        mutating func parseNumber() throws -> AssistantJSON {
            let start = index
            var isInteger = true
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            var digits = 0
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1; digits += 1 }
            guard digits > 0 else { throw ParseError.unexpectedCharacter(offset: index) }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                isInteger = false
                index += 1
                var fraction = 0
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1; fraction += 1 }
                guard fraction > 0 else { throw ParseError.unexpectedCharacter(offset: index) }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                isInteger = false
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                var exponent = 0
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1; exponent += 1 }
                guard exponent > 0 else { throw ParseError.unexpectedCharacter(offset: index) }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if isInteger, let value = Int64(text) { return .int(value) }
            guard let value = Double(text) else { throw ParseError.unexpectedCharacter(offset: start) }
            return .double(value)
        }
    }
}
