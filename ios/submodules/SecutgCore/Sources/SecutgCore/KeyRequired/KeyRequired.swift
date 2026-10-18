import Foundation

/// PLAN.md 3.41: a chat that has encrypted once refuses to send plaintext while it has no usable send key.
///
/// The composer of a Telegram client works the same whether or not a chat has a key, and a key goes away quietly:
/// a reinstall or an emergency wipe, the peer unpairing or changing device, an admin retiring the group key, a
/// 3.39 share code not yet adopted. The user sees the same input box in every one of those moments, and that is
/// exactly when words meant to be encrypted go out in the clear. 3.38's password lock already refuses to send for
/// a locked group; this generalises the same gate to every chat that has ever held a key.
///
/// Pure, and shared byte for byte by the two Apple clients: the table below (`shouldBlockSend`) and the record's
/// two transitions (`observed`, `toggled`) are what the unit tests pin. Reading the live key state out of the
/// keyring and the v2 stores, and deciding where the refusal is shown, belong to the runtime and the UI layers.
///
/// What this flag is **not**: an encryption switch. Media are not encrypted today (PLAN.md 3.27), and nothing
/// here changes that — the flag is about the *state* "this chat has no key", not about what a key would cover,
/// and no wording built on it may promise that everything is encrypted.
public enum KeyRequired {
    /// The three kinds of chat the flag applies to (3.41.1). Saved Messages is its own kind because it has no
    /// peer to pair with — its key is made locally (PLAN.md 3.20) — yet it is the chat whose whole contents
    /// live on the server, so losing its key matters as much as anywhere.
    public enum ChatKind: Equatable {
        case privateChat
        case group
        case savedMessages
    }

    /// Whether the chat has a usable **send** key right now, in the terms of 3.41.2 and the 3.41.5 table.
    ///
    /// Spelled out per kind rather than as one boolean so a test can name the row it is checking, and so a
    /// status page can say why a send was refused. `isUsable` is the only thing the gate reads.
    public enum KeyState: Equatable {
        // 1v1
        /// A current v2 binding that may send (`V2Binding.BindingStore.canSend`).
        case v2Sendable
        /// No sendable v2 binding, but a v1 key — a legacy pairing or a manually imported key — still encrypts.
        case v1LegacyOnly
        /// Nothing at all, in either protocol.
        case notPaired
        /// A binding existed and was torn down (this side or the peer's).
        case unpaired
        /// An exchange is in flight (v2 INVITE / SELECT / CONFIRM, or another device holds the pairing).
        case invited
        /// PLAN.md 3.39: a V2Q join is installed but its commit is not adopted yet — readable, not sendable.
        case joinPending
        /// A binding is present but sending is paused (replace in progress, or a safety-code mismatch).
        case suspended
        // group / supergroup
        /// A current group key, whichever road it came by.
        case groupKey
        /// No current group key (a 3.38 password-locked group is refused before this is ever asked).
        case noGroupKey
        // Saved Messages
        case savedKey
        case noSavedKey

        public var isUsable: Bool {
            switch self {
            case .v2Sendable, .v1LegacyOnly, .groupKey, .savedKey:
                return true
            case .notPaired, .unpaired, .invited, .joinPending, .suspended, .noGroupKey, .noSavedKey:
                return false
            }
        }
    }

    /// The 3.41.5 table.
    ///
    /// - Parameters:
    ///   - keyRequired: the chat's flag (3.41.1)
    ///   - chatKind: which kind of chat this is. Part of the shared signature so every client's table reads the
    ///     same; the decision itself does not branch on it — the kind is already inside `keyState`.
    ///   - keyState: whether a usable send key exists right now
    ///   - isControlLine: an app-generated protocol line (`P2` / `G2` / `GP1` / `N1` / `U1` / `R1` / `P1`, an
    ///     already-sealed envelope being resent). Those are the roads a key comes back by, so they always pass.
    /// - Returns: true when the send must be refused — user content only, nothing sent, draft kept (3.41.2).
    public static func shouldBlockSend(keyRequired: Bool, chatKind: ChatKind, keyState: KeyState, isControlLine: Bool) -> Bool {
        _ = chatKind
        guard keyRequired else { return false }
        if isControlLine { return false }
        return !keyState.isUsable
    }

    /// The per-chat record (3.41.1). Local only: never on the wire and never in a K1 / K2 backup — a restored
    /// key re-arms it by itself, so there is nothing to back up.
    public struct Record: Codable, Equatable {
        /// The flag.
        public var enabled: Bool
        /// The identity of the send key the chat had when the user turned the flag off by hand — nil when there
        /// was none, and nil when the flag was never turned off by hand. Auto-arm stays quiet for exactly this
        /// key: turning the flag off is a deliberate act, and it comes back only when the chat gains a *new*
        /// key (unpair, then pair again).
        public var manualOffKeyId: String?

        public init(enabled: Bool, manualOffKeyId: String? = nil) {
            self.enabled = enabled
            self.manualOffKeyId = manualOffKeyId
        }
    }

    /// Auto-arm (3.41.1 「自动打开」): the chat's current send-key identity has just been observed. `keyId` is the
    /// identity of the key that makes the chat sendable — a v2 binding id, a v1 master id, a group key id — or
    /// nil when there is none.
    ///
    /// Returns the record to store: the same value when nothing changes. The rules, in order: no key arms
    /// nothing; the first key a chat ever has on this device turns the flag on; a flag already on stays on; a
    /// flag turned off by hand stays off for the key it was turned off under; any other key is a new key and
    /// turns it back on.
    public static func observed(_ record: Record?, keyId: String?) -> Record? {
        guard let keyId = keyId else { return record }
        guard let record = record else { return Record(enabled: true) }
        if record.enabled { return record }
        if record.manualOffKeyId == keyId { return record }
        return Record(enabled: true, manualOffKeyId: nil)
    }

    /// The lock menu's switch (3.41.1 「手动」), and the notice's 〔本聊天允许明文〕. Turning the flag off remembers
    /// the current key so `observed` does not turn it straight back on for the same key.
    public static func toggled(_ record: Record?, enabled: Bool, currentKeyId: String?) -> Record {
        _ = record
        return enabled
            ? Record(enabled: true, manualOffKeyId: nil)
            : Record(enabled: false, manualOffKeyId: currentKeyId)
    }
}
