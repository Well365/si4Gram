import Foundation

/// v1.4 section 17's K2 carry secret: "a 32-byte random carry secret, Crockford Base32 is 52
/// characters, in 13 groups". Ported from `src/secutg/v2/backup/crockford.ts` and
/// `org.telegram.secutg.v2.backup.Crockford`.
///
/// Crockford's own alphabet excludes I/L/O/U specifically to avoid visual confusion with 1/1/0/
/// (profanity); decoding is deliberately CASE-INSENSITIVE and forgives the two substitutions
/// Crockford's own spec calls out (O to 0, I/L to 1). It does NOT implement Crockford's optional
/// check-symbol variant.
public enum V2Crockford {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let secretBytes = 32
    public static let carrySecretSymbols = 52
    private static let groupSize = 4

    private static let decodeMap: [Character: Int] = {
        var map: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { map[c] = i }
        // Crockford's own two forgiving substitutions — applied during decode only, never produced
        // by encode.
        map["O"] = 0
        map["I"] = 1
        map["L"] = 1
        return map
    }()

    /// Encodes exactly 32 bytes as 52 Crockford Base32 symbols, grouped into 13 groups of 4 with
    /// "-" separators. nil if bytes is not exactly secretBytes long.
    public static func encodeCarrySecret(_ bytes: [UInt8]) -> String? {
        guard bytes.count == secretBytes else { return nil }
        let symbols = encodeRaw(bytes, symbolCount: carrySecretSymbols)
        var out = ""
        var i = symbols.startIndex
        while i < symbols.endIndex {
            if i != symbols.startIndex { out += "-" }
            let end = symbols.index(i, offsetBy: groupSize, limitedBy: symbols.endIndex) ?? symbols.endIndex
            out += symbols[i..<end]
            i = end
        }
        return out
    }

    /// Decodes a carry secret typed/pasted by a user — case-insensitive, forgives "-" separators in
    /// any position (or none at all) and Crockford's own O/I/L substitutions. nil for anything that
    /// doesn't decode to exactly 32 bytes.
    public static func decodeCarrySecret(_ text: String) -> [UInt8]? {
        var stripped = ""
        for c in text.uppercased() {
            if c.isNumber || (c >= "A" && c <= "Z") { stripped.append(c) }
        }
        guard stripped.count == carrySecretSymbols else { return nil }
        return decodeRaw(stripped, byteCount: secretBytes)
    }

    private static func encodeRaw(_ bytes: [UInt8], symbolCount: Int) -> String {
        var buffer = 0
        var bits = 0
        var out = ""
        for b in bytes {
            buffer = (buffer << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 0x1f])
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 0x1f]) }
        while out.count < symbolCount { out.append(alphabet[0]) }
        return out
    }

    private static func decodeRaw(_ symbols: String, byteCount: Int) -> [UInt8]? {
        var buffer = 0
        var bits = 0
        var out: [UInt8] = []
        for c in symbols {
            guard let value = decodeMap[c] else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        guard out.count >= byteCount else { return nil }
        return Array(out.prefix(byteCount))
    }
}
