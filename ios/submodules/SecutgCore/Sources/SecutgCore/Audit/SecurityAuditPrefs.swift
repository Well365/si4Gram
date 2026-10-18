import Foundation

/// PLAN.md 3.46: the little the check-up remembers, per account and on this device only — which findings were
/// ignored and when, the group-key age limit set on the page, and when the last whole-keyring backup was made
/// (check 7). None of it is a key or a message; all of it goes with the emergency wipe (3.16). Each app keeps the
/// three strings in its own local preferences; this codec is the part both Apple clients share, so a malformed
/// record reads the same way everywhere: as "nothing".
public enum SecurityAuditPrefs {
    public static func ignoredKey(accountKey: String) -> String { return "secutg.audit.ignored.\(accountKey)" }
    public static func groupKeyDaysKey(accountKey: String) -> String { return "secutg.audit.groupKeyMaxAgeDays.\(accountKey)" }
    public static func lastBackupKey(accountKey: String) -> String { return "secutg.audit.lastBackupMs.\(accountKey)" }

    /// Every key this account owns, for the wipe. Exact keys, never a prefix sweep: account keys are decimal ids,
    /// and one can be a literal prefix of another.
    public static func allKeys(accountKey: String) -> [String] {
        return [ignoredKey(accountKey: accountKey), groupKeyDaysKey(accountKey: accountKey), lastBackupKey(accountKey: accountKey)]
    }

    /// `{"<finding id>": <ms>}`; anything that is not that shape reads as empty, a bad entry is dropped on its own.
    public static func parseIgnored(_ text: String?) -> [String: Int64] {
        guard let data = text?.data(using: .utf8), let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else { return [:] }
        var out: [String: Int64] = [:]
        for (id, value) in object {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue == number.doubleValue.rounded() else { continue }
            out[id] = number.int64Value
        }
        return out
    }

    public static func serializeIgnored(_ ignored: [String: Int64]) -> String {
        let object = ignored.mapValues { NSNumber(value: $0) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// A positive whole number of days, else the default (90).
    public static func parseGroupKeyDays(_ text: String?) -> Int {
        guard let text = text, let value = Int(text), value > 0 else { return SecurityAudit.defaultGroupKeyMaxAgeDays }
        return value
    }

    /// The page's stepper: whole days, at least 1. nil = not a value to store.
    public static func serializeGroupKeyDays(_ days: Int) -> String? {
        return days > 0 ? String(days) : nil
    }

    public static func parseLastBackupMs(_ text: String?) -> Int64? {
        guard let text = text, let value = Int64(text), value > 0 else { return nil }
        return value
    }
}
