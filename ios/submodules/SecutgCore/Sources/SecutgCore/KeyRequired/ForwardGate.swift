import Foundation

/// A forward is a server-side copy: `messages.forwardMessages` names ids, never text, so the send hook
/// (`prepareOutgoing`) never sees it — the 3.20 re-send puts text-only forwards through that hook when the target
/// encrypts, but a media forward, and any forward into a chat that has lost its key, would still be copied by the
/// server. This is the same pair of gates the send hook applies, asked at the forward funnel for the target chat,
/// in the same order: PLAN.md 3.38.2's password lock first, PLAN.md 3.41.2's 「没有钥匙时禁止发送」 second. A forward
/// is always user content — there is no protocol line to exempt.
///
/// Pure and shared by the two Apple clients; the runtime reads the two states off the keyring and the v2 stores
/// exactly as it does for a typed message.
public enum ForwardGate {
    public enum Refusal: Equatable {
        /// PLAN.md 3.38.2: the target group's password policy is on and this run has not unlocked it.
        case groupPasswordLocked
        /// PLAN.md 3.41.2: the target chat's flag is on and it has no usable send key right now.
        case keyRequired
    }

    /// nil = the forward may go ahead (into the 3.20 re-send or the ordinary server-side copy).
    public static func refusal(groupPasswordLocked: Bool, keyRequired: Bool, chatKind: KeyRequired.ChatKind, keyState: KeyRequired.KeyState) -> Refusal? {
        if GroupPasswordSendGate.refuses(locked: groupPasswordLocked, text: "") { return .groupPasswordLocked }
        if KeyRequired.shouldBlockSend(keyRequired: keyRequired, chatKind: chatKind, keyState: keyState, isControlLine: false) { return .keyRequired }
        return nil
    }
}
