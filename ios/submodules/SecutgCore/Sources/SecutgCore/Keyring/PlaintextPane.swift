import Foundation

/// PLAN.md 3.30 rule 10: "the other side keeps sending plaintext".
///
/// This is the **only** signal in the whole design that actively tells you the peer has stopped
/// encrypting. The per-message "⚠️ this message is not encrypted" marker exists on all five clients,
/// but it asks the reader to notice a pattern across several messages by themselves; without this
/// pane somebody can keep typing into a chat they still believe is encrypted long after the other end
/// dropped back to plaintext (uninstalled the plugin, switched the chat off, moved to a device that
/// does not have secuTG).
///
/// The judgement is deliberately dull and fixed across the five clients:
///
/// * take the last **20** listed messages — listed, not "in the chat": every client can only see the
///   window it has loaded, and a rule stated over the whole history would mean something different on
///   each of them;
/// * of those keep the ones **from the peer that carry text** — our own messages say nothing about what
///   the peer is doing, and a photo or a sticker is not evidence either way, since only text is ever
///   encrypted;
/// * of *those* take the last **3**, and only speak up when there are three and none of them came
///   through secuTG. Three, because one plaintext message is an accident (a paste from another device, a
///   message sent before the key landed) and a warning that fires on accidents is a warning people learn
///   to dismiss without reading.
///
/// Note the order: the window of 20 is cut **before** filtering, not after. So a burst of twenty of our
/// own messages suppresses the pane rather than reaching further back for three old incoming ones — the
/// question is "what has been happening lately", and twenty messages ago is not lately.
public enum PlaintextPane {
    /// How many listed messages are looked at at all.
    public static let recentWindow = 20
    /// How many consecutive plaintext messages from the peer mean "the peer is not encrypting".
    public static let threshold = 3

    /// What a message's secuTG attribute says about it — the same six states on every client, named here
    /// so `carriesSecutgMeta` can be one pure function rather than five per-platform `if`s over five
    /// different attribute types.
    public enum Meta: String, Equatable {
        /// Opened out of an `E1:` envelope.
        case decrypted
        /// Was an `E1:` envelope; this device could not open it.
        case undecryptable
        /// secuTG's own `R1:` / `P1:` machinery, drawn as a system line.
        case control
        /// A `G1` group invite that came out of an envelope, drawn as a card.
        case groupInvite
        /// Opened, then written back to the database as the envelope it arrived in (PLAN.md 3.19).
        case sealed
        /// Plain text from the peer while this chat encrypts — the "⚠️ not encrypted" marker (3.13 rule 6).
        case plaintext
    }

    /// **Did this message come through secuTG at all?** The one distinction the whole judgement turns on,
    /// isolated here because getting it wrong is silent: a pane that never appears looks exactly like a
    /// peer who never stopped encrypting.
    ///
    /// An `E1:` envelope counts whether or not this device could open it — `undecryptable` is still the
    /// peer encrypting, it is our key that is missing, and reading it as plaintext would accuse them of
    /// something they did not do. Control messages count too: an `R1:` / `P1:` is how the peer sets
    /// encryption *up*, which is the opposite of abandoning it. A decrypted `G1` invite obviously counts.
    ///
    /// `plaintext` does **not** count, and that is the trap this function exists to name. That state is
    /// attached to plain text arriving from the peer *while this chat encrypts* — i.e. to exactly the
    /// messages this pane is counting — and it is what draws the per-message "⚠️ not encrypted" marker.
    /// Web A's `SecutgPlaintextPane.tsx` asks whether the message has *any* secuTG attribute, and since
    /// `secutg/hooks/incoming.ts` attaches `{ state: 'plaintext' }` in precisely this case, its pane can
    /// only ever fire in a chat where that marker is not applied — which is a chat that does not encrypt,
    /// where the pane does not run. That bar is dead code; this one is not. Web A is being fixed to match.
    public static func carriesSecutgMeta(_ meta: Meta?) -> Bool {
        switch meta {
        case .decrypted, .undecryptable, .control, .groupInvite, .sealed:
            return true
        case .plaintext, nil:
            return false
        }
    }

    /// One listed message, reduced to the three facts the judgement uses.
    public struct Message: Equatable {
        /// From the peer rather than from us. Our own messages are not evidence about the other end.
        public let isIncoming: Bool
        /// Carries text. Only text is ever encrypted, so a photo or a sticker proves nothing.
        public let hasText: Bool
        /// This message's secuTG attribute, or nil where it has none. Read only through
        /// `carriesSecutgMeta` — never compared against a state directly at a call site.
        public let meta: Meta?

        public init(isIncoming: Bool, hasText: Bool, meta: Meta?) {
            self.isIncoming = isIncoming
            self.hasText = hasText
            self.meta = meta
        }
    }

    /// Whether the pane should be on screen right now.
    ///
    /// - Parameters:
    ///   - isChatEncrypted: this chat is set to encrypt. The pane is about a disagreement between the two
    ///     ends; where we are not encrypting either there is no disagreement to report.
    ///   - isDismissed: the user answered the pane in this chat during this session (see the note on the
    ///     three buttons in PLAN.md 3.30 rule 10: two of them mean this and only the third changes state).
    ///   - recent: the listed messages, **oldest first**, as the client has them loaded.
    public static func isDue(isChatEncrypted: Bool, isDismissed: Bool, recent: [Message]) -> Bool {
        guard isChatEncrypted, !isDismissed else { return false }
        return isPeerPlaintext(recent: recent)
    }

    /// The half of `isDue` that depends only on the messages.
    ///
    /// Split out because the two halves change at completely different moments: this one only when the
    /// message list moves, the rest of `isDue` when a button is tapped or the chat's encryption switch is
    /// flipped. A client that watches the message list can cache this and re-ask `isDue` for free.
    public static func isPeerPlaintext(recent: [Message]) -> Bool {
        let window = recent.suffix(recentWindow)
        let fromPeer = window.filter { $0.isIncoming && $0.hasText }
        let latest = fromPeer.suffix(threshold)
        guard latest.count >= threshold else { return false }
        return latest.allSatisfy { !carriesSecutgMeta($0.meta) }
    }
}
