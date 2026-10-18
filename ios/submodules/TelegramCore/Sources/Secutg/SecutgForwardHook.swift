import Foundation
import Postbox
import SecutgCore

/// SECUTG: forwarding into an encrypted chat (PLAN.md 3.20), the iOS side of Web A `src/secutg/hooks/forward.ts`.
///
/// A forward is a server-side copy — `messages.forwardMessages` names ids, never text — so the send hook never sees
/// what is being copied. Into an encrypted chat that deposits plaintext, and Saved Messages, which now encrypts
/// itself, is the one chat people forward into constantly.
///
/// Text-only messages are therefore re-sent as ordinary messages, which puts them through the A1 encrypt hook. The
/// costs are deliberate and are paid here: the native "forwarded from" label is gone, so the origin goes inside the
/// ciphertext as a first line; the entities go with it, because their offsets index the text before that line.
///
/// Messages carrying media keep the ordinary forward. Their bytes are outside this project's scope, and a caption
/// cannot be detached from what it captions; those captions arrive as plain text and the 3.13 marker flags them.
public enum SecutgForwardHook {
    /// What the rewrite decided for one forwarded message.
    public struct Rewrite {
        /// The text to send instead, origin line included
        public let text: String
        /// The chat the forward was going into
        public let targetPeerId: PeerId
    }

    /// Everything in `Message.media` is media except a link preview, which the server derives from the text itself
    /// and which therefore costs nothing to lose: the re-sent copy is ciphertext, so no preview could survive anyway.
    public static func hasVisibleMedia(_ message: Message) -> Bool {
        return message.media.contains(where: { !($0 is TelegramMediaWebpage) })
    }

    /// Whether this stored message may be re-sent through the encrypt hook instead of copied by the server.
    ///
    /// Reads the stored text, so for a message sealed under PLAN.md 3.19 it answers about the envelope and says no.
    /// `reencryptedText(of:transaction:accountPeerId:)` opens the envelope first and is the one the forward path
    /// asks; this stays the plain predicate over a stored text.
    public static func isReencryptable(_ message: Message) -> Bool {
        return SecutgForward.isReencryptable(text: message.text, hasMedia: hasVisibleMedia(message))
    }

    /// Who the re-sent copy says it came from. An already-forwarded message keeps pointing at its true origin rather
    /// than at the chat it was picked up in; otherwise it is the source chat, or the author when the chat has no name
    /// of its own (a group's members are named, the group is not, when the reader is not in it).
    ///
    /// `debugDisplayTitle` is the only display title TelegramCore can build without presentation strings, and the
    /// forward hook runs inside a Postbox transaction with none in reach. It is the plain name for every peer type.
    public static func originName(of message: Message, transaction: Transaction) -> String? {
        if let forwardInfo = message.forwardInfo {
            if let source = forwardInfo.source, !source.debugDisplayTitle.isEmpty { return source.debugDisplayTitle }
            if let author = forwardInfo.author, !author.debugDisplayTitle.isEmpty { return author.debugDisplayTitle }
            if let signature = forwardInfo.authorSignature, !signature.isEmpty { return signature }
        }
        if let peer = transaction.getPeer(message.id.peerId), !peer.debugDisplayTitle.isEmpty {
            return peer.debugDisplayTitle
        }
        if let author = message.author, !author.debugDisplayTitle.isEmpty { return author.debugDisplayTitle }
        return nil
    }

    /// The text the re-sent copy carries: the origin line, then the original text. Nil when this message must keep
    /// the ordinary forward.
    public static func reencryptedText(of message: Message, transaction: Transaction, accountPeerId: PeerId) -> String? {
        // PLAN.md 3.19: in a chat that keeps only the envelope, the stored text is the envelope. Forwarding it as it
        // stands would copy a ciphertext the target's readers hold no key for, so the words are opened first and the
        // re-sent copy is encrypted again under the target's key — which is what this hook did before 3.19 and what
        // a forward out of an encrypted chat has always meant.
        var text = message.text
        if message.secutgMeta?.kind == .sealed {
            guard case let .opened(plaintext, _)? = SecutgSealedText.render(message: message, accountPeerId: accountPeerId) else { return nil }
            text = plaintext
        }
        guard SecutgForward.isReencryptable(text: text, hasMedia: hasVisibleMedia(message)) else { return nil }
        let origin = originName(of: message, transaction: transaction)
        let label = SecutgL10n.string("SecutgForwardedFrom", ["name": origin ?? ""])
        return SecutgForward.withOriginLine(text: text, origin: origin, originLabel: label)
    }

    /// The text to re-send for a forward of `sourceId` into `peerId`, or nil when the ordinary forward stands —
    /// because the target does not encrypt, because the message is not there, or because it is not text-only.
    public static func reencryptedText(
        accountPeerId: PeerId, targetPeerId: PeerId, sourceId: MessageId, transaction: Transaction
    ) -> String? {
        guard let runtime = SecutgHookRegistry.shared.runtime(for: accountPeerId),
              runtime.isChatEncrypted(chatPeerId: targetPeerId),
              let source = transaction.getMessage(sourceId) else { return nil }
        return reencryptedText(of: source, transaction: transaction, accountPeerId: accountPeerId)
    }

    /// PLAN.md 3.20: told once per batch, because every copy in it lost its label and its entities.
    public static func reportBatch(accountPeerId: PeerId, targetPeerId: PeerId, count: Int) {
        SecutgHookRegistry.shared.runtime(for: accountPeerId)?.reportForwardReencrypted(chatPeerId: targetPeerId, count: count)
    }
}
