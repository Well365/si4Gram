import Foundation

/// `E1:<key_id>:<nonce_b64url>:<ct_b64url>` — PLAN.md 3.2; byte-identical rules to Web A / Android.
public enum E1Format {
    public static let prefix = "E1"
    public static let wireMaxChars = 4096
    public static let nonceBytes = 24
    public static let tagBytes = 16
    public static let keyBytes = 32

    public struct Parsed: Equatable {
        public let keyId: String
        public let nonce: [UInt8]
        public let ciphertext: [UInt8]
    }

    private static let keyIdRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,64}$")
    private static let e1Regex = try! NSRegularExpression(pattern: "^E1:([A-Za-z0-9._-]{1,64}):([A-Za-z0-9_-]+):([A-Za-z0-9_-]+)$")

    public static func isValidKeyId(_ keyId: String) -> Bool {
        return keyIdRegex.wholeMatch(keyId) != nil
    }

    /// Purely syntactic; a wire longer than Telegram's limit can never be ours.
    public static func isEncrypted(_ wire: String) -> Bool {
        return wire.utf16.count <= wireMaxChars && e1Regex.wholeMatch(wire) != nil
    }

    public static func parse(_ wire: String) -> Parsed? {
        guard wire.utf16.count <= wireMaxChars, let match = e1Regex.wholeMatch(wire) else { return nil }
        let groups = match.groups(in: wire)
        guard groups.count == 3,
              let nonce = Base64Url.decode(groups[1]), let ct = Base64Url.decode(groups[2]),
              nonce.count == nonceBytes, ct.count >= tagBytes else { return nil }
        return Parsed(keyId: groups[0], nonce: nonce, ciphertext: ct)
    }

    public static func serialize(keyId: String, nonce: [UInt8], ciphertext: [UInt8]) -> String {
        return "\(prefix):\(keyId):\(Base64Url.encode(nonce)):\(Base64Url.encode(ciphertext))"
    }
}

extension NSRegularExpression {
    /// Match against the whole string (the patterns are anchored) — nil when it does not match.
    func wholeMatch(_ text: String) -> NSTextCheckingResult? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = firstMatch(in: text, options: [], range: range), match.range == range else { return nil }
        return match
    }
}

extension NSTextCheckingResult {
    /// Capture groups 1…n as Swift strings.
    func groups(in text: String) -> [String] {
        guard numberOfRanges > 1 else { return [] }
        return (1..<numberOfRanges).compactMap { index in
            guard let range = Range(self.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }
}
