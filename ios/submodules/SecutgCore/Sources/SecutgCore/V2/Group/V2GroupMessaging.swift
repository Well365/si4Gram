import Foundation

/// The ACTUAL sending/receiving surface for GROUP business messages — the group analog of
/// `V2PrivateChatMessaging`. Resolves a group's (genesis_id, epoch) -> state_hash (the real HKDF
/// salt) via `V2GroupState.GroupStateStore.findByGenesisAndEpoch`, and the master via
/// `V2GroupKeyStore`. Ported from `src/secutg/v2/group/messaging.ts` and
/// `org.telegram.secutg.v2.group.GroupMessaging`.
///
/// permitHash is deliberately left unset on every message this file builds. Nothing in this codebase
/// tracks a per-device PERMIT event hash outside the JOIN_REQUEST flow — a device added via
/// commitAddDevice never has one at all — and the header field's role is informational/AAD-bound, not
/// the PRIMARY authorization mechanism. That mechanism is receive()'s own check, below, that
/// sender_device is actually in the RESOLVED generation's own deviceRoster.
public final class V2GroupMessaging {
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
    private let group: V2GroupProcessor
    private let e2: V2DataProcessor

    public init(identity: V2Identity, group: V2GroupProcessor, e2: V2DataProcessor) {
        self.identity = identity
        self.group = group
        self.e2 = e2
    }

    /// v1.4 section 15: encrypts plaintext under the group's CURRENT generation's master and signs
    /// it as this device.
    public func send(_ groupId: String, plaintext: [UInt8], retryMsgId: String? = nil) -> SendOutcome {
        guard let state = group.stateStore.current(groupId) else { return .fail("no_state") }
        guard group.canSend(groupId) else { return .fail("cannot_send") }
        guard let record = group.keyStore.get(groupId, state.stateHash), let master = record.master else { return .fail("no_current_key") }
        guard let saltBytes = Base64Url.decode(state.stateHash) else { return .fail("malformed_state") }

        guard let outcome = e2.send(V2DataProcessor.SendParams(
            chatId: groupId, genesisOrBinding: state.genesisId, epoch: String(state.epoch), saltStateOrBindingHash: saltBytes, master: master,
            senderIdentityPk: identity.publicKey, senderIdentitySk: identity.secretKey, permitHash: nil, plaintext: plaintext, retryMsgId: retryMsgId
        )) else { return .fail("build_failed") }
        return .ok(wire: outcome.wire, msgId: outcome.msgId)
    }

    /// v1.4 section 15: resolves the SPECIFIC generation (genesis_id, epoch) names (current OR
    /// historical — v1.4 section 37), checks the sender was actually a member of THAT generation's
    /// own roster snapshot (not the current one), then verifies, dedups, and decrypts.
    public func receive(_ wire: String) -> V2DataProcessor.ReceiveOutcome {
        guard let parsed = V2E2.parse(wire) else { return .fail("malformed") }

        let groupId = parsed.header.chatId
        guard let epoch = Int(parsed.header.epoch) else { return .fail("unknown_state") }
        guard let state = group.stateStore.findByGenesisAndEpoch(groupId: groupId, genesisId: parsed.header.genesisOrBinding, epoch: epoch) else {
            return .fail("unknown_state")
        }
        guard state.deviceRoster.contains(parsed.header.senderDevice) else { return .fail("sender_not_in_roster") }

        guard let senderKeys = state.deviceKeys[parsed.header.senderDevice] else { return .fail("unknown_sender") }
        guard let senderPk = Base64Url.decode(senderKeys.identityPk) else { return .fail("malformed_sender_key") }

        guard let record = group.keyStore.get(groupId, state.stateHash), let master = record.master else { return .fail("missing_key") }
        guard let saltBytes = Base64Url.decode(state.stateHash) else { return .fail("malformed_state") }

        return e2.receive(wire, V2DataProcessor.ReceiveParams(master: master, saltStateOrBindingHash: saltBytes, senderIdentityPk: senderPk, dedupStateKey: state.stateHash))
    }
}
