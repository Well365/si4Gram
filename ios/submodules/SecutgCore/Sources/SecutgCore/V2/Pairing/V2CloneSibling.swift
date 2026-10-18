import Foundation

/// PLAN.md 3.39.13 「必改项」 3 (同账号重配): two devices of one account share a chat's device identity after a V2Q
/// clone. When the OTHER one pairs this chat again — its INVITE / ACCEPT / CONFIRM / READY, outgoing on this device,
/// signed by the shared identity, for a pairing other than the one behind this device's current binding, and made
/// after this device installed that binding — the peer is moving to a binding this device will never hold. This
/// device sets its own aside (`SecutgV2CloneSiblingRepaired`: scan a new code), by the same mechanism as the
/// 2026-09-29 superseded-UNPAIR fix (`PairingProcessor.unpairSupersededBinding`): tombstoned with the triggering
/// message's `event_id`, deactivated, history masters kept.
///
/// "Another pairing" per message type: CONFIRM / READY name it (`transcript_hash` = the binding id they produce) and
/// must differ from this binding's id; INVITE / ACCEPT carry no binding id yet, so their transaction must differ from
/// the one that installed this binding (`binding.txnId` — for a clone `clone:<bindingId>`, which no wire transaction
/// ever equals; the creation-time rule is what keeps the handshake that made the shared binding, re-rendering from
/// history, from counting). A transaction THIS device is running itself (`phaseOf` knows it) is never a sibling's.
/// SELECT / MERGE / BUSY are not on the plan's list: SELECT always follows the same initiator's INVITE.
/// Ported from Web A `src/secutg/v2/pairing/cloneSibling.ts`; kept out of `V2Processor.swift` for its size.
public enum V2CloneSibling {
    public enum RepairOutcome: Equatable {
        case retired(bindingId: String)
        case notRetired(reason: String)
    }

    private struct PairingStep {
        let envelope: V2Envelope
        let transcriptHash: String?
    }

    private static func parsePairingStep(_ wire: String) -> PairingStep? {
        switch V2Envelope.parse(prefix: V2Messages.prefix, text: wire)?.type {
        case "INVITE": return V2Messages.parseInvite(wire).map { PairingStep(envelope: $0.envelope, transcriptHash: nil) }
        case "ACCEPT": return V2Messages.parseAccept(wire).map { PairingStep(envelope: $0.envelope, transcriptHash: nil) }
        case "CONFIRM": return V2Messages.parseConfirm(wire).map { PairingStep(envelope: $0.envelope, transcriptHash: $0.body.transcriptHash) }
        case "READY": return V2Messages.parseReady(wire).map { PairingStep(envelope: $0.envelope, transcriptHash: $0.body.transcriptHash) }
        default: return nil
        }
    }

    /// Applies 「必改项」 3 to `localChatId` for an outgoing pairing step whose actor is this device's own identity for
    /// the chat (`ownDeviceId`, established by the caller). Idempotent: once retired there is no current binding left.
    public static func retireOnSiblingRepair(_ pairing: V2Processor.PairingProcessor, localChatId: String, ownDeviceId: String, wire: String, nowMs: Int64) -> RepairOutcome {
        guard let step = parsePairingStep(wire) else { return .notRetired(reason: "not_a_pairing_step") }
        let envelope = step.envelope
        guard let binding = pairing.bindingStore.current(localChatId) else { return .notRetired(reason: "no_binding") }
        guard envelope.actorDevice == ownDeviceId else { return .notRetired(reason: "not_own_identity") }
        guard let ownKeys = binding.deviceKeys[ownDeviceId], V2Messages.verifyTyped(envelope, identityPkB64: ownKeys.identityPk) else {
            return .notRetired(reason: "bad_signature")
        }
        if let txnId = envelope.txnId, pairing.phaseOf(txnId) != nil { return .notRetired(reason: "own_transaction") }
        let isSamePairing = step.transcriptHash.map { $0 == binding.bindingId } ?? (envelope.txnId == binding.txnId)
        if isSamePairing { return .notRetired(reason: "same_binding") }
        guard let createdMs = Int64(envelope.createdMs), createdMs > binding.installedAtMs else { return .notRetired(reason: "stale") }
        pairing.tombstoneStore.recordUnpaired(bindingId: binding.bindingId, eventId: envelope.eventId, atMs: nowMs)
        pairing.bindingStore.deactivate(localChatId)
        pairing.authorizationStore.consumeByTxn(binding.txnId)
        return .retired(bindingId: binding.bindingId)
    }

    /// Whether `eventId` is the message that retired one of `localChatId`'s earlier bindings — so the line reads the
    /// same on every re-render.
    public static func wasRetiredBy(_ pairing: V2Processor.PairingProcessor, localChatId: String, eventId: String) -> Bool {
        return pairing.bindingStore.historical(localChatId).contains { pairing.tombstoneStore.unpairedFor($0.bindingId)?.eventId == eventId }
    }
}
