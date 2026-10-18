import Foundation

/// PLAN.md 3.35: the auto mode's whole distribution mechanism — the group's key, in clear, in the group.
///
/// `G2:<chat_id>:<at>:<obfuscated_payload_b64url>:<publisher_user_id>`
///
/// ## Why there is no signature here
///
/// Every other control message has one, and leaving it off looks like an oversight until you read 3.35.1: the
/// `R1 welcome` road it replaces had seven sequential gates, and four batches of fixes each removed one only
/// for the next to surface. Five of the seven were verification steps that could not answer yet — the
/// publisher's `P1` had not arrived, the member's `P1` had not reached the publisher, the admin list was still
/// loading — and every one of them failed by quietly doing nothing. A member ended up with no key and nothing
/// on screen.
///
/// What made the face-to-face road work all along is that the QR payload is self-contained: it depends on
/// nothing this device already holds and on no round trip. `G2` carries **that same payload, byte for byte**,
/// and the only thing the receiver does is pick the newest one.
///
/// What this costs, stated plainly (3.35.2, and CLAUDE.md's amended hard constraint): the key is readable by
/// Telegram's servers and by anyone who can read the group's history, retroactively and forever. The mode that
/// protects against the platform is 当面配对, which does not use this message at all.
public enum G2 {
    /// What a device does with a broadcast it has read (PLAN.md 3.35.4).
    ///
    /// Every case renders a line. `park` and `refuseNotAdmin` are separate cases rather than one `false`
    /// because "not an admin" and "I cannot tell yet" look identical to a member staring at a chat where
    /// nothing happened, and only the second one resolves itself.
    public enum Verdict: String, Equatable, CaseIterable {
        /// Bind this key: the publisher is a known admin and this is the newest broadcast seen.
        case apply
        /// Older than, or the same age as, what is bound. Every scroll through history re-reads these.
        case stale
        /// The admin list has not arrived. Park it, retry when it does, and SAY SO on screen.
        case park
        /// The publisher is not a Telegram admin of this group. Dropped, visibly, and never recorded.
        case refuseNotAdmin
        /// A 当面配对 payload. The modes differ in exactly this: a manual key never travels in clear.
        case refuseNotAuto
        /// This device published it. Shown as 「你发布了新的群密钥」; the key is already here.
        case own
    }

    public struct ParsedG2: Equatable {
        /// Which group. Checked against the chat it arrived in, so it cannot be replayed sideways.
        public let chatId: String
        /// Unix seconds. The ONLY ordering this message has — see `judge`.
        public let at: Int64
        /// `secutg://key?…`, exactly what the offline QR code carries.
        public let keyPayload: String
        /// Who published it. Checked against the Telegram sender, then against the admin list (3.35.4).
        public let publisherId: String
    }

    /// Groups and channels only: a two-person key never travels in clear (CLAUDE.md hard constraint).
    private static let g2Regex = try! NSRegularExpression(
        pattern: "^G2:(-\\d{1,20}):(\\d{1,20}):([A-Za-z0-9_-]+):(\\d{1,20})$")
    private static let maxChars = 4096
    /// Largest `at` every port agrees is a number: JavaScript's Number.MAX_SAFE_INTEGER.
    private static let maxSafeAt: Int64 = 9_007_199_254_740_991

    public static func isG2(_ text: String) -> Bool {
        return text.utf16.count <= maxChars && g2Regex.wholeMatch(text) != nil
    }

    public static func build(chatId: String, at: Int64, keyPayload: String, publisherId: String) -> String? {
        guard let wrapped = G2Obfuscation.obfuscate(keyPayload) else { return nil }
        return "G2:\(chatId):\(at):\(Base64Url.encode(wrapped)):\(publisherId)"
    }

    public static func parse(_ text: String) -> ParsedG2? {
        guard text.utf16.count <= maxChars, let match = g2Regex.wholeMatch(text) else { return nil }
        let g = match.groups(in: text)
        guard g.count == 4, let at = Int64(g[1]), at <= maxSafeAt else { return nil }
        guard let bytes = Base64Url.decode(g[2]) else { return nil }
        // "This build cannot unwrap it" is not a separate answer from "not a key": a broadcast from another
        // fork is not ours to act on, and saying so more precisely tells the reader nothing they can use.
        guard let keyPayload = G2Obfuscation.deobfuscate(bytes),
              keyPayload.hasPrefix(KeyPayload.prefix) else { return nil }
        return ParsedG2(chatId: g[0], at: at, keyPayload: keyPayload, publisherId: g[3])
    }

    /// PLAN.md 3.35.4: one rule, plus one gate that is never silent.
    ///
    /// - Parameters:
    ///   - boundAt: nil when this device has never bound a broadcast for this chat.
    ///   - publisherIsAdmin: nil is the load-bearing value — "the list has not arrived", NOT "no". Collapsing
    ///     the three states into a Bool is the single mistake that broke auto mode four times (3.34.7 rule 1
    ///     is the same point for `N1`).
    ///   - payloadMode: read out of the key payload itself — the key's own property (3.34.1).
    public static func judge(at: Int64, boundAt: Int64?, publisherIsAdmin: Bool?,
                             payloadMode: Rekey.KeyMode, isOwn: Bool) -> Verdict {
        if payloadMode != .auto { return .refuseNotAuto }
        if isOwn { return .own }
        // The publisher gate comes BEFORE the clock. The other order would judge a parked broadcast `stale`
        // on the retry that finally learns who the publisher is — 3.34.3 rule 3's bug, reintroduced by
        // ordering alone.
        guard let isAdmin = publisherIsAdmin else { return .park }
        if !isAdmin { return .refuseNotAdmin }
        if let bound = boundAt, at <= bound { return .stale }
        return .apply
    }
}
