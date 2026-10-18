import Foundation

/// PLAN.md 3.52: the 智能助手服务部署 page's "助手源码（GitHub）" row shows `distribution.assistant_source` from the
/// bundled secutg.json only when it is a well-formed `https://` URL. Unset today — the user publishes the
/// repository later — so absent or malformed values fall back to `SecutgAssistantDeploySourcePending`.
/// Kept apart from `RelaySourceUrl` on purpose: the relay feature stays an independent module (PLAN.md 3.48.0).
public enum AssistantSourceUrl {
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
