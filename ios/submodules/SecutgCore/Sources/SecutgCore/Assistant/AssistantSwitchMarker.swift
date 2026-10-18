import Foundation

/// PLAN.md 3.45.2 "开关" / implementation plan C1.1: the `enabled` file, made so that only secuTG can write a valid one.
///
/// The file is the switch's on-disk mark, but any process running as the user can create a file, and the switch
/// opens a socket that hands out decrypted words and sends as the user. So a line only counts when it carries an
/// HMAC-SHA256 over the account id, keyed by a 32-byte secret that lives in the Keychain entry of the app that
/// turned the switch on (the glue, `SecutgAssistantSwitch`). Turning the switch off deletes that secret, so a copy
/// of an old file taken while it was on stops counting too. A file from before this format (`1`) reads as off.
///
/// One line per account that has the switch on: `v1 <account peer id> <hex tag>`.
public enum AssistantSwitchMarker {
    public static let keyBytes = 32
    private static let version = "v1"

    public static func tag(account: Int64, key: [UInt8]) -> String? {
        guard key.count == keyBytes, SecutgSodium.ensureReady() else { return nil }
        let mac = V2Suite.hmac(key32: key, data: Array("secutg-assistant-enabled|\(version)|\(account)".utf8))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    public static func line(account: Int64, key: [UInt8]) -> String? {
        return tag(account: account, key: key).map { "\(version) \(account) \($0)" }
    }

    /// Does `content` hold a valid line for `account` under `key`?
    public static func isValid(_ content: String?, account: Int64, key: [UInt8]) -> Bool {
        guard let content, let expected = tag(account: account, key: key) else { return false }
        return lines(content).contains { parts in
            parts.count == 3 && parts[0] == version && Int64(parts[1]) == account
                && V2Suite.constantTimeEqual(Array(parts[2].utf8), Array(expected.utf8))
        }
    }

    /// `content` with `account`'s line (re)written under `key`; other accounts' lines are kept as they are.
    public static func adding(account: Int64, key: [UInt8], to content: String?) -> String? {
        guard let line = line(account: account, key: key) else { return nil }
        return (others(account, in: content) + [line]).joined(separator: "\n") + "\n"
    }

    /// `content` without `account`'s line; nil when no line is left (the file should go).
    public static func removing(account: Int64, from content: String?) -> String? {
        let kept = others(account, in: content)
        return kept.isEmpty ? nil : kept.joined(separator: "\n") + "\n"
    }

    private static func lines(_ content: String) -> [[Substring]] {
        return content.split(whereSeparator: \.isNewline).map { $0.split(separator: " ") }
    }

    /// Well-formed lines of other accounts; anything else (this account's line, an old `1`, garbage) is dropped.
    private static func others(_ account: Int64, in content: String?) -> [String] {
        guard let content else { return [] }
        return lines(content).filter { parts in
            parts.count == 3 && parts[0] == version && Int64(parts[1]).map { $0 != account } == true
        }.map { $0.joined(separator: " ") }
    }
}
