import Foundation

/// PLAN.md 3.7.1 rule 10: when a one-to-one pairing completes, exactly one encrypted
/// "🔒 加密已开启" (`SecutgPairConfirmMessage`) goes into the chat, so that both people see, in the
/// conversation itself, that everything from here on is ciphertext on the wire.
///
/// "Exactly one" is the entire difficulty, and it has two separate traps on either side of it:
///
/// * **Send it too rarely.** The confirmation used to be posted from inside the "配对完成" dialog,
///   so it only went out when that dialog was on screen — which means it only went out when the user
///   happened to be *looking at that chat* at the instant the peer's `P1` landed. Pair while the app
///   is on the chat list, or on another chat, or in the background, and the message was never sent at
///   all. The fix is to post it from a listener that is alive for the whole account rather than for a
///   screen, which is what Web A has always done (`global/actions/apiUpdaters/secutg.ts`).
///
/// * **Send it too often.** The dialog has a catch-up path (`PairingDialogCatchUp`) that replays a
///   "配对完成" this device missed seeing — every time the chat is opened until it is acknowledged.
///   Hanging the message off *that* would post a fresh "🔒 加密已开启" on every catch-up, and the
///   inviting side raises a `.done` of its own from `startPairing` too, which would make both ends
///   post one for a single pairing.
///
/// Hence this predicate rather than an `if` written out at each call site: both facts are named, and
/// the two traps are pinned by tests instead of by whoever edits the observer next.
public enum PairConfirmation {
    /// Whether *this* pairing event is the one that posts the encrypted confirmation text.
    ///
    /// - Parameters:
    ///   - isPairingDone: the event announces a completed pairing, not an incoming invite. An invite
    ///     has not encrypted anything yet, so there is nothing to confirm.
    ///   - completedHere: this device is the side that turned the peer's `P1` into a finished pairing
    ///     — the runtime's `shouldConfirm`. It is false for the other three ways a "done" can appear:
    ///     the inviting side's own `startPairing` completing locally, the "已经配对过了" re-announce,
    ///     and every `PairingDialogCatchUp` replay of an episode this device merely missed seeing.
    ///     Those all describe a pairing whose confirmation has already been sent once, by whichever
    ///     device actually completed it.
    public static func shouldSend(isPairingDone: Bool, completedHere: Bool) -> Bool {
        return isPairingDone && completedHere
    }
}
