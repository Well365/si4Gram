import Foundation

/// PLAN.md 3.7.1: the "配对完成" safety-code dialog is normally shown from a live event
/// (`SecutgAccountRuntime.pairingEvents`) the instant a pairing completes. That event is a one-shot
/// broadcast with no memory — nobody guarantees a listener is attached at the exact moment it fires
/// (the chat this pairing belongs to might not be the one on screen right then), and once it fires
/// unheard, it is gone. A device that missed it would otherwise never learn the pairing finished until
/// it happens to look at the lock button's menu.
///
/// This is the pure half of the fix: whenever a chat becomes the one on screen, ask "is this chat's
/// pairing done, and have I shown the dialog for *this* pairing episode yet" — independent of whether
/// the live event was ever heard. Keyed by `pairedAt` rather than a plain seen/unseen flag on purpose:
/// a later re-pairing (key changed, unpair + re-pair) produces a new `pairedAt`, so the catch-up fires
/// again for the new episode without this file — or any of its callers — needing to know every place a
/// re-pair can happen and remember to clear a stale flag there.
public enum PairingDialogCatchUp {
    /// - Parameters:
    ///   - pairingState: this chat's current pairing state string (`"paired"` is the only one that
    ///     qualifies — `key_changed` shows a different, separate warning dialog, not this one).
    ///   - pairedAt: unix seconds this pairing bound, from the same status read as `pairingState`.
    ///     `nil` means there is nothing to catch up on (no completed pairing at all).
    ///   - lastSeenPairedAt: the `pairedAt` this device last showed the dialog for, from local storage,
    ///     or `nil` if it never has.
    ///   - isVerified: whether this chat's safety code is already marked as checked (`pairingVerified`).
    ///     No default on purpose: a caller that has not decided this has not thought about rule 7b.
    public static func isDue(pairingState: String?, pairedAt: Int64?, lastSeenPairedAt: Int64?, isVerified: Bool) -> Bool {
        guard pairingState == "paired", let pairedAt else { return false }
        // PLAN.md 3.30 rule 7b: a chat whose safety code the user has already checked is not caught up on.
        // Without this, the day this mechanism ships every long-standing paired chat is "never shown" and
        // fires once on next open — somebody with dozens of encrypted private chats gets dozens of modal
        // dialogs in a row, which reads as a bug rather than a reminder. For the ones already marked as
        // checked, the dialog asks for something that is done; that is noise, not a reminder.
        //
        // This gates the catch-up only. The live dialog is raised from the pairing event and never passes
        // through here, so the moment a pairing completes it still shows — nothing can be "already checked"
        // one instant after it was created. Unverified chats are still caught up on, and that is the whole
        // reason the mechanism exists (PLAN.md 3.7.1: a safety code nobody was ever asked to compare is not
        // an acceptable resting state).
        if isVerified { return false }
        return lastSeenPairedAt != pairedAt
    }
}
