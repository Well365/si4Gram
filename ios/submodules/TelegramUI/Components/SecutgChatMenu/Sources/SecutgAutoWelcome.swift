import Foundation
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import SecutgCore

/// SECUTG (PLAN.md 3.34.6): the account-wide listener that answers a public-key announcement in an auto-mode
/// group with one `R1 welcome`, and the one that keeps the runtime's picture of a group's Telegram admins up
/// to date.
///
/// Both halves exist because the protocol layer deliberately cannot do them. `RekeyProcessor` decides that a
/// welcome is owed and says so; it never sends, because a state machine that posts messages is a state machine
/// nobody can test. And rule 1 of 3.34.3 — "is the sender a Telegram admin of this group?" — is not in the
/// keyring at all; it is in the postbox, it loads asynchronously, and **not knowing it yet is a third state**
/// that has to reach the processor as an absent value so a notice is parked rather than refused.
///
/// The listener is account-wide and has no controller in it, for the same reason
/// `SecutgPairingDialogs.installConfirmationSender` is: an announcement arrives whenever it arrives, and a
/// welcome that only went out while the user happened to be looking at that group would be missing far more
/// often than not.
public enum SecutgAutoWelcome {
    /// One live sender per account. Main queue only.
    private static var senders: [PeerId: Disposable] = [:]

    /// **Why the ledger.** `transformIncoming` runs on every message that is stored or re-read, so scrolling a
    /// group's history back past old announcements would otherwise post a welcome for each one. Keyed on the
    /// master in use, so a rebuild — which is exactly when everybody needs one again — lets them all through,
    /// while a replayed announcement under the same key does not.
    ///
    /// It also counts, because 3.34.6's co-holder rule is expressed in "how many times has this member
    /// announced since we last sent them a copy": the lowest-ranked holder answers the first announcement, the
    /// next one the second, and a member stops announcing the moment a key arrives — so a second announcement
    /// only ever happens because the first holder did not answer.
    ///
    /// Session-lived on purpose. A member who really did not get their copy announces again after the cooldown
    /// and the next run answers them; a ledger that survived a restart would make that silence permanent.
    private static var announceCounts: [String: Int] = [:]

