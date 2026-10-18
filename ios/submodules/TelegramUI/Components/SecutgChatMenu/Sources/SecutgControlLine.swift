import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import AccountContext
import SecutgCore

/// SECUTG (PLAN.md 3.30 item 1): the action a secuTG system line offers **on the line itself**.
///
/// Until now every iOS control line was plain text: `ChatMessageTextBubbleContentNode` took
/// `SecutgAccountRuntime.controlSummary`'s sentence and drew it, and every action it mentioned lived one
/// tap down, in the lock button's menu. Item 1 splits that. Two of them come up to the row —
///
/// * 〔同意〕 on "they invited you to start encrypted messaging": not answering leaves the other person
///   waiting for a reply that never comes, and nothing else in the app will ever raise it again;
/// * 〔安全码…〕 on "this conversation is now encrypted": a safety code nobody was ever asked to compare is
///   the exact failure the pairing design exists to prevent;
///
/// — and the two recovery actions (〔在本机重新配对〕, 〔重新配对〕) deliberately do not, on any of the five
/// clients. The third on-row action of item 1, 〔导入并加入〕, was already tappable here: a group invite is a
/// `groupInvite` message with its own card (`SecutgGroupInvite`), not a control line.
///
/// Which sentence carries which action is `SecutgCore.ControlLineAction`, pure and shared with the other
/// clients. What this file adds is the two things that cannot be pure: whether the action still applies to
/// the live keyring, and the road it takes when tapped — which is the lock menu's own road, not a second
/// copy of it.
public enum SecutgControlLine {
    /// An action this control line should draw. `title` is the button text, resolved on the caller's side of
    /// the language switch; the action itself stays private so the bubble node never has to name a
    /// `SecutgCore` type (and the message list target never has to depend on that module).
    public struct OnRowAction {
        public let title: String
        fileprivate let action: ControlLineAction.Action
        /// PLAN.md 3.34.6: the announcement this decision is about, and whose key it names. Carried on the
        /// action rather than re-derived at tap time, so the decision lands on the very message being read.
        fileprivate let announcement: (userId: String, p1: String)?
        /// PLAN.md 3.43: false for the key-changed invitation, whose sentence IS the warning and must stay under the
        /// button — the ordinary invitation's swap to `SecutgPairInvite` would delete it.
        fileprivate let replacesLine: Bool

        fileprivate init(title: String, action: ControlLineAction.Action,
                         announcement: (userId: String, p1: String)? = nil, replacesLine: Bool = true) {
            self.title = title
            self.action = action
            self.announcement = announcement
            self.replacesLine = replacesLine
        }
    }

