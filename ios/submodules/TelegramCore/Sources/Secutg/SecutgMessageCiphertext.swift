import Foundation
import Postbox
import SecutgCore

/// SECUTG: the `E1:` envelope behind one message, for the context-menu entry of PLAN.md 3.17 rule 6.
///
/// Which of the two places the bytes are in is decided by the meta attribute's kind, not by "whichever value
/// happens to look like an envelope" — `MessageCiphertext` in SecutgCore says why, and its tests pin it. The
/// three kinds that are never encrypted at all (`.control`, `.groupInvite`, `.plaintext`) and a message with no
/// meta return nothing, and the entry is then **absent rather than disabled**: on an ordinary message it would
/// be answering a question nobody asked.
public extension Message {
    var secutgCiphertext: String? {
        guard let meta = self.secutgMeta else { return nil }
        let form: MessageCiphertext.StoredForm
        switch meta.kind {
        case .undecryptable, .sealed:
            // The stored text *is* the envelope: never opened (rule 1), or put away by 3.19. Both are rule 2
            // working as designed — the bytes were never replaced, only what is drawn over them.
            form = .envelopeIsText
        case .decrypted:
            // The words are stored; the envelope rides in the attribute beside them, kept whatever 3.19 says.
            form = .wordsWithEnvelope
        case .control, .groupInvite, .plaintext:
            form = .none
        }
        return MessageCiphertext.resolve(form: form, storedText: self.text, envelope: meta.wire)
    }
}