    /// Installs this account's welcome sender, for the lifetime of the account. Idempotent: re-installing after
    /// a sign-out / sign-in swaps in the new context instead of leaving a sender bound to the dead one.
    public static func install(context: AccountContext) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let accountPeerId = context.account.peerId
        senders.removeValue(forKey: accountPeerId)?.dispose()
        senders[accountPeerId] = (runtime.autoWelcomes.signal() |> deliverOnMainQueue).start(next: { [weak context] chatAndUser in
            guard let context else { return }
            answer(context: context, runtime: runtime, groupPeerId: chatAndUser.0, userId: chatAndUser.1)
        })
    }

    private static func answer(context: AccountContext, runtime: SecutgAccountRuntime,
                               groupPeerId: PeerId, userId: String) {
        guard let masterId = runtime.status(chatPeerId: groupPeerId).currentKeyId else { return }
        let ticket = "\(groupPeerId.toInt64()):\(userId):\(masterId)"
        let count = (announceCounts[ticket] ?? 0) + 1
        announceCounts[ticket] = count
        // 3.34.6: whose turn it is. Both unknowns — this device not in the admin list, and a list that has not
        // loaded — rank 0 and therefore act: a duplicate welcome costs one control line and opens the same
        // master, while silence costs somebody their key.
        guard AutoPairing.isOurTurnToWelcome(AutoPairing.TurnInput(
            ownUserId: runtime.ownUserId,
            adminIds: runtime.groupAdminIds(chatPeerId: groupPeerId),
            announceCount: count)) else { return }
        guard let wire = try? runtime.buildRekey(chatPeerId: groupPeerId, request: .welcome(userId: userId)) else {
            // A welcome that could not be built is not worth a dialog — the member's device asks again on its
            // own. Let the ticket go so that ask is answered instead of silently skipped.
            announceCounts[ticket] = count - 1
            return
        }
        SecutgChatMenu.syncLanguage(context: context)
        SecutgChatMenu.sendText(context: context, peerId: groupPeerId, text: wire)
    }

    // MARK: rule 1's answer (PLAN.md 3.34.3)

    /// Hands the runtime the group's current Telegram admins, so an `N1` from one of them can be judged.
    ///
    /// Called when a group's participants are read for any other reason. Until it has been called at least
    /// once for a group, `SecutgAccountRuntime.isGroupAdmin` answers "not known", and the processor **parks**
    /// a notice rather than refusing it — which is the whole reason this is a separate feed instead of a
    /// synchronous lookup. After a long offline stretch the history always arrives before the member list, and
    /// a "no" spoken too early silently drops every notice in it.
    public static func refreshAdmins(context: AccountContext, groupPeerId: PeerId) {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: context.account.peerId) else { return }
        let _ = (adminIds(context: context, groupPeerId: groupPeerId)
        |> deliverOnMainQueue).startStandalone(next: { admins in
            // nil is "the list did not load", and so is an EMPTY list (PLAN.md 3.34.7 item 4): every group has
            // an owner, so nobody-is-an-admin is not a thing Telegram can truthfully say — it is what a basic
            // group's participant list reads as before it has been fetched. Written down, it would turn "not
            // loaded" into an answer and refuse the creator's own notice as `not_admin`, which is what one of
            // the two phones did on 2026-09-19. Nothing is written for either.
            guard let admins, !admins.isEmpty else { return }
            // Nothing to unpark when the answer has not moved, and the sweep is a scan over the group's stored
            // messages — running it on every chat open would be paying for an answer nobody asked again.
            guard runtime.setGroupAdmins(chatPeerId: groupPeerId, userIds: admins) else { return }
            // And now ask again about the rows that were parked while the answer was missing — the notices, and
            // the welcomes parked behind them. The refused ones are rewritten too: a notice that tried to take
            // this group's key away and was turned away is worth seeing, and until this pass its row says
            // nothing at all. Strictly after the write: the retry re-runs the receive hook, which reads exactly
            // what was just stored.
            //
            // Through `SecutgKeysChanged.sweep` rather than straight to the scan, so this road and the one the
            // runtime reports on share a queue: both are a SEQUENCE of postbox transactions over the same rows,
            // and Postbox serialises each transaction but not a run of them.
            SecutgKeysChanged.sweep(context: context, chatPeerId: groupPeerId)
        })
    }

    /// Who this group's admins are, as Telegram itself says — **the members' own rights, not this account's**.
    ///
    /// Deliberately not `secutgIsTelegramGroupAdmin`, which answers "does the account looking at this peer have
    /// admin rights here". That is the right question for "may I offer the rebuild button" and the wrong one
    /// for every entry in a member list: applied to somebody else's `TelegramUser` it is simply false, and rule
    /// 1 would then refuse every notice a real admin ever sent.
    ///
    /// nil means the list could not be read, which is the third state and is never flattened into an empty one.
    private static func adminIds(context: AccountContext, groupPeerId: PeerId) -> Signal<[String]?, NoError> {
        if groupPeerId.namespace == Namespaces.Peer.CloudChannel {
            return context.engine.peers.channelMembers(peerId: groupPeerId, category: .admins)
            |> map { members -> [String]? in
                members.map { $0.map { SecutgAccountRuntime.userId($0.peer.id) } }
            }
        }
        guard groupPeerId.namespace == Namespaces.Peer.CloudGroup else { return .single(nil) }
        return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.LegacyGroupParticipants(id: groupPeerId))
        |> map { participants -> [String]? in
            guard let list = participants.knownValue else { return nil }
            return list.compactMap { participant in
                switch participant {
                case .creator, .admin:
                    return SecutgAccountRuntime.userId(participant.peerId)
                case .member:
                    return nil
                }
            }
        }
    }
}
