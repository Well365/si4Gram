import Foundation
import SecutgCore
import TelegramCore
import SecutgBuildInfo

/// SECUTG: what the "About secuTG" sheet shows (PLAN.md 3.11). Facts come from the bundled secutg.json only
/// (`SecutgConfig.distribution`); the build fingerprint is the constant Bazel wrote into `SecutgBuildInfo`,
/// falling back to the file's `build` field. Without version, channel and build the sheet says "unofficial".
public struct SecutgAbout: Equatable {
    public let lines: [String]
    public let siteURL: URL?
    public let sourceURL: URL?

    public static func current() -> SecutgAbout {
        let base = build(distribution: SecutgConfigHolder.shared.config?.distribution, fingerprint: SecutgBuildInfo.fingerprint)
        // PLAN.md 3.40.6: where this install's API credentials come from, and the api_id — never the hash.
        let api = SecutgApiCredentialsUI.aboutLines()
        guard !api.isEmpty else { return base }
        var lines = base.lines
        lines.insert(contentsOf: api, at: lines.lastIndex(of: "") ?? lines.count)
        return SecutgAbout(lines: lines, siteURL: base.siteURL, sourceURL: base.sourceURL)
    }

    /// PLAN.md 3.15 rule 1: the Settings "Version" row — `{version} · {build}`, from the built-in distribution block
    /// plus the Bazel-injected fingerprint. nil when either half is missing, so the caller shows the unofficial line.
    public static func versionLine() -> String? {
        return versionLine(distribution: SecutgConfigHolder.shared.config?.distribution, fingerprint: SecutgBuildInfo.fingerprint)
    }

    /// PLAN.md 3.52 row 13: the main settings page's short subtitle for "关于 Si4Gram" — `SecutgSettingsVersionShort`
    /// when the bundled file names a version, else `SecutgAboutUnofficial`. Distinct from `versionLine()` above,
    /// which also needs the build fingerprint and reads "{version} · {build}" rather than "版本 {version}".
    public static func shortVersionLine() -> String {
        guard let version = SecutgConfigHolder.shared.config?.distribution?.version, !version.isEmpty else {
            return SecutgL10n.string("SecutgAboutUnofficial")
        }
        return SecutgL10n.string("SecutgSettingsVersionShort", ["version": version])
    }

    static func versionLine(distribution: DistributionConfig?, fingerprint: String) -> String? {
        let buildId = fingerprint.isEmpty ? distribution?.build : fingerprint
        guard let version = distribution?.version, let buildId = buildId, !version.isEmpty, !buildId.isEmpty else { return nil }
        return version + " · " + buildId
    }

    static func build(distribution: DistributionConfig?, fingerprint: String) -> SecutgAbout {
        let buildId = fingerprint.isEmpty ? distribution?.build : fingerprint
        var lines: [String] = []
        let isOfficialShaped = distribution?.version != nil && distribution?.channel != nil && buildId != nil
        if !isOfficialShaped { lines.append(SecutgL10n.string("SecutgAboutUnofficial")) }
        if let version = distribution?.version { lines.append(SecutgL10n.string("SecutgAboutVersion", ["version": version])) }
        if let channel = distribution?.channel {
            let shown = channel == "official" ? SecutgL10n.string("SecutgChannelOfficial") : channel
            lines.append(SecutgL10n.string("SecutgAboutChannel", ["channel": shown]))
        }
        let siteURL = distribution?.site.flatMap(httpURL)
        let sourceURL = distribution?.source.flatMap(httpURL)
        if let site = siteURL { lines.append(SecutgL10n.string("SecutgAboutSite") + ": " + site.absoluteString) }
        if let source = sourceURL { lines.append(SecutgL10n.string("SecutgAboutSource") + ": " + source.absoluteString) }
        if let contact = distribution?.contact { lines.append(SecutgL10n.string("SecutgAboutContact", ["contact": contact])) }
        if let buildId = buildId { lines.append(SecutgL10n.string("SecutgAboutBuild", ["build": buildId])) }
        lines.append("")
        lines.append(SecutgL10n.string("SecutgAboutHint"))
        return SecutgAbout(lines: lines, siteURL: siteURL, sourceURL: sourceURL)
    }

    /// Only http(s) links are offered as tappable actions; anything else stays plain text.
    private static func httpURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}
