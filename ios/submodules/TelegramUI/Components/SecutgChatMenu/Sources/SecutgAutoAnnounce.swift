import Foundation
import Postbox
import TelegramCore
import AccountContext

/// SECUTG (PLAN.md 3.34.6 / 3.34.7 item 4): the member's half of auto mode, actually automatic.
///
/// Until now `shouldAnnounceIdentity` had a decision and no trigger: its only callers were the menu's hand
/// crank and the moment a key was imported, so a member who did not know to press anything never announced —
/// the admin then had no public key to seal a welcome to, and the group stayed dark. That is the second of the
/// three gaps two phones showed on 2026-09-19.
///
/// The rule itself stays in the keyring (`AutoPairing.shouldAnnounceIdentity`: auto mode, encryption on, no key
/// held, off cooldown). This side only supplies the occasions and remembers when it last asked, per chat, for
/// the session — the same shape Web's `autoAnnounce.ts` has. Two occasions, both named in 3.34.7 item 4:
///
///  - a control message moved this chat's keys (`SecutgKeysChanged`), which is how an `N1` retiring the
///    member's key reaches them: their key is gone, the replacement is coming, and it can only come to a key
///    the admin has on file;
///  - the chat being opened, which is what catches a member who was away when all of that happened.
///
/// Unlike Web there is no per-row trigger, because this client does not re-run an effect per rendered control
/// line — and it does not need one: the two occasions above are the two 3.34.7 item 4 asks for, and every
/// condition the row would have carried (auto mode, notice applied, not our own echo — the admin holds the key,
/// so `hasKey` refuses them) is already in the keyring's own answer.
public enum SecutgAutoAnnounce {
    /// When this device last announced itself in each chat, unix seconds. Main queue only.
    ///
    /// Session-lived on purpose, like the welcome ledger: the cooldown exists so that an admin who is offline
    /// for a week does not collect one announcement per app start, and a fresh start that has forgotten it
    /// announces once — which is the right thing to do anyway.
    /// Kept alongside the retired trigger above (3.35.5): reinstating the announcement means restoring one
    /// function body, not rebuilding the cooldown it needs.
    private static var announcedAt: [PeerId: Int64] = [:]

    /// Asks the keyring whether this device owes the group its public key, and posts one if it does.
    ///
    /// Silent when it does not, which is almost always: this runs on every chat open. A send that fails is not
    /// worth a dialog — the mark is dropped so the next occasion asks again.
    public static func maybeAnnounce(context: AccountContext, groupPeerId: PeerId) {
        // PLAN.md 3.35.5: **retired, and deliberately left as a no-op rather than deleted.**
        //
        // This was the member's half of the welcome road — a device waiting for a key in an auto-mode group
        // announced its public key so the admin had something to seal a replacement to. Gates 2 and 7 of
        // 3.35.1: the announcement had to reach the admin's device, the admin had to be online to answer it,
        // and if either did not happen the member sat with no key and nothing on screen.
        //
        // Nothing announces now. The key arrives in the `G2` that follows the notice, and a member who joins
        // later reads it out of history. The call sites (every chat open) stay wired so that reinstating it
        // is one edit, and so that nobody re-adds a second trigger somewhere else believing there is none.
        //
        // The RECEIVING half is untouched (3.34.6 「保留解析、移除入口」): a welcome from an older build
        // still applies, and the menu's hand crank still posts a `P1` when a person asks for it.
        _ = context
        _ = groupPeerId
    }
}
