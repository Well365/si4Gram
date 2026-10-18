import Foundation
import Postbox
import SecutgCore

/// SECUTG: reading back a message that the database holds as its envelope (PLAN.md 3.19).
///
/// The Web client could take the cheap route — every message it has is in memory anyway, so it only had to change
/// what the cache writer persists. This client pages messages out of the database, so "store the envelope" has to
/// mean "open it again on the way out". That happens here, at the two render funnels PLAN.md 3.17 already opened:
/// the text bubble and the chat-list preview. Nothing else is touched, and the database write path is untouched
/// by this file entirely — it only reads.
///
/// A message whose key has since gone (a wipe, an unpair) falls through to the 3.17 notice, which is the honest
/// answer: this device can no longer read it. That is also why `.sealed` is a different kind from `.undecryptable` —
/// one says "we put this away", the other says "we never got in" — and why the 3.17 re-decrypt sweep, which selects
/// on `.undecryptable`, walks straight past a sealed message instead of trying to rewrite it.
///
/// PLAN.md 3.44: a v2 row — private chat or group, wire `E2:` — is sealed and read back on exactly these terms. The
/// generation is settled inside `openSealed`, not here: a sealed row is a sealed row.
public enum SecutgSealedText {
    public enum Rendered {
        case opened(text: String, entities: [MessageTextEntity])
        /// `detail` feeds `SecutgUndecryptableLine.situation(detail:)`.
        case locked(detail: String?)
    }

    /// nil when this message is not stored sealed, i.e. every ordinary message and every message in a chat that
    /// does not encrypt — those are drawn exactly as they always were.
    public static func render(message: Message, accountPeerId: PeerId) -> Rendered? {
        guard message.secutgMeta?.kind == .sealed, !message.text.isEmpty else { return nil }
        guard let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId) else {
            // The keyring has not been installed for this account yet: a momentary state, and the 3.17 line for it
            // says "unlocking", not "no key".
            return .locked(detail: "not_ready")
        }
        // SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1): the chat-aware reader, so a locked group reads as such.
        switch runtime.openSealed(wire: message.text, chatPeerId: message.id.peerId) {
        case let .opened(text, entities):
            return .opened(text: text, entities: entities)
        case let .locked(detail):
            return .locked(detail: detail)
        }
    }

    /// PLAN.md 3.17 for a row the receive hook never saw: the Notification Service Extension stores messages with no
    /// secuTG runtime (PLAN.md 3.47), so a wire — content or control — can sit in the database with no meta at all
    /// until the catch-up pass or the 3.17 sweep writes its verdict. Such a row must draw the notice, never its own
    /// base64: this returns the notice detail to draw it with (`SecutgUndecryptableLine.line(detail:)`), or nil for
    /// every row that is not one (anything with meta, and any text that is not a wire by structure).
    public static func unmarkedWireDetail(message: Message) -> String? {
        return CatchUp.unmarkedWireNotice(text: message.text, hasSecutgMeta: message.secutgMeta != nil)
    }
}
