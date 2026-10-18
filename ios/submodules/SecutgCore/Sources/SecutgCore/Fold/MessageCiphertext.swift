import Foundation

/// The `E1:` — or, PLAN.md 3.44, v2's `E2:` — envelope behind one message, when this device still has it
/// (PLAN.md 3.17 rule 6).
///
/// This does not overturn rule 1. Rule 1 is about what the reader is *shown* without asking, and the answer
/// there is still a sentence rather than a screen of base64. This is the other case: the reader asked. The three
/// things he can do with it are carry the message to a device that has the key, check whether it was altered on
/// the way (the `auth_failed` line of rule 1 says it might have been, and only the bytes can settle it), and
/// hand it to somebody debugging. None of those depend on whether the message opened, which is why a decrypted
/// message offers it too.
///
/// Where the bytes come from follows rule 2 — storage keeps the ciphertext, only the rendering layer puts words
/// in its place — and there are exactly two places they can be, which is what `StoredForm` names.
public enum MessageCiphertext {
    /// Which of the two places this message's envelope is in.
    public enum StoredForm: Equatable {
        /// The message's own text **is** the envelope: one that never opened (rule 1), one stored sealed
        /// (PLAN.md 3.19), or the anchor of a folded run, which keeps its own envelope untouched underneath the
        /// collapsed line (rule 5).
        case envelopeIsText
        /// The text is the words. The envelope, if this device kept it, is the separate value beside them.
        case wordsWithEnvelope
        /// Nothing encrypted here at all: an ordinary message, a control line, a group-invite card.
        case none
    }

    /// v1's business envelope and v2's (PLAN.md 3.44: a v2 row is put away behind `E2:` on the same terms). The
    /// control families (`P2:`, `G2:`, `R1:`…) are not here: a control line is never "ciphertext" to look at.
    private static let envelopePrefixes = ["E1:", "E2:"]

    /// The envelope to show, or nil when there is none — in which case the menu entry is **absent rather than
    /// disabled**, because on a never-encrypted message it would be answering a question nobody asked.
    ///
    /// The form decides which value is even looked at, rather than "whichever of the two looks like an
    /// envelope". Plaintext that happens to begin with `E1:` is rare but perfectly possible — somebody quoting a
    /// wire in a message — and handing that to a dialog labelled "ciphertext" would be showing the words under
    /// the one label that promises they are not the words.
    ///
    /// The prefix test is deliberately looser than `E1Format.isEncrypted`: a malformed envelope is one of the
    /// things somebody opens this dialog to look at, and the strict parser would leave him with nothing to look
    /// at in exactly the case where he needs the bytes most.
    public static func resolve(form: StoredForm, storedText: String?, envelope: String?) -> String? {
        let candidate: String?
        switch form {
        case .envelopeIsText: candidate = storedText
        case .wordsWithEnvelope: candidate = envelope
        case .none: candidate = nil
        }
        guard let candidate = candidate, envelopePrefixes.contains(where: { candidate.hasPrefix($0) }) else { return nil }
        return candidate
    }
}
