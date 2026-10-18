import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext

/// SECUTG (PLAN.md 3.17 rule 3, 3.34.7 item 4): the fifth moment a key can arrive — a control message that
/// moved this chat's keys where the message itself was built.
///
/// 3.17 rule 3 listed four moments worth re-reading a chat's stored messages after: importing a chat key,
/// accepting a group invite, completing a pairing, taking in a transferred keyring. A welcome did not exist
/// when that was written, and a welcome is itself a road a key travels by — it applies inside the receive hook,
/// which is handed one message at a time and cannot go back for the others. So the runtime reports it
/// (`SecutgAccountRuntime.keysChanged`) and this is what answers:
///
///  1. the rows parked for exactly this are asked again — a welcome that overtook its notice, a notice waiting
///     for the admin list (`secutgRetryParkedControlRows`);
///  2. the ciphertext that could not be opened is tried against the key that has just arrived
///     (`secutgRedecryptChats`);
///  3. the member is asked whether it now owes the group its public key (`SecutgAutoAnnounce`) — a notice that
///     retired this device's key is precisely when it does.
///
/// Only **fresh** applications get here (`RekeyProcessor.Result.movedKeys`): `already_known`, `already_applied`
/// and this device's own echo change nothing and recur on every load of a history, so a sweep on those would
/// run on every scroll. That is also what stops this looping — the pass in (1) re-runs the receive hook, and a
/// row it applies reports once and then reads as `already_known`.
///
/// Account-wide and with no controller in it, like `SecutgAutoWelcome`: a welcome arrives whenever it arrives,
/// and a sweep that only ran while the user happened to be looking at that group would be missing far more
/// often than not.
///
/// `sweep` is also what the OTHER road calls — the admin list arriving and the notices parked for it being
/// judged (`SecutgAutoWelcome.refreshAdmins`). Both moments do the same three things to the same chat, and each
/// of them is a sequence of postbox transactions rather than one: Postbox serialises each transaction, but not
/// a run of them, so two roads left to themselves could interleave their passes over the same rows. One queue,
/// so they cannot (the point Web's cross-check raised, and the reason its `sweepChat` moved into the store).
public enum SecutgKeysChanged {
    /// One live listener per account. Main queue only.
    private static var listeners: [PeerId: Disposable] = [:]

    /// Chats being swept right now; the value is "another report came in while this was running". Main queue
    /// only. A second report queues one more pass rather than a second sweep at the same time — the pass is a
    /// scan over the chat's stored messages, and two of them racing would each rewrite what the other read.
    private static var sweeping: [PeerId: Bool] = [:]

    /// Installs this account's listener, for the lifetime of the account. Idempotent: re-installing after a
    /// sign-out / sign-in swaps in the new context instead of leaving a listener bound to the dead one.
    public static func install(context: AccountContext) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let accountPeerId = context.account.peerId
        listeners.removeValue(forKey: accountPeerId)?.dispose()
        listeners[accountPeerId] = (runtime.keysChanged.signal() |> deliverOnMainQueue).start(next: { [weak context] chatPeerId in
            guard let context else { return }
            sweep(context: context, chatPeerId: chatPeerId)
        })
    }

    /// Re-judge this chat's parked control rows, open what the arriving key unlocks, then ask whether this
    /// device now owes the group its public key. Main queue only. Called by the runtime's own report above and
    /// by `SecutgAutoWelcome.refreshAdmins`, so the two share this queue.
    static func sweep(context: AccountContext, chatPeerId: PeerId) {
        if sweeping[chatPeerId] != nil {
            sweeping[chatPeerId] = true
            return
        }
        sweeping[chatPeerId] = false
        let postbox = context.account.postbox
        let accountPeerId = context.account.peerId
        // Parked rows first, ciphertext second: a welcome judged in (1) binds a master, and (2) is what opens
        // the messages that were sent under it before it arrived.
        let pass = secutgRetryParkedControlRows(postbox: postbox, accountPeerId: accountPeerId, peerId: chatPeerId)
        |> mapToSignal { _ -> Signal<Int, NoError> in
            return secutgRedecryptChats(postbox: postbox, accountPeerId: accountPeerId, peerIds: [chatPeerId])
        }
        let _ = (pass |> deliverOnMainQueue).startStandalone(next: { [weak context] _ in
            guard let context else {
                sweeping.removeValue(forKey: chatPeerId)
                return
            }
            // PLAN.md 3.34.6: the notice that took this device's key away is the moment it owes the group its
            // public key, so the admin has something to seal the replacement to. Asked after the sweep, when
            // the keyring has settled — `shouldAnnounceIdentity` refuses a device that already holds a key,
            // and a welcome applied a moment ago is exactly such a device.
            SecutgAutoAnnounce.maybeAnnounce(context: context, groupPeerId: chatPeerId)
            let again = sweeping[chatPeerId] ?? false
            sweeping.removeValue(forKey: chatPeerId)
            if again { sweep(context: context, chatPeerId: chatPeerId) }
        })
    }
}
