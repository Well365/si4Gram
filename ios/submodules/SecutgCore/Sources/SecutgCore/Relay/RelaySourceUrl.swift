import Foundation

/// PLAN.md 3.48.8: the relay guide page's "源码（GitHub）" row shows `distribution.relay_source` from the bundled
/// secutg.json only when it is a well-formed `https://` URL — never `http://`, never a bare host, never garbage
/// that would open somewhere unexpected. The field is unset today (用户原话："github 仓库后面我自己会加上。你先预留
/// 链接的栏目" — the repo link is reserved for later), so this guards whatever gets filled in later just as much as
/// it guards today's nil. Absent or malformed, the caller falls back to `SecutgRelayGuideSourcePending`
/// ("源码地址即将公布") instead of showing a dead or dangerous link.
///
/// A pure, standalone function on purpose (PLAN.md 3.48.0 rule 1: independent module) — it does not reach into
/// `SecutgConfigLoader` or `SecutgConfigHolder` itself; callers pass the already-resolved
/// `DistributionConfig.relaySource` string in.
public enum RelaySourceUrl {
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
