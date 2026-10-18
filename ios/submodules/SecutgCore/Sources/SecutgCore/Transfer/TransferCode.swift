import Clibsodium
import Foundation

/// Transfer code of a keyring export (PLAN.md 3.14). 20 random bytes shown as 32 Crockford-base32
/// characters: the user types or reads it out, so it avoids the characters that look alike, and it
/// carries 160 bits — enough that hashing it once is a safe key derivation, with no argon2 needed
/// (a user-chosen passphrase would be the weakest part of a file that holds every key this device has).
/// Byte-identical to Web A `src/secutg/transfer/code.ts`.
public enum TransferCode {
    public static let codeBytes = 20
    public static let kdfContext = "tg-e1-transfer-v1"

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let codeChars = 32
    private static let group = 4
    /// Crockford leniency: what someone is likely to type instead of the real character
    private static let confusable: [Character: Character] = ["I": "1", "L": "1", "O": "0", "U": "V"]

    public static func generate() -> String {
        return format(encodeBase32(SecutgSodium.randomBytes(codeBytes)))
    }

    /// Uppercase, separators dropped, regrouped four by four
    public static func format(_ code: String) -> String {
        let plain = code.filter { $0.isLetter || $0.isNumber }.uppercased()
        var out = [String]()
        var index = plain.startIndex
        while index < plain.endIndex {
            let end = plain.index(index, offsetBy: group, limitedBy: plain.endIndex) ?? plain.endIndex
            out.append(String(plain[index..<end]))
            index = end
        }
        return out.joined(separator: "-")
    }

    /// Accepts the code with or without separators and in any case; nil when it is not a valid code
    public static func parse(_ text: String) -> [UInt8]? {
        let plain = String(text.filter { $0.isLetter || $0.isNumber }.uppercased().map { confusable[$0] ?? $0 })
        guard plain.count == codeChars else { return nil }
        return decodeBase32(plain)
    }

    /// blake2b(32, context || code_bytes). The context defaults to 3.14's `tg-e1-transfer-v1`; PLAN.md 3.39.2's V2Q
    /// join code passes its own (`V2JoinText.kdfContext`, `tg-v2-join-v1`) — same construction, different domain, so
    /// a code shown for one purpose never derives the key of the other. Byte-identical to Web A `deriveTransferKey`.
    public static func deriveKey(_ code: [UInt8], context: String = kdfContext) throws -> [UInt8] {
        guard code.count == codeBytes else { throw SecutgCryptoError.invalidKey }
        SecutgSodium.ensureReady()
        let input = Array(context.utf8) + code
        var out = [UInt8](repeating: 0, count: 32)
        guard crypto_generichash(&out, out.count, input, UInt64(input.count), nil, 0) == 0 else {
            throw SecutgCryptoError.sodiumFailure("generichash failed")
        }
        return out
    }

    private static func encodeBase32(_ bytes: [UInt8]) -> String {
        var bits = 0
        var value = 0
        var out = ""
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(value >> bits) & 31])
            }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return out
    }

    private static func decodeBase32(_ text: String) -> [UInt8]? {
        var bits = 0
        var value = 0
        var out = [UInt8]()
        for char in text {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xff))
            }
        }
        return out.count == codeBytes ? out : nil
    }
}
