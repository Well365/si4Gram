import Foundation

/// v1.4 section 15/16's E2 send/receive bookkeeping — everything `V2E2` deliberately leaves to a
/// caller: per-(chat, generation) monotonic seq assignment, outbox retry, and receive-side dedup by
/// (state, sender, msg_id). Ported from `src/secutg/v2/data/processor.ts` and
/// `org.telegram.secutg.v2.data.DataProcessor`.
///
/// Like `V2E2` itself, this class never resolves a master or a key-derivation salt on its own — both
/// are supplied by the caller on every send/receive call.
///
/// One V2DataProcessor instance represents ONE device's send/receive state across every chat it
/// participates in (private or group alike) — the same "one instance per device" shape
/// V2PairingProcessor and V2GroupProcessor already use, keyed internally by chatId.
///
/// seq is a per-device-per-generation monotonically increasing UNSIGNED 64-bit value (v1.4 section
/// 15) — represented here as a native Swift `UInt64` (a true unsigned 64-bit integer), unlike the
/// Java port which needs `BigInteger` since `long` is signed and only covers half that range.
public final class V2DataProcessor {
    public struct SendParams {
        public let chatId: String
        public let genesisOrBinding: String
        public let epoch: String
        public let saltStateOrBindingHash: [UInt8]
        public let master: [UInt8]
        public let senderIdentityPk: [UInt8]
        public let senderIdentitySk: [UInt8]
        /// Group messages only — nil for a private chat.
        public let permitHash: String?
        public let plaintext: [UInt8]
        /// Omit (nil) for a NEW message — a fresh msgId and the next seq for this (chatId, epoch)
        /// are assigned. Pass the msgId an earlier send() call returned to REPLAY that exact wire
        /// byte-for-byte (v1.4 section 15).
        public let retryMsgId: String?

        public init(chatId: String, genesisOrBinding: String, epoch: String, saltStateOrBindingHash: [UInt8], master: [UInt8], senderIdentityPk: [UInt8], senderIdentitySk: [UInt8], permitHash: String?, plaintext: [UInt8], retryMsgId: String?) {
            self.chatId = chatId
            self.genesisOrBinding = genesisOrBinding
            self.epoch = epoch
            self.saltStateOrBindingHash = saltStateOrBindingHash
            self.master = master
            self.senderIdentityPk = senderIdentityPk
            self.senderIdentitySk = senderIdentitySk
            self.permitHash = permitHash
            self.plaintext = plaintext
            self.retryMsgId = retryMsgId
        }
    }

    public struct SendOutcome {
        public let wire: String
        public let msgId: String
    }

    public struct ReceiveParams {
        public let master: [UInt8]
        public let saltStateOrBindingHash: [UInt8]
        public let senderIdentityPk: [UInt8]
        /// The "state" component of v1.4 section 16's replay_index dedup key (state + sender +
        /// msg_id).
        public let dedupStateKey: String

        public init(master: [UInt8], saltStateOrBindingHash: [UInt8], senderIdentityPk: [UInt8], dedupStateKey: String) {
            self.master = master
            self.saltStateOrBindingHash = saltStateOrBindingHash
            self.senderIdentityPk = senderIdentityPk
            self.dedupStateKey = dedupStateKey
        }
    }

    public struct ReceiveOutcome {
        public let ok: Bool
        public let kind: String? // "installed" | "duplicate"
        public let plaintext: [UInt8]?
        public let header: V2E2.Header?
        public let reason: String?

        static func ok(_ kind: String, plaintext: [UInt8], header: V2E2.Header) -> ReceiveOutcome {
            return ReceiveOutcome(ok: true, kind: kind, plaintext: plaintext, header: header, reason: nil)
        }

        static func fail(_ reason: String) -> ReceiveOutcome {
            return ReceiveOutcome(ok: false, kind: nil, plaintext: nil, header: nil, reason: reason)
        }
    }

    private struct OutboxEntry {
        let wire: String
        let seq: String
    }

    private struct ReplayEntry {
        let plaintext: [UInt8]
        let header: V2E2.Header
    }

    /// "${chatId}\0${msgId}" -> the exact wire this device already built for it.
    private var outbox: [String: OutboxEntry] = [:]
    /// "${chatId}\0${epoch}" -> the next seq to assign.
    private var nextSeq: [String: UInt64] = [:]
    /// "${dedupStateKey}\0${senderDevice}\0${msgId}" -> the already-processed result.
    private var replayIndex: [String: ReplayEntry] = [:]

    public init() { }

    /// v1.4 section 15: builds and signs an E2 message, assigning the next seq for (chatId, epoch)
    /// and remembering the exact wire under a fresh msg_id — or, given retryMsgId, returns that
    /// EXACT previously-built wire again, never re-encrypting or advancing seq.
    public func send(_ params: SendParams) -> SendOutcome? {
        if let retryMsgId = params.retryMsgId {
            let outboxKey = params.chatId + "\0" + retryMsgId
            guard let existing = outbox[outboxKey] else { return nil } // this device never sent that msgId for this chat
            return SendOutcome(wire: existing.wire, msgId: retryMsgId)
        }

        let senderDevice = V2E2.deviceIdOf(params.senderIdentityPk)
        let seq = nextSeqFor(chatId: params.chatId, epoch: params.epoch)
        let msgId = Base64Url.encode(V2Suite.randomBytes(V2Envelope.idBytes))
        let header = V2E2.Header(chatId: params.chatId, genesisOrBinding: params.genesisOrBinding, epoch: params.epoch, senderDevice: senderDevice, permitHash: params.permitHash, msgId: msgId, seq: String(seq))
        guard let wire = V2E2.build(V2E2.BuildParams(header: header, plaintext: params.plaintext, master: params.master, saltStateOrBindingHash: params.saltStateOrBindingHash, senderIdentitySk: params.senderIdentitySk, nonce: nil)) else {
            return nil
        }
        outbox[params.chatId + "\0" + msgId] = OutboxEntry(wire: wire, seq: header.seq)
        return SendOutcome(wire: wire, msgId: msgId)
    }

    /// v1.4 section 15/16: verifies, dedups, and decrypts. A REPEAT of an already-processed (state,
    /// sender, msg_id) returns the SAME cached result idempotently, without re-verifying or
    /// re-decrypting. Ordering is NEVER enforced (v1.4: "current receiving allows out-of-order
    /// delivery").
    public func receive(_ wire: String, _ params: ReceiveParams) -> ReceiveOutcome {
        guard let parsed = V2E2.parse(wire) else { return .fail("malformed") }

        let replayKey = params.dedupStateKey + "\0" + parsed.header.senderDevice + "\0" + parsed.header.msgId
        if let cached = replayIndex[replayKey] {
            return .ok("duplicate", plaintext: cached.plaintext, header: cached.header)
        }

        guard V2E2.verifySignature(parsed, senderIdentityPk: params.senderIdentityPk) else { return .fail("bad_signature") }
        guard let plaintext = V2E2.decrypt(parsed, master: params.master, saltStateOrBindingHash: params.saltStateOrBindingHash) else { return .fail("decrypt_failed") }

        replayIndex[replayKey] = ReplayEntry(plaintext: plaintext, header: parsed.header)
        return .ok("installed", plaintext: plaintext, header: parsed.header)
    }

    private func nextSeqFor(chatId: String, epoch: String) -> UInt64 {
        let key = chatId + "\0" + epoch
        let current = nextSeq[key] ?? 1
        nextSeq[key] = current + 1
        return current
    }
}
