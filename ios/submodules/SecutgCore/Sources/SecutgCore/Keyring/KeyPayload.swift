import Foundation

/// `secutg://key?<master_b64url>&admin_pk=<ed25519_pk_b64url>&mode=<auto|manual>` — PLAN.md 3.6 / 3.34.1
///
/// `admin_pk` arrived with stage 5, `mode` with 3.34. Both are **appended**, never inserted, and both are
/// optional on the way in: strip `mode` and what is left is exactly what an older build sent, so an old QR code
/// still scans. A payload carrying no `mode` reads as `manual` — the conservative half, since a device that
/// assumed `auto` would sit waiting for a key nobody is going to send it. A `mode` nobody recognises is refused
/// outright rather than defaulted: that is a payload from a build that knows something this one does not.
public struct KeyPayload: Equatable {
    public static let prefix = "secutg://key?"
    private static let adminParam = "&admin_pk="
    private static let modeParam = "&mode="

    public let masterKey: [UInt8]
    public let adminPk: [UInt8]?
    /// PLAN.md 3.34.1: a property of the key, so it rides with the key rather than being set per device
    public let mode: Rekey.KeyMode

    public static func build(masterKey: [UInt8], adminPk: [UInt8]?, mode: Rekey.KeyMode? = nil) -> String {
        return prefix + Base64Url.encode(masterKey)
            + (adminPk.map { adminParam + Base64Url.encode($0) } ?? "")
            + (mode.map { modeParam + $0.rawValue } ?? "")
    }

    /// nil for anything that is not a well-formed payload with a 32-byte master. PLAN.md 3.38: this is the
    /// pre-3.38 parser, unchanged in behaviour — a password-protected payload is nil here, so no existing
    /// caller can mistake one for a key. Callers that know about 群密码 use `parse(_:allowLocked:)`.
    public static func parse(_ text: String) -> KeyPayload? {
        guard let split = split(text) else { return nil }
        return plain(split)
    }

    public static func buildLocked(_ fields: GroupPasswordLockedFields, adminPk: [UInt8]?, mode: Rekey.KeyMode? = nil) -> String {
        return prefix + GroupPassword.buildLockedHead(fields) + tail(adminPk: adminPk, mode: mode)
    }

    /// PLAN.md 3.38 opt-in parser (Web `parseKeyPayload(text, { allowLocked: true })`). A plain payload comes back
    /// as `.plain` exactly as `parse(_:)` would return it; a password-protected one as `.locked`, which never
    /// carries a master. `allowLocked: false` is `parse(_:)` wrapped in `.plain`.
    public static func parse(_ text: String, allowLocked: Bool) -> AnyKeyPayload? {
        guard let split = split(text) else { return nil }
        if split.head.hasPrefix(GroupPassword.lockedHeadPrefix) {
            guard allowLocked, let fields = GroupPassword.parseLockedHead(split.head),
                  let adminPk = adminPk(split.adminText) else { return nil }
            return .locked(LockedKeyPayload(fields: fields, adminPk: adminPk, mode: split.mode))
        }
        return plain(split).map(AnyKeyPayload.plain)
    }

    private static func tail(adminPk: [UInt8]?, mode: Rekey.KeyMode?) -> String {
        return (adminPk.map { adminParam + Base64Url.encode($0) } ?? "") + (mode.map { modeParam + $0.rawValue } ?? "")
    }

    private struct Split {
        let head: String
        /// nil when there was no `&admin_pk=` at all
        let adminText: String?
        let mode: Rekey.KeyMode
    }

    private static func split(_ text: String) -> Split? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        var rest = String(trimmed.dropFirst(prefix.count))
        // `mode` is last on the wire, so it comes off first; what remains is exactly what older builds sent.
        var mode = Rekey.KeyMode.manual
        if let range = rest.range(of: modeParam) {
            guard let parsed = Rekey.KeyMode(rawValue: String(rest[range.upperBound...])) else { return nil }
            mode = parsed
            rest = String(rest[..<range.lowerBound])
        }
        let parts = rest.components(separatedBy: adminParam)
        let adminText = parts.count > 1 ? parts.dropFirst().joined(separator: adminParam) : nil
        return Split(head: parts[0], adminText: adminText, mode: mode)
    }

    /// `.some(nil)` = no admin key given; nil = present but not a 32-byte key (reject the payload).
    private static func adminPk(_ adminText: String?) -> [UInt8]?? {
        guard let adminText = adminText else { return .some(nil) }
        guard let pk = Base64Url.decode(adminText), pk.count == 32 else { return nil }
        return .some(pk)
    }

    private static func plain(_ split: Split) -> KeyPayload? {
        guard let master = Base64Url.decode(split.head), master.count == KeyDerivation.masterKeyBytes,
              let adminPk = adminPk(split.adminText) else { return nil }
        return KeyPayload(masterKey: master, adminPk: adminPk, mode: split.mode)
    }
}

/// PLAN.md 3.38: a password-protected payload has the same prefix and the same `&admin_pk=` / `&mode=` tail, but
/// its head is `pw=1&kdf=…&ops=…&mem=…&salt=…&wrap=…[&hist=…]` instead of a master. An older build reads that
/// head as a bad master and rejects the whole payload — the intended failure.
public struct LockedKeyPayload: Equatable {
    public let fields: GroupPasswordLockedFields
    public let adminPk: [UInt8]?
    public let mode: Rekey.KeyMode
}

public enum AnyKeyPayload: Equatable {
    case plain(KeyPayload)
    case locked(LockedKeyPayload)
}