    /// The action this message's line offers right now, or nil.
    ///
    /// The live checks repeat the lock menu's own conditions rather than a looser version of them, because a
    /// button that does nothing is worse than no button: it teaches the reader that the row is decoration.
    /// A stored control message keeps saying what happened that day, but "accept" stops being offered the
    /// moment this device has answered, and "safety code…" stops the moment the chat is no longer paired.
    public static func onRowAction(message: Message, accountPeerId: PeerId) -> OnRowAction? {
        guard let meta = message.secutgMeta, meta.kind == .control,
              let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId) else { return nil }
        // PLAN.md 3.43: the key-changed invitation carries the same 〔同意配对〕 as an ordinary one, on the same road
        // (`startPairing` accepts the cached invite), for as long as that invite is on offer — which, the chat being
        // bound already, is `hasIncomingInvite` alone. The warning sentence stays under the button (`replacesLine`).
        let keyChangedParts = (meta.detail ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if keyChangedParts.first == "peer-key", keyChangedParts.count > 3, keyChangedParts[3] == "invite_key_changed" {
            guard runtime.status(chatPeerId: message.id.peerId).hasIncomingInvite else { return nil }
            return OnRowAction(title: SecutgL10n.string("SecutgPairAccept"), action: .pairAccept, replacesLine: false)
        }
        guard let action = ControlLineAction.onRow(detail: meta.detail) else { return nil }
        let status = runtime.status(chatPeerId: message.id.peerId)
        switch action {
        case .pairAccept:
            // SECUTG-HOOK (fix, 2026-09-27): the lock menu (SecutgChatMenu's own doc) dropped `!hasKey`
            // from this same gate — a genuinely detected, freshly-cached v2 invite must stay actionable
            // once a key already exists (the normal case for re-pairing), and `hasKey` is purely v1's
            // KeyRing, unrelated to v2's own send dispatch. This row follows the same gate.
            guard status.pairingState == nil, status.hasIncomingInvite else { return nil }
            return OnRowAction(title: SecutgL10n.string("SecutgPairAccept"), action: action)
        case .safetyCode:
            // And 〔安全码…〕 exactly while the chat is auto-paired **and** a code can actually be
            // computed for it. Two of the three conjuncts Android's `ControlLineAction.of` uses; since
            // PLAN.md 3.25.11 a `key_changed` line reaches this rule with the chat already back on `paired`
            // — the key was adopted before the line was written — so it lights up here rather than under a
            // rule of its own, which is the behaviour 3.25.11 asks for.
            //
            // Android's third conjunct is "the rendered line still contains that live code", which stops an
            // old line quoting a superseded code from opening a dialog about a different key. The rendered
            // text is produced after this decision, by `decorate`, so it cannot be tested here — but the
            // thing it would be tested against can be, and more directly: for `paired` / `self_paired` the
            // code the sentence will quote was baked into `detail` at transform time
            // (`pairingDetailSuffix`), so comparing THAT against the live code is the same question without
            // the string search. `key_changed` bakes no code — `controlSummary` reads it from the live
            // keyring on every draw — so that line cannot go stale and is left alone.
            //
            // What this stops: the chat re-pairs or the peer rotates, and the older 「安全码：AAAA」 line is
            // still in the history while the button on it opened a dialog about BBBB. A button that answers
            // a different question from the sentence it is attached to is worse than no button, because the
            // person comparing codes out of band has no way to notice the substitution.
            guard status.isAutoPaired, let live = runtime.safetyCode(chatPeerId: message.id.peerId) else {
                return nil
            }
            let detailParts = (meta.detail ?? "").split(separator: ":", omittingEmptySubsequences: false)
                .map(String.init)
            let detailPairing = detailParts.count > 3 ? detailParts[3] : ""
            if detailPairing == "paired" || detailPairing == "self_paired" {
                // parts[4] is the baked code for these two outcomes and the new device_id for `key_changed`,
                // which is why the segment is only read under this branch.
                let baked = detailParts.count > 4 ? detailParts[4] : ""
                if !baked.isEmpty, baked != live { return nil }
            }
            return OnRowAction(title: SecutgL10n.string("SecutgMenuSafetyCode"), action: action)
        case .adoptGroupKey:
            // PLAN.md 3.34.6. The `P1` is the message's own text: this client stores a control message
            // verbatim and re-derives its line on every draw, so unlike Web there is nothing to copy into the
            // stored detail — the announcement is right here. `userId` comes from the detail, where the
            // processor wrote it after checking it against the sender; verifying the wire against the id it
            // carries itself would only prove the message agrees with itself.
            let parts = (meta.detail ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count > 1 else { return nil }
            let userId = parts[1]
            guard let parsed = Rekey.parseP1(message.text), Rekey.verifyP1(parsed, senderId: userId) else { return nil }
            // The live check, the same shape the other two use: the button goes away once the decision has
            // been taken here, whether through this row or from anywhere else. A button that does nothing
            // teaches the reader that the row is decoration.
            guard runtime.registeredMemberKey(chatPeerId: message.id.peerId, userId: userId) != parsed.x25519Pk else {
                return nil
            }
            return OnRowAction(title: SecutgL10n.string("SecutgGroupKeyChangedAccept"), action: action,
                               announcement: (userId, message.text))
        }
    }

    /// The tap. Both roads are the lock menu's: 〔同意〕 is the same `startPairing` that
    /// `SecutgMenuPairAccept` runs, and 〔安全码…〕 opens the same dialog `SecutgMenuSafetyCode…` opens.
    public static func perform(_ action: OnRowAction, context: AccountContext, peerId: PeerId, controller: ViewController) {
        SecutgChatMenu.syncLanguage(context: context)
        switch action.action {
        case .pairAccept:
            SecutgChatMenu.startPairing(context: context, peerId: peerId, controller: controller)
        case .safetyCode:
            SecutgChatMenu.presentSafetyCode(context: context, peerId: peerId, controller: controller)
        case .adoptGroupKey:
            guard let announcement = action.announcement else { return }
            SecutgChatMenu.presentAdoptMemberKey(context: context, peerId: peerId, controller: controller,
                                                 userId: announcement.userId, p1: announcement.p1)
        }
    }

    /// The line plus its action, as the bubble draws it: the sentence, a blank line, then the button text in
    /// bold — the shape `SecutgGroupInvite.cardText` already uses for 〔导入并加入〕, so the two on-row actions
    /// in a private chat look like one thing rather than two.
    ///
    /// The sentence itself can change when a button is attached (PLAN.md 3.30.1b): the invitation line's
    /// "— 点锁钮选择「同意配对」" was written for a row with no button on it, and with one there it points the
    /// reader at the long way round. `ControlLineAction.line` owns that choice, shared with the other clients
    /// that re-derive their line on every draw. This is also why the swap lives here and not in
    /// `SecutgAccountRuntime.controlSummary`: that function is iOS/macOS shared and knows nothing about
    /// whether a button was drawn, and it should stay that way.
    public static func decorate(text: String, action: OnRowAction) -> (text: String, entities: [MessageTextEntity]) {
        let sentence = action.replacesLine ? ControlLineAction.line(summary: text, action: action.action, localized: { SecutgL10n.string($0) }) : text
        let label = "\u{25B6} " + action.title
        let decorated = sentence + "\n\n" + label
        return (decorated, [MessageTextEntity(range: decorated.utf16.count - label.utf16.count ..< decorated.utf16.count, type: .Bold)])
    }
}
