import Foundation

/// PLAN.md 3.52: pure subtitle logic for the Si4Gram settings page, shared by every client that follows the
/// same page layout. No UIKit/AppKit, no `SecutgL10n` (that lives above this module) — these functions hand
/// back which localization keys apply and in what order; the caller looks the keys up and joins them.
public enum SecutgSettingsSubtitles {
    /// Row 4, "擦除设置": the short names of every enabled toggle, joined by the caller with "·", in the
    /// table's fixed order (confirm, listen-to-phrase, reset-auth, then custom-phrase last because it is not a
    /// toggle). Empty means "all off" — the caller falls back to `SecutgWipeSettingsAllOff`.
    public static func wipeSettingsActiveLabelKeys(
        needsConfirmation: Bool,
        listensToPhrase: Bool,
        resetsAuthorizations: Bool,
        hasCustomPhrase: Bool
    ) -> [String] {
        var keys: [String] = []
        if needsConfirmation { keys.append("SecutgWipeSettingsShortConfirm") }
        if listensToPhrase { keys.append("SecutgWipeSettingsShortListen") }
        if resetsAuthorizations { keys.append("SecutgWipeSettingsShortResetAuth") }
        if hasCustomPhrase { keys.append("SecutgWipeSettingsShortPhrase") }
        return keys
    }

    /// Row 2, "专属应用身份": which of the three `SecutgSettingsApiUsing…` keys names the credentials source
    /// currently in effect. `nil` for `.none` — there is nothing to report yet, and the row's own disclosure
    /// handles first-run guidance.
    public static func apiIdentitySubtitleKey(source: ApiCredentialRules.Source) -> String? {
        switch source {
        case .user: return "SecutgSettingsApiUsingOwn"
        case .bundled: return "SecutgSettingsApiUsingShared"
        case .env: return "SecutgSettingsApiUsingEnv"
        case .none: return nil
        }
    }
}
