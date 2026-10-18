import Foundation

/// PLAN.md 3.30 item 1: which of a control message's actions has to be tappable **on the line itself**.
///
/// The ruling is a split, not "put everything on the row". Two kinds of action end up on a secuTG system
/// line, and they fail in completely different ways when they are one level down in the lock button's
/// menu:
///
/// * **Nothing happens until you do it.** Skipping 〔Accept〕 leaves the other person waiting for an answer
///   that never comes; skipping 〔Safety code…〕 means the code is never compared, which is the one step the
///   whole pairing design rests on. Neither of those is a thing the reader knows to go looking for, so they
///   live on the row, where the sentence that mentions them is.
/// * **Recovery, and late is fine.** 〔Re-pair on this device〕 and 〔Re-pair〕 put back something that is
///   already broken and visibly so. Doing them a minute later costs nothing, and having them one tap from
///   the text of a *warning* invites tapping them to make the warning go away. Those stay in the menu on
///   all five clients — this function is deliberately unable to return them.
///
/// The third on-row action of item 1, 〔Import and join〕 on a group-invite card, is not here: an invite is
/// a `groupInvite` message, not a control line, and its card has always been tappable.
public enum ControlLineAction {
    public enum Action: Equatable {
        /// 〔Accept〕 on "they invited you to start encrypted messaging". Same road as the lock menu's
        /// `SecutgMenuPairAccept`: this device sends its own `P1`.
        case pairAccept
        /// 〔Safety code…〕 on "this conversation is now encrypted", and since PLAN.md 3.25.11 on "their
        /// encryption key changed — this chat re-paired itself with the new one" as well. Opens the same
        /// dialog the lock menu does.
        case safetyCode
        /// PLAN.md 3.34.6: 〔Accept the new key〕 on "{name} announced a different key from the one on file".
        ///
        /// On the row for the same reason 〔Accept〕 is: nothing happens until somebody does it, and the
        /// consequence — that person gets no copy of the group key until then — is invisible otherwise. It is
        /// not a recovery action either: nothing is broken, a decision is owed. The decision deliberately lands
        /// on the announcement being read rather than on something re-derived elsewhere, which is why the
        /// caller verifies the `P1` this very message carries.
        case adoptGroupKey
    }

    /// The key of the sentence this row shows **instead of** `controlSummary`'s, or nil to keep what it said.
    ///
    /// Only the invitation needs one. `SecutgPairInviteHint` is `SecutgPairInvite` plus "— 点锁钮选择
    /// 「同意配对」": an instruction written for a client with no button on the row. With the button there it
    /// sends the reader somewhere they no longer need to go, and `SecutgPairInvite` — the same sentence
    /// without the tail — is exactly what Web A shows beside its own 〔同意〕, so dropping the tail also lands
    /// on the shared wording. Both keys have been in the table all along; this adds none.
    ///
    /// PLAN.md 3.30.1b: this is a **rendering-layer** swap, which is why Android keeps the long sentence and
    /// the other clients do not. Android's line is written into `message.message` by `applyControl` and
    /// frozen at write time, so it cannot follow a button that appears conditionally; where the gate is not
    /// met, that tail is the only working directions the reader has. iOS, macOS and Web re-derive the line on
    /// every draw, so they can say the right one each time — and must, because a button plus directions to
    /// the long way round reads as two different answers to the same question.
    ///
    /// Deliberately keyed on the action rather than on the pairing outcome: the sentence may only be shortened
    /// where the button that replaces its tail is actually on screen. `onRow` having returned an action is not
    /// enough on its own — the caller's live check has to have passed too, which is why this takes the action
    /// the caller decided to draw rather than re-deriving one from `detail`.
    public static func replacementLineKey(_ action: Action) -> String? {
        switch action {
        case .pairAccept:
            return "SecutgPairInvite"
        case .safetyCode, .adoptGroupKey:
            return nil
        }
    }

    /// The sentence a control row reads once its action (if any) has been folded in.
    ///
    /// - Parameters:
    ///   - summary: what `SecutgAccountRuntime.controlSummary` produced for this line.
    ///   - action: the action the caller has decided to draw, or nil when the row carries none.
    ///   - localized: resolves a string key. A parameter because `SecutgCore` holds no string table — and
    ///     because it makes both branches of this decision testable without one.
    public static func line(summary: String, action: Action?, localized: (String) -> String) -> String {
        guard let action = action, let key = replacementLineKey(action) else { return summary }
        return localized(key)
    }

    /// The action this control line carries, or nil for the ones that offer nothing on the row.
    ///
    /// `detail` is the `SecutgTextMetaAttribute.detail` wire string the receive hook stored, in the same
    /// shape the line's own text is derived from (`SecutgAccountRuntime.controlSummary`):
    /// `peer-key:<uid>:<outcome>[:<pairing>[:…]]`, or `rekey:<type>:<outcome>`. Only the pairing segment is
    /// read here, exactly as `controlSummary` reads it, so the button can never appear on a sentence other
    /// than the one it belongs to.
    ///
    /// Everything not named below returns nil on purpose, including `pairing_lost`, `pairing_moved` and
    /// `other_device` — those are the warning lines whose only action is a re-pair.
    public static func onRow(detail: String?) -> Action? {
        let parts = (detail ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // `rekey:…` lines state an outcome and offer nothing; a `peer-key` that failed has no pairing
        // segment at all, so it falls out here too.
        guard parts.first == "peer-key", parts.count > 3 else { return nil }
        switch parts[3] {
        case "incoming":
            return .pairAccept
        // PLAN.md 3.25.11: `key_changed` belongs here now, not with the re-pair warnings below. The peer's
        // new key is adopted before this line is ever written, so the chat is back on `paired` by the time it
        // renders and the one thing left for the reader to do is compare the NEW safety code — which the
        // sentence itself now quotes. Android reaches the same answer without naming the outcome at all
        // (`ControlLineAction.of`: live state `paired`, a live safety code, and that code present in the
        // rendered text) and Web the same way; naming it here is how a `detail`-keyed lookup asks the
        // identical question. The caller's live check is the other half, and is what stops the button on a
        // chat that has since moved on.
        case "paired", "self_paired", "key_changed":
            return .safetyCode
        // PLAN.md 3.34.6: a group announcement replacing a registered key. Its own segment value rather than
        // the private chat's `key_changed`, which is a pairing state with a completely different road out
        // (3.25.3) — the two must not be able to reach each other's button.
        case "group_key_changed":
            return .adoptGroupKey
        default:
            return nil
        }
    }
}
