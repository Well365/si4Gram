import Foundation

/// SECUTG-HOOK (PLAN.md 3.53): the main settings page's 〔Telegram FAQ〕 row shows `distribution.faq` from the
/// bundled secutg.json only when it is a well-formed `https://` URL — same https-only rule as
/// `RelaySourceUrl` / `AssistantSourceUrl`, kept as its own small validator here (in `Config/`, not the relay or
/// assistant modules) because this field belongs to the general settings page, not to either of those independent
/// features. Absent or malformed, the caller hides the row entirely.
public enum FaqUrl {
    public static func validate(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: trimmed) else { return nil }
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        return trimmed
    }
}
