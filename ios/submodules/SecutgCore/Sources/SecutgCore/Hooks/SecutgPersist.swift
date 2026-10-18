import Foundation

/// What an encrypted chat's message leaves behind on this device's disk (PLAN.md 3.19).
///
/// The decrypt hook sits where a message is built (`StoreMessage(apiMessage:)`), so until now the local database
/// held the words. The wire and the server were protected and the device was not — and the keyring guarding these
/// messages lives in the Keychain while the messages themselves lay beside it in the clear.
///
/// The swap happens on the way into storage: what is written is the envelope the words came out of, and the words
/// are kept in `SecutgPlaintextCache` for as long as this process lives. Reading a message back opens it again —
/// from the cache when it is still there, from the keyring when it is not — so the reader sees the words either way.
///
/// Encrypted chats only. An ordinary chat is stored exactly as it always was, which is what keeps its search working.
public enum SecutgPersist {
    /// The form a message takes in the local database.
    public struct Stored: Equatable {
        /// what goes into the message's text
        public let text: String
        /// the entities stored beside it — empty for a sealed message, whose entities travel inside the envelope
        public let entities: [E1Entity]
        /// true when `text` is the envelope rather than the words
        public let isSealed: Bool

        public init(text: String, entities: [E1Entity], isSealed: Bool) {
            self.text = text
            self.entities = entities
            self.isSealed = isSealed
        }
    }

    /// `wire` is the envelope the plaintext came out of — v1's `E1:`, or v2's `E2:` (PLAN.md 3.44: private chats
    /// and groups alike, the same rule). A chat that does not encrypt, or one whose setting is off, is stored
    /// exactly as it is — there is nothing to swap in, and pretending otherwise would put a message beyond reach
    /// of the only key that opens it.
    public static func storedForm(plaintext: String, entities: [E1Entity]?, wire: String, keepsCiphertextLocally: Bool) -> Stored {
        guard keepsCiphertextLocally, isEnvelope(wire) else {
            return Stored(text: plaintext, entities: entities ?? [], isSealed: false)
        }
        return Stored(text: wire, entities: [], isSealed: true)
    }

    /// What may stand on the disk in place of the words: a wire of either generation, judged by shape the way
    /// `E1Format.isEncrypted` always has. A text that merely begins with `E1:` / `E2:` is words, and sealing words
    /// away behind themselves would leave nothing any key could open.
    public static func isEnvelope(_ wire: String) -> Bool {
        return E1Format.isEncrypted(wire) || V2E2.isWire(wire)
    }
}

/// The words of the messages this session has already opened, keyed by the envelope they came out of (PLAN.md 3.19).
///
/// This client pages messages out of the database instead of keeping them all in memory, so "store the envelope"
/// means "open it again on the way out". Opening is an AEAD decryption per message and the chat list re-renders far
/// more often than it reads, so what has been opened once is kept for the rest of the process — and only for the rest
/// of the process: nothing here is ever written down.
///
/// Keyed by the envelope rather than by a message id on purpose: the envelope carries a random 24-byte nonce, so it
/// identifies the message on its own, and the same entry serves the bubble, the chat list and a re-read of the same
/// message under a different id (a sent message that the server echoes back, for instance).
///
/// Bounded and first-in-first-out. Eviction costs one decryption, never a wrong answer.
public final class SecutgPlaintextCache {
    public struct Opened: Equatable {
        public let text: String
        public let entities: [E1Entity]

        public init(text: String, entities: [E1Entity]) {
            self.text = text
            self.entities = entities
        }
    }

    private let limit: Int
    private let lock = NSLock()
    private var entries: [String: Opened] = [:]
    private var order: [String] = []

    public init(limit: Int = 4096) {
        self.limit = max(1, limit)
    }

    public func remember(wire: String, text: String, entities: [E1Entity]) {
        lock.lock(); defer { lock.unlock() }
        if entries.updateValue(Opened(text: text, entities: entities), forKey: wire) == nil {
            order.append(wire)
            while order.count > limit {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
    }

    public func opened(wire: String) -> Opened? {
        lock.lock(); defer { lock.unlock() }
        return entries[wire]
    }

    /// Called when the keyring changes under us — a key removed, a chat unpaired, the setting flipped, a wipe.
    /// Dropping everything is always safe: the envelopes are still in the database and re-open from the keyring.
    public func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }
}
