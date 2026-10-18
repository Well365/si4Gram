import Foundation

/// Forwarding into an encrypted chat (PLAN.md 3.20), ported from Web A `src/secutg/hooks/forward.ts`.
///
/// A forward is a server-side copy: the text never passes the send hook, so forwarding a plain message into an
/// encrypted chat deposits plaintext there — most visibly in Saved Messages, which is the one chat people forward
/// into constantly and the one that lives entirely on the server.
///
/// A text-only message can be re-sent instead, which puts it through the ordinary encrypt-on-send path. That costs
/// the native "forwarded from" label, so the origin is carried inside the encrypted text, where it stays readable to
/// the reader and invisible to the server. Entities go with it: their offsets index the text before the origin line.
///
/// Media cannot be re-sent this way: the bytes would have to be re-uploaded, and this project does not encrypt media
/// at all. Media forwards therefore keep the ordinary path, and their captions arrive as plain text, which the 3.13
/// marker already flags in the chat.
public enum SecutgForward {
    /// What a batch of forwards splits into once the target chat is known to encrypt.
    public struct Split<Message> {
        /// messages that must be re-sent as encrypted text rather than forwarded
        public let reencrypt: [Message]
        /// messages that keep the ordinary server-side forward
        public let forward: [Message]

        public init(reencrypt: [Message], forward: [Message]) {
            self.reencrypt = reencrypt
            self.forward = forward
        }
    }

    /// A message whose whole content is text has nothing that needs re-uploading.
    ///
    /// `hasMedia` is the caller's reading of its own message model. On iOS "media" means anything in `Message.media`
    /// that the reader can see; a link preview is not one of those — the server derives it from the text, so a
    /// message that carries only a webpage is still nothing but text.
    public static func isTextOnly(text: String, hasMedia: Bool) -> Bool {
        return !text.isEmpty && !hasMedia
    }

    /// Text that may be re-sent through the encrypt hook: text-only, and not something that has to travel
    /// byte-for-byte.
    ///
    /// Ciphertext this device could not open is stored as the `E1:` payload itself (PLAN.md 3.17). Prepending an
    /// origin line to it would stop it parsing as `E1`, and re-encrypting a ciphertext under a second key helps
    /// nobody — the reader needs the original key either way. Control messages are excluded on their prefix rather
    /// than on a full parse, because that is how the receive hook recognises them: a malformed `R1:` would be routed
    /// to the rekey processor on arrival, so it must not be rewritten here either. Both keep the ordinary forward.
    public static func isReencryptable(text: String, hasMedia: Bool) -> Bool {
        guard isTextOnly(text: text, hasMedia: hasMedia) else { return false }
        return !E1Format.isEncrypted(text) && !text.hasPrefix("R1:") && !text.hasPrefix("P1:")
    }

    /// Splits a forward batch for an encrypted target; an ordinary target is left exactly as it came in.
    public static func split<Message>(
        _ messages: [Message],
        isTargetEncrypted: Bool,
        isReencryptable: (Message) -> Bool
    ) -> Split<Message> {
        guard isTargetEncrypted else { return Split(reencrypt: [], forward: messages) }
        var reencrypt: [Message] = []
        var forward: [Message] = []
        for message in messages {
            if isReencryptable(message) {
                reencrypt.append(message)
            } else {
                forward.append(message)
            }
        }
        return Split(reencrypt: reencrypt, forward: forward)
    }

    /// The origin line kept inside the ciphertext, so it survives without the server reading it. No origin, no line:
    /// a message with nowhere to point back to is re-sent as it stands.
    public static func withOriginLine(text: String, origin: String?, originLabel: String) -> String {
        guard let origin = origin, !origin.isEmpty else { return text }
        return "\(originLabel)\n\(text)"
    }
}
