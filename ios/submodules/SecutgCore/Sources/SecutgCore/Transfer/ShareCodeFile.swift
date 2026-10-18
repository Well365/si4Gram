import Foundation

/// PLAN.md 3.39.14: a `V2Q:` clone code or a `K1Q:` quick-share code carried as a FILE instead of a camera — for the
/// device that has no camera (a Mac Studio cannot scan a phone whose code page blocks screenshots and has no copy
/// button). The file holds exactly the QR's text (UTF-8, one line, no trailing newline), so holding it is holding the
/// key, exactly like the QR; a V2Q's ten minutes are enforced by its own `expires_ms`, not by the file.
///
/// The rules every client shares (name, sanitising, what the reader accepts) live here so the UI only asks.
public enum ShareCodeFile {
    public enum Kind: Equatable {
        /// `V2Q:` — PLAN.md 3.39.13 clone of a 1v1 chat
        case v2q
        /// `K1Q:` — PLAN.md 3.14.1 one chat's keys (Saved Messages / a group)
        case k1q

        public var fileExtension: String {
            switch self {
            case .v2q: return "secutg-v2q"
            case .k1q: return "secutg-k1q"
            }
        }
    }

    // SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-04): kept as the fallback for callers that do not pass their own
    // `namePrefix` to `fileName(...)` below; SecutgCore cannot import TelegramCore / call `SecutgL10n`, so the
    // iOS UI layer composes "Si4Gram-" + `SecutgL10n.string("SecutgShareFileNamePart")` and passes it in instead.
    // Importing keys on the file's content and its extension (`.secutg-v2q` / `.secutg-k1q`), never on this
    // prefix, so files written under the old or the new prefix both import unchanged.
    public static let namePrefix = "secuTG-分享码"
    /// Characters of the chat name kept in the file name.
    public static let maxChatNameCharacters = 40
    /// A V2Q / K1Q fits a version-40 QR (≤ 2953 bytes); anything far bigger is not one, and is not read whole.
    public static let maxFileBytes = 16 * 1024

    /// What the text is, by prefix; nil for anything else (`SecutgShareFileBad`).
    public static func kind(of text: String) -> Kind? {
        if V2JoinText.isV2JoinText(text) { return .v2q }
        if QuickShare.isQuickShare(text) { return .k1q }
        return nil
    }

    /// The chat name as it may stand in a file name: no `/ \ : * ? " < > |`, no control characters, whitespace runs
    /// collapsed to one space, trimmed, at most `maxChatNameCharacters`; `fallback` (the peer id) when nothing is left.
    public static func sanitizeChatName(_ name: String, fallback: String) -> String {
        let forbidden = Set("/\\:*?\"<>|")
        var out = ""
        var pendingSpace = false
        for scalar in name.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !out.isEmpty
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar) || forbidden.contains(Character(scalar)) {
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.unicodeScalars.append(scalar)
        }
        let capped = String(out.prefix(maxChatNameCharacters)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? fallback : capped
    }

    /// `<namePrefix>-<chat name>-<yyyyMMdd-HHmm>.secutg-v2q` (or `.secutg-k1q`), in the device's own time zone.
    /// `namePrefix` defaults to `namePrefix` above; callers that can resolve a localized / branded prefix (see
    /// that property's note) pass their own instead. Either way the file imports the same — see that note.
    public static func fileName(kind: Kind, chatName: String, fallback: String, date: Date, timeZone: TimeZone = .current, namePrefix: String = Self.namePrefix) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let name = sanitizeChatName(chatName, fallback: fallback)
        return "\(namePrefix)-\(name)-\(formatter.string(from: date)).\(kind.fileExtension)"
    }

    /// The file's bytes: the code text trimmed, UTF-8, no trailing newline.
    public static func contents(_ text: String) -> Data {
        return Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    /// The code text read back from a file: nil when the file is too big or not UTF-8. A leading BOM and surrounding
    /// whitespace are dropped; what is left is NOT checked here — it goes to the same import as a scanned code.
    public static func readText(_ data: Data) -> String? {
        guard data.count <= maxFileBytes, var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
