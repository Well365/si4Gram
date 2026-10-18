import Foundation
import TelegramCore
import AccountContext
import SecutgCore
import SecutgRelay // SECUTG-HOOK (PLAN.md 3.48.0 hook ⑤ / 3.48.7 §5)

/// SECUTG (PLAN.md 3.46.2 §1): deletes this account's secuTG records when its session was revoked out from under
/// it — never when the user signed out on purpose (that path registers with `LogoutIntentRegistry` first and this
/// never runs). Called from `ApplicationContext`'s `account.loggedOut` handler, before `logoutFromAccount`.
///
/// Deletes: the keyring and its Keychain-backed encryption key, the v2 state and its Keychain item, the v2
/// runtime, and this account's local preferences (stranger decisions, onboarding-card memory, the fold
/// preference, the check-up's ignore list / group-key limit / backup time, the 3.46.1 shown-code record, the
/// 3.47 catch-up watermarks) — the same per-account local state the emergency wipe (3.16) destroys.
///
/// Keeps (never touched here): the device-wide secuTG application identity (3.40, shared by every account on
/// this device), the wipe-phrase "already executed" marker (3.22.5 — without it a re-login re-triggers the wipe
/// for the following 30 days), every other account's data, and the app passcode.
public enum SecutgForcedLogoutWipe {
    public static func wipe(context: AccountContext) {
        let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId)
        // The same local, synchronous, cannot-fail step the emergency wipe runs first (PLAN.md 3.16 step ①):
        // keys, v2 state (with their Keychain items), the v2 runtime, the group-password unlock table.
        runtime?.destroyKeyring()

        let key = SecutgLocalPrefs.accountKey(context.account.peerId)
        SecutgLocalPrefs.clearStrangerDecisions(accountKey: key)
        SecutgLocalPrefs.clearOnboardMemories(accountKey: key)
        SecutgLocalPrefs.clearFoldPreference(accountKey: key)
        SecutgLocalPrefs.clearAuditPrefs(accountKey: key)
        SecutgLocalPrefs.clearLostDeviceShownCodes(accountKey: key)
        SecutgLocalPrefs.clearCatchUpWatermarks(accountKey: key)
        // SECUTG-HOOK (PLAN.md 3.48.0 hook ⑤ / 3.48.7 §5): this account's relay sent-items and local copies only
        // — app-level relay config (other accounts' relays, trust list) is untouched, same rule as everything
        // else in this file.
        SecutgRelayRuntime.shared.wipeForForcedLogout(context: context)
        // Deliberately NOT cleared here: SecutgApiCredentialsUI (device-wide, 3.40) and the wipe "consumed"
        // marker (3.22.5) — see the type doc.
    }
}
