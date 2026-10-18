import Foundation

/// SECUTG: secuTG strings follow the Telegram in-app language (PLAN.md 3.12).
/// The table is generated into `SecutgStrings.generated.swift`; the UI layer sets `currentLanguageCode`
/// from the presentation data whenever the language changes, and everything else reads `string(_:)`.
public enum SecutgL10n {
    public enum Lang: String {
        case en = "en"
        case zhHans = "zh-Hans"
        case zhHant = "zh-Hant"
    }

    private static let lock = NSLock()
    private static var _currentLanguageCode: String = "en"

    /// Telegram's current language code (`PresentationStrings.baseLanguageCode` / `primaryComponent.languageCode`).
    public static var currentLanguageCode: String {
        get { lock.lock(); defer { lock.unlock() }; return _currentLanguageCode }
        set { lock.lock(); _currentLanguageCode = newValue; lock.unlock() }
    }

    public static var currentLang: Lang { return map(currentLanguageCode) }

    /// Anything Chinese → Simplified unless it is a Traditional variant; everything else → English.
    public static func map(_ code: String?, base: String? = nil) -> Lang {
        for candidate in [code, base] {
            guard let c = candidate?.lowercased(), !c.isEmpty else { continue }
            if c.hasPrefix("zh") || c == "taiwan" || c == "hongkong" {
                let traditional = ["hant", "-tw", "_tw", "-hk", "_hk", "-mo", "_mo", "taiwan", "hongkong"]
                return traditional.contains(where: { c.contains($0) }) ? .zhHant : .zhHans
            }
        }
        return .en
    }

    /// Resolves a key; a missing language or key falls back to English, never to the key name.
    public static func string(_ key: String, _ vars: [String: String] = [:], lang: Lang? = nil) -> String {
        let table = SecutgStringsTable.table[key]
        let template = table?[(lang ?? currentLang).rawValue] ?? table?[Lang.en.rawValue] ?? ""
        return substitute(template, vars)
    }

    public static func string(_ key: String, languageCode: String?, _ vars: [String: String] = [:]) -> String {
        return string(key, vars, lang: map(languageCode))
    }

    private static func substitute(_ template: String, _ vars: [String: String]) -> String {
        guard !vars.isEmpty else { return template }
        var out = template
        for (name, value) in vars {
            out = out.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return out
    }
}
