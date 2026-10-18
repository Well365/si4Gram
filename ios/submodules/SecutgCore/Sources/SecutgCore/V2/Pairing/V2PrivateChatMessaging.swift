import Foundation

/// The ACTUAL sending/receiving surface for private-chat business messages: resolves every parameter
/// `V2E2`/`V2DataProcessor` deliberately leave to a caller (master, HKDF salt, sender identity) from a
/// `V2Processor.PairingProcessor`'s own binding + keyStore state, then delegates to a shared
/// `V2DataProcessor`. Ported from `src/secutg/v2/pairing/messaging.ts` and
/// `org.telegram.secutg.v2.pairing.PrivateChatMessaging`.
///
/// A SEPARATE type from V2Processor/V2Roster, for the same file-size reason V2Roster already is:
/// constructed over a device's SAME bindingStore/keyStore those already own, plus the V2DataProcessor
/// instance this device's whole message traffic (private chats AND groups alike) shares — one
/// V2DataProcessor per device, not one per chat.
///
/// For a GROUP chat's equivalent, see `V2GroupMessaging` — the same shape, resolving a group's
/// (genesis_id, epoch) -> state_hash instead of a private chat's fixed binding_id.
public final class V2PrivateChatMessaging {
    public struct SendOutcome {
        public let ok: Bool
        public let wire: String?
        public let msgId: String?
        public let reason: String?

        static func ok(wire: String, msgId: String) -> SendOutcome {
            return SendOutcome(ok: true, wire: wire, msgId: msgId, reason: nil)
        }

        static func fail(_ reason: String) -> SendOutcome {
            return SendOutcome(ok: false, wire: nil, msgId: nil, reason: reason)
        }
    }

    private let identity: V2Identity
    private let pairing: V2Processor.PairingProcessor
    private let e2: V2DataProcessor

    public init(identity: V2Identity, pairing: V2Processor.PairingProcessor, e2: V2DataProcessor) {
        self.identity = identity
        self.pairing = pairing
        self.e2 = e2
    }

    /// v1.4 section 15: encrypts plaintext under the binding's CURRENT master and signs it as this
    /// device. retryMsgId (an id an earlier send() call returned) reproduces that EXACT wire instead
    /// of building a new one — V2DataProcessor.send's own retry contract, just threaded through.
    public func send(_ chatId: String, plaintext: [UInt8], retryMsgId: String? = nil) -> SendOutcome {
        guard let binding = pairing.bindingStore.current(chatId) else { return .fail("no_binding") }
        guard pairing.canSend(chatId) else { return .fail("cannot_send") }
        guard let record = pairing.keyStore.get(binding.bindingId, binding.epoch), let master = record.master else { return .fail("no_current_key") }
        guard let saltBytes = Base64Url.decode(binding.bindingId) else { return .fail("malformed_binding") }
        // PLAN.md 3.39.4 step 6: on a binding joined by V2Q, `sender_device` and the signature are the per-binding
        // identity's — the roster the peer verifies against knows THAT device, not this one.
        let sender = V2OwnIdentity.identity(for: binding, fallback: identity)

        guard let outcome = e2.send(V2DataProcessor.SendParams(
            chatId: chatId, genesisOrBinding: binding.bindingId, epoch: String(binding.epoch), saltStateOrBindingHash: saltBytes, master: master,
            senderIdentityPk: sender.publicKey, senderIdentitySk: sender.secretKey, permitHash: nil, plaintext: plaintext, retryMsgId: retryMsgId
        )) else { return .fail("build_failed") }
        return .ok(wire: outcome.wire, msgId: outcome.msgId)
    }

    /// v1.4 section 15: verifies, dedups, and decrypts an incoming E2 wire. Resolves the sender's
    /// identity_pk from the binding's own deviceKeys (current OR historical — an old binding's
    /// history stays readable, v1.4 section 37) rather than trusting anything the wire itself claims
    /// about who sent it.
    ///
    /// SECUTG-HOOK (fix C0, 2026-09-27): `localChatId` = the chat this device received the message in
    /// (its own name for the conversation). The header's `chat_id` is the SENDER's view — on a real 1:1
    /// chat, this device's own user id — so bindings are searched under `localChatId` instead. nil keeps
    /// the old behaviour (header chat id) for callers on a shared chat id.
    public func receive(_ wire: String, localChatId: String? = nil) -> V2DataProcessor.ReceiveOutcome {
        guard let parsed = V2E2.parse(wire) else { return .fail("malformed") }

        let chatId = localChatId ?? parsed.header.chatId
        let bindingId = parsed.header.genesisOrBinding
        var binding: V2Binding? = nil
        if let current = pairing.bindingStore.current(chatId), current.bindingId == bindingId {
            binding = current
        } else {
            binding = pairing.bindingStore.historical(chatId).first { $0.bindingId == bindingId }
        }
        guard let binding = binding else { return .fail("unknown_binding") }

        guard let senderKeys = binding.deviceKeys[parsed.header.senderDevice] else { return .fail("unknown_sender") }
        guard let senderPk = Base64Url.decode(senderKeys.identityPk) else { return .fail("malformed_sender_key") }

        guard let epoch = Int(parsed.header.epoch) else { return .fail("missing_key") }
        guard let record = pairing.keyStore.get(bindingId, epoch), let master = record.master else { return .fail("missing_key") }
        guard let saltBytes = Base64Url.decode(bindingId) else { return .fail("malformed_binding") }

        return e2.receive(wire, V2DataProcessor.ReceiveParams(master: master, saltStateOrBindingHash: saltBytes, senderIdentityPk: senderPk, dedupStateKey: bindingId))
    }
}
