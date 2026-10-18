import Foundation

/// SECUTG: what a message this device cannot open looks like (PLAN.md 3.17 points 1 and 2).
///
/// The ciphertext stays in storage — untouched, byte for byte — because it is what lets the message become readable
/// once the key arrives (`secutgRedecryptChats`). Showing it to the reader was only ever noise, so the bubble and the
/// chat-list preview draw this line instead. The substitution happens at render time and nowhere else.
///
/// Three situations, and they are not interchangeable:
///   * the keyring has not answered yet — a momentary state, nothing is wrong;
///   * this device holds no key that opens the message — far and away the commonest, and the one with an answer, so
///     the line points at the guide chapter that explains how to get the key;
///   * a key exists and rejects the ciphertext (`auth_failed` / `bad_plaintext` / `malformed`) — this message may
///     have been altered in transit, which is a different statement entirely and must not be reported as "no key".
public enum SecutgUndecryptableLine {
    public enum Situation {
        case loading
        case noKey
        case tampered
        /// SECUTG-HOOK (feature, 2026-09-28, PLAN.md 3.38.1): a group whose password this run has not been given.
        case groupPasswordLocked
    }

    /// `detail` is `SecutgTextMetaAttribute.detail`, i.e. the `DecryptResult.Reason` raw value the receive hook stored.
    public static func situation(detail: String?) -> Situation {
        switch detail {
        case "not_ready":
            return .loading
        case secutgGroupPasswordLockedDetail:
            return .groupPasswordLocked
        case "auth_failed", "bad_plaintext", "malformed":
            return .tampered
        default:
            // `unknown_key`, `invalid_key` and anything a future version writes: no usable key here.
            return .noKey
        }
    }

    /// The guide chapter the "no key" line points at: how a member gets the key for a chat.
    public static let guideChapterId = "member"

    /// Whether a tap on this bubble should open the guide — true only for the line that offers it.
    public static func offersGuide(detail: String?) -> Bool {
        return situation(detail: detail) == .noKey
    }

    /// The replacement text, and the entities that go with it. `asPreview` is the chat-list / reply-quote form:
    /// the same sentence with nothing to tap, since there is nothing there to tap it with.
    public static func line(detail: String?, asPreview: Bool) -> (text: String, entities: [MessageTextEntity]) {
        switch situation(detail: detail) {
        case .loading:
            return (SecutgL10n.string("SecutgUndecryptableLoading"), [])
        case .tampered:
            return (SecutgL10n.string("SecutgUndecryptableTampered"), [])
        case .groupPasswordLocked:
            return (SecutgL10n.string("SecutgGroupPwLockedPreview"), [])
        case .noKey:
            let head = SecutgL10n.string("SecutgUndecryptableLine")
            if asPreview {
                return (head, [])
            }
            let action = "\u{25B6} " + SecutgL10n.string("SecutgGuideTitle")
            let text = head + " " + SecutgL10n.string("SecutgUndecryptableHint") + "\n\n" + action
            let actionStart = text.utf16.count - action.utf16.count
            return (text, [MessageTextEntity(range: actionStart..<text.utf16.count, type: .Bold)])
        }
    }
}
