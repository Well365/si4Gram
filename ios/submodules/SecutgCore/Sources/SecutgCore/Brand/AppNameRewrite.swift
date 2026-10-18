import Foundation

/// SECUTG-HOOK (PLAN.md 3.51 补充 2026-10-05 用户：「三端一起做」)
///
/// Pure, side-effect-free rewrite applied to a localization dictionary (bundled English strings
/// or a downloaded server langpack, both already flattened to `[String: String]` by
/// `dictFromLocalization` / the bundled-strings loader) before it becomes a `PresentationStrings`
/// component. Only entries whose key is listed in `AppNameKeys.keys` (or is a plural variant of a
/// listed key, e.g. `Foo_1` / `Foo_any` for a listed `Foo`) are touched, so the cost is proportional
/// to the small fixed key list, not to the whole dictionary.
///
/// Inside a touched value, every whole-word occurrence of any name in `AppNameKeys.localizedNames`
/// (the upstream app name "Telegram" and its known localized spellings) is replaced with "Si4Gram".
/// Whole-word matching means surrounding `%@` / `%1$@` placeholders and `**bold**` markdown markers
/// are preserved untouched, and names glued to other letters (e.g. "TelegramDesktop") are left alone.
public enum AppNameRewrite {
    /// The brand name shown to users in place of the upstream app name (PLAN.md 3.51).
    public static let replacement = "Si4Gram"

    /// Returns a new dictionary with the listed keys rewritten; `dict` itself is never mutated.
    public static func apply(_ dict: [String: String]) -> [String: String] {
        return apply(dict, keys: AppNameKeys.keys, pluralSuffixes: pluralSuffixes)
    }

    /// Caller-supplied variant of `apply(_:)` (PLAN.md 3.51 补充 2026-10-05 用户：「三端一起做」): lets a
    /// platform that keeps its own key list (e.g. macOS, whose `Localizable.strings` keys and plural
    /// suffixes differ from iOS's) reuse this same whole-word replacement logic without adopting
    /// `AppNameKeys.keys`, which is iOS-specific. `dict` is never mutated.
    public static func apply(_ dict: [String: String], keys: Set<String>, pluralSuffixes: [String] = AppNameRewrite.pluralSuffixes) -> [String: String] {
        guard !dict.isEmpty else {
            return dict
        }
        var result = dict
        for (key, value) in dict {
            guard isListedKey(key, in: keys, pluralSuffixes: pluralSuffixes) else {
                continue
            }
            let rewritten = replaceAppName(in: value)
            if rewritten != value {
                result[key] = rewritten
            }
        }
        return result
    }

    /// Whole-word replacement of every known localized spelling of the app name in `text`.
    public static func replaceAppName(in text: String) -> String {
        var result = text
        for name in AppNameKeys.localizedNames {
            result = replaceWholeWord(name, with: replacement, in: result)
        }
        return result
    }

    // MARK: - Plural variants

    /// `dictFromLocalization` expands a pluralized entry `Foo` into `Foo_zero` / `Foo_1` / `Foo_2` /
    /// `Foo_3_10` / `Foo_many` / `Foo_any` (and the server langpack format additionally uses `Foo_0`).
    /// A listed key's plural siblings must be covered too without listing each suffix explicitly.
    public static let pluralSuffixes = ["_zero", "_1", "_2", "_3_10", "_many", "_any", "_0"]

    /// Caller-supplied variant (PLAN.md 3.51 补充 2026-10-05): whether `key` (or a plural sibling of a
    /// listed base key, using `pluralSuffixes`) is in `keys`.
    public static func isListedKey(_ key: String, in keys: Set<String>, pluralSuffixes: [String] = AppNameRewrite.pluralSuffixes) -> Bool {
        if keys.contains(key) {
            return true
        }
        for suffix in pluralSuffixes where key.hasSuffix(suffix) {
            let base = String(key.dropLast(suffix.count))
            if keys.contains(base) {
                return true
            }
        }
        return false
    }

    private static func isListedKey(_ key: String) -> Bool {
        return isListedKey(key, in: AppNameKeys.keys, pluralSuffixes: pluralSuffixes)
    }

    // MARK: - Whole-word replace

    private static func replaceWholeWord(_ word: String, with replacement: String, in text: String) -> String {
        guard !word.isEmpty, text.contains(word.first!) else {
            return text
        }
        let chars = Array(text)
        let wordChars = Array(word)
        guard chars.count >= wordChars.count else {
            return text
        }

        var output = ""
        output.reserveCapacity(text.count)
        var i = 0
        while i < chars.count {
            if chars[i] == wordChars[0], i + wordChars.count <= chars.count,
               Array(chars[i..<(i + wordChars.count)]) == wordChars {
                let script = BoundaryScript(of: wordChars[0])
                let beforeIsWordChar = i > 0 && script.joins(chars[i - 1])
                let afterIndex = i + wordChars.count
                let afterIsWordChar = afterIndex < chars.count && script.joins(chars[afterIndex])
                if !beforeIsWordChar && !afterIsWordChar {
                    output.append(replacement)
                    i = afterIndex
                    continue
                }
            }
            output.append(chars[i])
            i += 1
        }
        return output
    }

    /// Which neighbouring characters glue onto a match and so make it part of a longer word. Only letters of
    /// the SAME script count (2026-10-07 fix): "TelegramDesktop" stays untouched, but "关于Telegram" — Chinese
    /// writes Latin brand names with no space — is replaced, because a Han character is not part of a Latin
    /// word. Arabic and Hangul attach particles/prefixes directly to nouns ("텔레그램을"), so for those scripts
    /// nothing blocks.
    private enum BoundaryScript {
        case latin, cyrillic, free

        init(of first: Character) {
            let v = first.unicodeScalars.first?.value ?? 0
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || (0xC0...0x24F).contains(v) { self = .latin }
            else if (0x400...0x52F).contains(v) { self = .cyrillic }
            else { self = .free }
        }

        func joins(_ c: Character) -> Bool {
            guard let v = c.unicodeScalars.first?.value else { return false }
            switch self {
            case .latin:
                return (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) || v == 0x5F || (0xC0...0x24F).contains(v)
            case .cyrillic:
                return (0x400...0x52F).contains(v) || (0x30...0x39).contains(v)
            case .free:
                return false
            }
        }
    }
}
