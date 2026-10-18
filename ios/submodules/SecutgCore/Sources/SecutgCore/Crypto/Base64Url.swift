import Foundation

/// base64url without padding, byte-identical to libsodium's URLSAFE_NO_PADDING used by Web A.
public enum Base64Url {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
    private static let lookup: [Int8] = {
        var table = [Int8](repeating: -1, count: 128)
        for (index, char) in alphabet.enumerated() { table[Int(char)] = Int8(index) }
        return table
    }()

    public static func encode(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity((bytes.count * 4 + 2) / 3)
        var i = 0
        while i + 3 <= bytes.count {
            let n = (Int(bytes[i]) << 16) | (Int(bytes[i + 1]) << 8) | Int(bytes[i + 2])
            out.append(alphabet[(n >> 18) & 63]); out.append(alphabet[(n >> 12) & 63])
            out.append(alphabet[(n >> 6) & 63]); out.append(alphabet[n & 63])
            i += 3
        }
        let rest = bytes.count - i
        if rest == 1 {
            let n = Int(bytes[i]) << 16
            out.append(alphabet[(n >> 18) & 63]); out.append(alphabet[(n >> 12) & 63])
        } else if rest == 2 {
            let n = (Int(bytes[i]) << 16) | (Int(bytes[i + 1]) << 8)
            out.append(alphabet[(n >> 18) & 63]); out.append(alphabet[(n >> 12) & 63]); out.append(alphabet[(n >> 6) & 63])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// nil for anything that is not canonical unpadded base64url.
    public static func decode(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        let len = chars.count
        if len % 4 == 1 { return nil }
        let full = len / 4
        let rest = len % 4
        var out = [UInt8]()
        out.reserveCapacity(full * 3 + (rest == 2 ? 1 : rest == 3 ? 2 : 0))
        var i = 0
        for _ in 0..<full {
            var n = 0
            for _ in 0..<4 {
                guard let v = value(chars[i]) else { return nil }
                n = (n << 6) | v
                i += 1
            }
            out.append(UInt8((n >> 16) & 0xff)); out.append(UInt8((n >> 8) & 0xff)); out.append(UInt8(n & 0xff))
        }
        if rest == 2 {
            guard let a = value(chars[i]), let b = value(chars[i + 1]), (b & 0x0f) == 0 else { return nil }
            out.append(UInt8(((a << 2) | (b >> 4)) & 0xff))
        } else if rest == 3 {
            guard let a = value(chars[i]), let b = value(chars[i + 1]), let c = value(chars[i + 2]), (c & 0x03) == 0 else { return nil }
            out.append(UInt8(((a << 2) | (b >> 4)) & 0xff))
            out.append(UInt8(((b << 4) | (c >> 2)) & 0xff))
        }
        return out
    }

    private static func value(_ c: UInt8) -> Int? {
        guard c < 128 else { return nil }
        let v = lookup[Int(c)]
        return v < 0 ? nil : Int(v)
    }
}

/// Small helpers shared by the codec and rekey modules.
enum Hex {
    static func encode(_ bytes: ArraySlice<UInt8>) -> String {
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }
}
