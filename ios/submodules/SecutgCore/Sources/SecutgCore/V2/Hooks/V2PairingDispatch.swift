import Foundation

/// The real send/receive surface for v2's P2 pairing family — the pairing analogue of `V2Dispatch`
/// (E2 business ciphertext), built for PLAN.md UI-01: a brand-new chat's pair/accept UI runs through
/// this file instead of v1's `RekeyProcessor`, while a chat v1 already has ANY pairing record for
/// never reaches it — that routing decision belongs to the caller (`SecutgAccountRuntime`), not here.
///
/// Inert exactly like `V2Dispatch` until a `V2Runtime` is actually bootstrapped for a real account —
/// `V2Bootstrap.initV2Worker` is still not called from any real app-startup path in this pass either,
/// so every lookup below fails closed to `.notOnV2`/`.notV2` for every account that exists today.
///
/// Scope (PLAN.md UI-01, matching the Web reference's own slice): the two-party happy path
/// (INVITE/ACCEPT/SELECT/CONFIRM/READY) plus CONFLICT. CANCEL/MERGE/BUSY/ROSTER_COMMIT are
/// recognized — never misread as a v1 `R1`/`P1`/`U1`/`N1`, never crash — but not acted on this
/// round. SECUTG-HOOK (fix A9): UNPAIR is no longer in that "not acted on" set — the explicit
/// "user tapped unpair" action has its own entry point below (`unpair(accountKey:chatId:)`,
/// mirroring `startPairing`/`acceptInvite`), and an incoming UNPAIR wire is now handled the same
/// way ACCEPT/SELECT/CONFIRM/READY already are, so a chat this device unpaired from — or whose
/// peer unpaired from it — actually stops trusting the old v2 binding on both sides, instead of
/// silently doing nothing the way it used to.
public enum V2PairingSendOutcome: Equatable {
    case notOnV2
    case sent(wire: String)
    case failed(reason: String)
}

/// What handling one incoming P2 wire produced, for the caller (`transformIncoming`) to turn into a
/// `SecutgTextMetaAttribute`.
public enum V2PairingReceiveOutcome: Equatable {
    case notV2
    /// A fresh INVITE arrived and nothing is recorded for it yet — the v2 analogue of v1's
    /// `hasIncomingInvite`. The caller is expected to remember `inviteWire` (keyed by chatId) so a
    /// later "accept" tap can hand it back to `acceptInvite`; this dispatcher itself records nothing
    /// (matching `V2Processor.handleInvite`'s own "no state is recorded here" contract).
    case invited(fromUser: String, targetUser: String, inviteWire: String)
    /// PLAN.md 3.43: an INVITE for a chat that already has a binding, signed by an identity that is **not** in that
    /// binding's device roster — the peer reinstalled, or somebody is wearing their name; this side cannot tell.
    /// Cached exactly like `invited` (the same 〔同意配对〕 accepts it) but rendered as the key-changed block with the
    /// two device codes — no safety code: the peer cannot compute one for the new identity before this side accepts
    /// (they have no key of ours until then), so the person, not a number, is what the row asks the user to verify.
    /// Nothing is adopted: the binding stays as it was until the user accepts.
    case invitedKeyChanged(fromUser: String, targetUser: String, inviteWire: String, oldDeviceCode: String, newDeviceCode: String)
    /// This processor's own `handle*` advanced the exchange; `wire` is what to send onward next, nil
    /// when nothing needs to go out (the responder's own completion, on READY).
    case progressed(wire: String?)
    /// v1.4's own terminal, not-a-failure outcome (TEST_MATRIX P-17): two valid selections collided.
    case conflict
    /// A CANCEL/MERGE/BUSY/ROSTER_COMMIT wire, or a business-logic refusal from one of the
    /// happy-path `handle*` calls — recognized (never falls through to v1's own P1/R1/U1/N1 parsing,
    /// never crashes) but not acted on this round. UNPAIR is no longer here (fix A9) — see
    /// `handleIncoming`'s own `"UNPAIR"` case.
    case ignored(reason: String)
    case failed(reason: String)
    /// PLAN.md 3.39: an `add_device` commit that concerns a device joining (still received from other clients), or
    /// PLAN.md 3.39.13's clone being set aside — its own line, never the generic one. See `V2JoinNotice`.
    case join(V2JoinNotice)
}

/// PLAN.md 3.39's device lines, decided at dispatch time so a history re-render reads the same.
public enum V2JoinNotice: Equatable {
    /// 3.39.4 step 5: THIS device was the one an add_device commit added (`SecutgV2JoinDone {code}`, code = the safety
    /// code). Only a 3.39.12 client still sends such a commit.
    case done(safetyCode: String?)
    /// 3.39.7: another device of THIS account was added by an add_device commit (`SecutgV2JoinSiblingAdded {code}`,
    /// code = its device code, PLAN.md 3.25.2's `XXX-XXX` from the new identity's encapsulation key).
    case siblingAdded(deviceCode: String)
    /// 3.39.5: the PEER added a device (`SecutgV2JoinPeerAdded {name} {code}`).
    case peerAdded(fromUser: String, deviceCode: String)
    /// PLAN.md 3.39.13 「必改项」 3: another device of this account paired this chat again, so this device's CLONE
    /// binding was set aside (`SecutgV2CloneSiblingRepaired` — scan a new code).
    case cloneSiblingRepaired
}

public enum V2PairingDispatch {
    private static let wirePrefix = V2Messages.prefix + ":"

    /// `.ignored(reason:)` of a valid ACCEPT another device of this account sent for an INVITE this device was offered
    /// and is not itself answering (2026-10-01 真机): the cached invite is closed here — `V2PairingLine.siblingAccepted`.
    public static let siblingAcceptedReason = "sibling_accepted"
    /// `.ignored(reason:)` of an INVITE whose transaction this device already closed (a sibling accepted it, the inviter
    /// cancelled it, or this device joined that pairing by V2Q): never cached or offered again — a handshake line.
    public static let inviteClosedReason = "invite_closed"

    /// Initiator side: builds a fresh INVITE for `chatId`/`targetUser` and hands back the wire for the
    /// caller to send as a plain chat message, exactly the way v1's own `P1` already travels.
    public static func startPairing(accountKey: String, chatId: String, targetUser: String) -> V2PairingSendOutcome {
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return .notOnV2 }
        guard let started = runtime.pairing.startPairing(chatId, targetUser) else { return .failed(reason: "build_failed") }
        runtime.noteSent(started.wire) // PLAN.md 3.39.13: before any local copy of it can render
        // SECUTG-HOOK (fix E1): persist once this real protocol action finishes — the pending INVITE
        // this just created must survive a restart, not just live in memory until the ACCEPT arrives.
        runtime.persisted.persist()
        return .sent(wire: started.wire)
    }

    /// Responder side: the explicit "user tapped accept" action on a cached incoming INVITE wire.
    /// `busy`/`expired`/`cancelled`/`rejected` all fail closed here — none of those has a wire worth
    /// sending, and the CANCEL/BUSY messaging those states would otherwise produce is out of scope
    /// this round (PLAN.md UI-01).
    public static func acceptInvite(accountKey: String, chatId: String, inviteWire: String) -> V2PairingSendOutcome {
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return .notOnV2 }
        // SECUTG-HOOK (fix C0, 2026-09-27): filed under THIS device's own chat id, not the invite's.
        let outcome = runtime.pairing.acceptInvite(inviteWire, localChatId: chatId)
        guard outcome.kind == "accept", let wire = outcome.wire else { return .failed(reason: outcome.kind) }
        runtime.noteSent(wire) // PLAN.md 3.39.13
        // SECUTG-HOOK (fix, mirrors E1): the cached incoming invite this accept just consumed is done —
        // drop it so a later relaunch does not offer to re-accept an already-accepted invite.
        runtime.persisted.incomingInviteStore.remove(chatId)
        // SECUTG-HOOK (fix E1): see `startPairing`'s own note above.
        runtime.persisted.persist()
        return .sent(wire: wire)
    }

    /// SECUTG-HOOK (fix A9): the explicit "user tapped unpair" action, targeting `chatId`'s current
    /// v2 binding — mirrors `startPairing`/`acceptInvite`. Only ever called for a chat v1 has NO
    /// pairing record for (`SecutgAccountRuntime.unpair(chatPeerId:)` gates that); a chat v1 already
    /// has a record for unpairs through v1's own unchanged `RekeyProcessor.unpair` path instead.
    public static func unpair(accountKey: String, chatId: String) -> V2PairingSendOutcome {
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return .notOnV2 }
        guard let wire = runtime.pairing.unpair(chatId) else { return .failed(reason: "no_binding") }
        runtime.noteSent(wire) // PLAN.md 3.39.13 (an empty wire is no envelope and records nothing)
        // SECUTG-HOOK (fix E1): the binding this just deactivated must not reappear as "current" on
        // the next reload.
        runtime.persisted.persist()
        // PLAN.md 3.39.7: a binding whose roster does not name this device is torn down locally with nothing to send
        // (the peer would refuse it) — `unpair` returns "" for it; the local effect above already happened.
        guard !wire.isEmpty else { return .failed(reason: "not_a_member") }
        return .sent(wire: wire)
    }

    /// SECUTG-HOOK (fix): the explicit "user tapped 换新密钥 (change key)" action for an installed
    /// v2 binding. Deliberately `V2Roster.rekey`, never the old R1 `rotate` shape: `rotate` is
    /// symmetric-encrypted under the CURRENT master, so a receiver whose local keyring ever drifted
    /// from the sender's cannot open it (`no_old_key`) — a real cryptographic fact, not a bug, but
    /// the wrong shape for "user explicitly asked to re-establish" (the user's own call: a deliberate
    /// tap means start over, not prove continuity). `rekey` reseals a fresh random master to every
    /// device already on file in the binding's `deviceKeys` (their long-term encapsulation public
    /// keys, exchanged once at pairing time and never touched since) — no old key needed, no new
    /// five-step handshake, same bindingId, epoch+1. This mechanism already existed at the processor
    /// level (`V2Runtime.roster`, built for v1.4 section 33's multi-device roster maintenance) and was
    /// already fully wired to a live `V2Runtime` instance; it was simply never exposed here.
    public static func rekey(accountKey: String, chatId: String) -> V2PairingSendOutcome {
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return .notOnV2 }
        guard let wire = runtime.roster.rekey(chatId) else { return .failed(reason: "no_binding") }
        runtime.noteSent(wire) // PLAN.md 3.39.13: the clone tells this echo from its own rekeys by the event id
        runtime.persisted.persist()
        return .sent(wire: wire)
    }

    /// SECUTG-HOOK (fix): the explicit "user tapped unpair/reset" action for a chat stuck in an
    /// in-flight transaction that never reached a binding (INVITED/SELECTING/CONFIRMING) — `unpair`
    /// above only knows how to tear down an installed binding and no-ops on anything earlier, so a
    /// chat that stalled mid-exchange (the v2PairingWires relay bug meant many did, before that fix)
    /// had no way back: `startPairing`'s own guard refuses a fresh INVITE while
    /// `currentTransactionForChat` is still non-nil, and nothing ever cleared it. `cancelPairing` at
    /// the processor level already existed and is already tested; it was simply never exposed here.
    public static func cancelPairing(accountKey: String, chatId: String, reason: String) -> V2PairingSendOutcome {
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else { return .notOnV2 }
        guard let txnId = runtime.pairing.currentTransactionForChat(chatId) else { return .failed(reason: "no_transaction") }
        guard let wire = runtime.pairing.cancelPairing(txnId: txnId, reason: reason) else { return .failed(reason: "cancel_failed") }
        runtime.noteSent(wire) // PLAN.md 3.39.13
        runtime.persisted.persist()
        return .sent(wire: wire)
    }

    /// PLAN.md 3.39.13: P2 wires the runtime built outside the entry points above (the 「一键恢复」 sweep's CANCEL /
    /// UNPAIR notices) — recorded as this device's own before they are sent, then persisted. Non-P2 text is ignored.
    public static func noteSent(accountKey: String, wires: [String]) {
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey), !wires.isEmpty else { return }
        for wire in wires { runtime.noteSent(wire) }
        runtime.persisted.persist()
    }

    /// PLAN.md 3.39.13 「必改项」 1: whether an identity is one this device acts (or acted) under in `chatId` — its own
    /// for the current binding, or the `ownIdentity` of an earlier one — so a clone set aside by 「必改项」 3 still knows
    /// its sibling's messages (the line re-renders the same) once it no longer has a current binding. Mirrors Web A
    /// `actsAsOwnDevice`.
    static func actsAsOwnDevice(_ runtime: V2Runtime, chatId: String, deviceId: String) -> Bool {
        let bindingStore = runtime.pairing.bindingStore
        if deviceId == V2OwnIdentity.ownDeviceId(for: bindingStore.current(chatId), fallback: runtime.identity) { return true }
        return bindingStore.historical(chatId).contains { $0.ownIdentity?.deviceId == deviceId }
    }

    /// SECUTG-HOOK (fix, 2026-09-27): whether a cached INVITE is genuinely newer than the binding this
    /// chat already has — the peer reinstalled or reset on their side and is asking to pair afresh, so
    /// the accept entry must stay reachable on a bound chat (accepting installs the new binding and
    /// `BindingStore.install` moves the old one to historical). Envelope parse only, no signature check:
    /// every cached invite was already verified on receipt by `handleInvite`. Unparseable → false.
    public static func isInviteNewer(thanBindingInstalledAtMs installedAtMs: Int64, inviteWire: String) -> Bool {
        guard let parsed = V2Messages.parseInvite(inviteWire), let createdMs = Int64(parsed.envelope.createdMs) else { return false }
        return createdMs > installedAtMs
    }

    /// Render-side dispatcher for an incoming (or local-echo) P2 wire.
    ///
    /// `isOutgoing` true is the local copy of a P2 message THIS device just sent, and is never handed
    /// to a processor `handle*` call: `V2Processor.handleInvite`'s own same-chat scan cannot tell an
    /// echo of this device's own INVITE apart from a genuine crossed invite from someone else (both
    /// look like "another open initiator txn already exists for this chatId") and would build a
    /// spurious MERGE wire from it — the exact edge case the Web reference's integration layer hit and
    /// fixed the same way: skip entirely here, before any processor call, rather than inside the
    /// (already fully tested) processor core.
    /// SECUTG-HOOK (feature, 2026-09-27, "一键恢复"): the receive-side half of the reset — what this
    /// device does to ITS OWN state for `chatId` when the peer's authenticated UNPAIR or
    /// CANCEL(user_reset) arrives, so that one side pressing the button leaves both sides at the same
    /// clean slate. The same sweep `SecutgAccountRuntime.resetChat` makes locally, minus the sending:
    /// every CANCEL wire `cancelAllForChat` builds here is discarded, never relayed — the peer already
    /// cleared everything on their side, and echoing would only ping-pong. v1's half needs no mirror:
    /// v1's U1 notice already makes the peer's `RekeyProcessor.handleU1` run its own full wipe.
    private static func resetLocallyForPeer(_ runtime: V2Runtime, chatId: String) {
        _ = runtime.pairing.cancelAllForChat(chatId)
        runtime.persisted.incomingInviteStore.remove(chatId)
    }

    /// SECUTG-HOOK (fix, 2026-10-01 真机, PLAN.md 3.39.6 / 3.39.13): an ACCEPT another device of THIS account sent — Telegram
    /// shows it as outgoing, this device did not build it — for an INVITE this device is not answering itself. The
    /// account has answered: the cached invite for the chat (same transaction, or the invite the ACCEPT hashes) is
    /// dropped, and the transaction is closed here (a cancelled tombstone), so neither a stale 〔同意配对〕, a restart, the
    /// INVITE re-rendering or arriving late, nor the rest of that handshake can offer it again — accepting it would only
    /// start a pairing competing with the sibling's. Authenticated as far as this device can: the ACCEPT's actor is this
    /// account and its signature verifies against the identity it carries (the sibling's own, or the shared clone one).
    /// A transaction this device is a party to (`phaseOf`) is left to the race (P-12). Returns whether it closed one —
    /// i.e. whether the line should say so: not when this device's own binding post-dates the ACCEPT (history).
    @discardableResult
    static func closeInviteTakenBySibling(_ runtime: V2Runtime, chatId: String, acceptWire: String) -> Bool {
        let pairing = runtime.pairing
        guard let accept = V2Messages.parseAccept(acceptWire), let txnId = accept.envelope.txnId else { return false }
        guard accept.envelope.actorUser == runtime.identity.userId,
              V2Messages.verifyTyped(accept.envelope, identityPkB64: accept.body.identityPk) else { return false }
        guard pairing.phaseOf(txnId) == nil else { return false }
        if let cached = runtime.persisted.incomingInviteStore.get(chatId), let invite = V2Messages.parseInvite(cached),
           invite.envelope.txnId == txnId || Base64Url.encode(V2Messages.hashWire(cached)) == accept.body.inviteHash {
            runtime.persisted.incomingInviteStore.remove(chatId)
        }
        if pairing.tombstoneStore.cancelledFor(txnId) == nil {
            pairing.tombstoneStore.recordCancelled(txnId: txnId, eventId: accept.envelope.eventId, atMs: runtime.now())
        }
        if let binding = pairing.bindingStore.current(chatId), let createdMs = Int64(accept.envelope.createdMs),
           binding.installedAtMs >= createdMs { return false }
        return true
    }

    /// SECUTG-HOOK (fix, 2026-10-01 真机): an INVITE this device must never offer (again) — its transaction is closed here
    /// (a sibling accepted it, the inviter cancelled it, or this device joined that pairing by V2Q), or the chat's
    /// current binding came from it. Envelope parse only (every cached invite was verified on receipt).
    public static func isInviteClosed(_ runtime: V2Runtime, chatId: String, inviteWire: String) -> Bool {
        guard let txnId = V2Messages.parseInvite(inviteWire)?.envelope.txnId else { return false }
        if runtime.pairing.tombstoneStore.cancelledFor(txnId) != nil { return true }
        return runtime.pairing.bindingStore.current(chatId)?.txnId == txnId
    }

    /// SECUTG-HOOK (fix, 2026-10-01 真机): what a successful V2Q import does to the chat's other pairing state — this device
    /// IS the showing device in the chat from now on, so nothing it was offered or was running there is still its to
    /// finish: the cached invite is dropped and closed (never offered again), every transaction it held for the chat —
    /// a losing responder's, its own INVITE, a CONFLICT — is dropped locally (the CANCEL wires are discarded: the peer
    /// already settled on the sibling's pairing).
    static func settleChatAfterClone(_ runtime: V2Runtime, chatId: String) {
        let pairing = runtime.pairing
        if let cached = runtime.persisted.incomingInviteStore.get(chatId) {
            if let invite = V2Messages.parseInvite(cached), let txnId = invite.envelope.txnId, pairing.tombstoneStore.cancelledFor(txnId) == nil {
                pairing.tombstoneStore.recordCancelled(txnId: txnId, eventId: invite.envelope.eventId, atMs: runtime.now())
            }
            runtime.persisted.incomingInviteStore.remove(chatId)
        }
        _ = pairing.cancelAllForChat(chatId)
        _ = pairing.dropConflictsForChat(chatId)
    }

    /// PLAN.md 3.43 rule 1: whether an INVITE's signing identity is one of the devices the chat's current binding
    /// already trusts — this device's own, the peer's, or any device either side added by V2Q. Compared as the
    /// base64url strings both sides already carry (`V2Binding.DeviceKeys.identityPk` / the INVITE's `identity_pk`).
    public static func inviteIdentityIsInRoster(_ binding: V2Binding, inviteIdentityPk: String) -> Bool {
        return binding.deviceKeys.values.contains { $0.identityPk == inviteIdentityPk }
    }

    /// PLAN.md 3.43 rules 1 and 3: what the key-changed line quotes — the two device codes, and deliberately no safety
    /// code (see `invitedKeyChanged`).
    public struct KeyChangedInvite: Equatable {
        /// PLAN.md 3.25.2 device codes (`XXX-XXX`) of the peer's devices in the current binding, oldest roster first.
        public let oldDeviceCode: String
        /// The device code of the identity that signed the INVITE.
        public let newDeviceCode: String

        public init(oldDeviceCode: String, newDeviceCode: String) {
            self.oldDeviceCode = oldDeviceCode
            self.newDeviceCode = newDeviceCode
        }
    }

    static func keyChangedInvite(_ runtime: V2Runtime, binding: V2Binding, invite: V2Messages.Parsed<V2Messages.InviteBody>) -> KeyChangedInvite {
        let ownDeviceId = V2OwnIdentity.ownDeviceId(for: binding, fallback: runtime.identity)
        let inviteIdentityPk = Base64Url.decode(invite.body.identityPk) ?? []
        let peerDevices = binding.deviceRoster.filter { $0 != ownDeviceId }
        let oldDeviceCode = peerDevices.map { deviceId -> String in
            V2JoinCoordinator.deviceCode(encapsulationPkB64: binding.deviceKeys[deviceId]?.encapsulationPk ?? "", fallback: deviceId)
        }.joined(separator: " / ")
        let newDeviceCode = V2JoinCoordinator.deviceCode(encapsulationPkB64: invite.body.encapsulationPk,
                                                         fallback: Base64Url.encode(V2Suite.sha256(inviteIdentityPk)))
        return KeyChangedInvite(oldDeviceCode: oldDeviceCode.isEmpty ? "-" : oldDeviceCode, newDeviceCode: newDeviceCode)
    }

    public static func handleIncoming(accountKey: String, chatId: String, wireText: String, isOutgoing: Bool) -> V2PairingReceiveOutcome {
        guard wireText.hasPrefix(wirePrefix) else { return .notV2 }
        guard let envelope = V2Envelope.parse(prefix: V2Messages.prefix, text: wireText) else { return .failed(reason: "malformed") }
        guard let runtime = V2RuntimeRegistry.shared.runtime(for: accountKey) else {
            return isOutgoing ? .ignored(reason: "own_echo:\(envelope.type.lowercased())") : .failed(reason: "v2_not_ready")
        }
        let pairing = runtime.pairing

        // PLAN.md 3.39.6 (the "same-account sibling" rule), as 3.39.13 「必改项」 1 decides it: an OUTGOING message is
        // this device's own echo only when this device BUILT it (its event id is in the sent-event log). A clone signs
        // with exactly this device's identity, so `actor_device` alone can no longer tell. Every other outgoing message
        // was sent by another device of this account and is processed like ordinary inbound traffic — with the
        // carve-outs in `handleCloneSiblingWire` / `siblingOutcome` below. This device's own P2 from before 3.39.13
        // (never recorded) is classified as its clone's; every clone handler tolerates that (Web A does the same).
        let ownDevice = V2OwnIdentity.ownDeviceId(for: pairing.bindingStore.current(chatId), fallback: runtime.identity)
        let isOwnEcho = isOutgoing && runtime.persisted.sentEventStore.contains(envelope.eventId)
        // PLAN.md 3.39.13: not built here, yet signed by an identity this device acts under in the chat — its V2Q clone.
        let isCloneSibling = isOutgoing && !isOwnEcho && actsAsOwnDevice(runtime, chatId: chatId, deviceId: envelope.actorDevice)
        // PLAN.md 3.39.6, kept for compatibility: a device of this account with an identity of its own.
        let isSibling = isOutgoing && !isOwnEcho && !isCloneSibling
        if isOwnEcho {
            // Our own echo — see the doc above. Never processed; a ROSTER_COMMIT only picks its line.
            if envelope.type == "ROSTER_COMMIT" { return ownRosterCommitEchoLine(runtime, chatId: chatId, wireText: wireText) }
            return .ignored(reason: "own_echo:\(envelope.type.lowercased())")
        }
        if isCloneSibling { return handleCloneSiblingWire(runtime, chatId: chatId, ownDevice: ownDevice, envelope: envelope, wireText: wireText) }
        if isSibling, let handled = siblingOutcome(runtime, chatId: chatId, type: envelope.type, wireText: wireText) { return handled }

        let outcome: V2PairingReceiveOutcome
        switch envelope.type {
        case "INVITE":
            // SECUTG-HOOK (fix C0, 2026-09-27): our own chat id, so a crossed invite is actually matched
            // against our own open INVITE for this chat (and a losing side's ACCEPT files correctly).
            let result = pairing.handleInvite(wireText, localChatId: chatId)
            if result.ok, result.wire == nil, isInviteClosed(runtime, chatId: chatId, inviteWire: wireText) {
                // SECUTG-HOOK (fix, 2026-10-01 真机): a sibling already accepted this invite (or the inviter cancelled it,
                // or the chat's binding came from it) — re-rendering it, or receiving it after the sibling's ACCEPT,
                // must not put 〔同意配对〕 back. Nothing cached, no invite dialog.
                outcome = .ignored(reason: inviteClosedReason)
            } else if !result.ok {
                outcome = .failed(reason: result.reason ?? "invite_failed")
            } else if let wire = result.wire {
                // A race this device is already an initiator in produces a busy/merge wire to send
                // back, structurally identical to any other "progressed" outcome from this device's
                // own side.
                // SECUTG-HOOK (fix, 2026-09-27): or, for a crossed invite this device LOST
                // (kind "merged_accept"), the ACCEPT it already built for the peer's invite as the
                // responder. That invite is consumed, so it is deliberately NOT cached below — there is
                // nothing left for the user to tap. (No other per-chat "I initiated" memory exists on
                // this side to clear: the processor already dropped our own txn.)
                outcome = .progressed(wire: wire)
            } else if let targetUser = result.targetUser, let fromUser = result.fromUser {
                // SECUTG-HOOK (fix, mirrors E1): `V2Processor.handleInvite` itself records no state
                // ("no state is recorded here"), so this cache is the ONLY record of this invite
                // anywhere — it must survive a relaunch or the accept button has nothing to act on
                // (see `V2IncomingInviteStore`'s own doc for the "both sides end up inviting each
                // other" symptom this closes).
                runtime.persisted.incomingInviteStore.set(chatId, wire: wireText)
                // PLAN.md 3.43 rule 1: on a chat that already has a binding, an INVITE from an identity the binding
                // does not know is said out loud rather than dressed as an ordinary re-pair. Same cache, same accept
                // road, nothing adopted (rule 2). An identity already in the roster — the same device inviting again,
                // a crossed invite — stays the ordinary line.
                if let binding = pairing.bindingStore.current(chatId), let parsed = V2Messages.parseInvite(wireText),
                   !inviteIdentityIsInRoster(binding, inviteIdentityPk: parsed.body.identityPk) {
                    let changed = keyChangedInvite(runtime, binding: binding, invite: parsed)
                    outcome = .invitedKeyChanged(fromUser: fromUser, targetUser: targetUser, inviteWire: wireText,
                                                 oldDeviceCode: changed.oldDeviceCode, newDeviceCode: changed.newDeviceCode)
                } else {
                    outcome = .invited(fromUser: fromUser, targetUser: targetUser, inviteWire: wireText)
                }
            } else {
                outcome = .failed(reason: "malformed")
            }
        case "ACCEPT":
            let result = pairing.handleAccept(wireText)
            outcome = result.ok ? .progressed(wire: result.wire) : .failed(reason: result.reason ?? "accept_failed")
        case "SELECT":
            let result = pairing.handleSelect(wireText)
            if !result.ok, result.reason == "conflict" {
                outcome = .conflict
            } else {
                outcome = result.ok ? .progressed(wire: result.wire) : .failed(reason: result.reason ?? "select_failed")
            }
        case "CONFIRM":
            let result = pairing.handleConfirm(wireText)
            outcome = result.ok ? .progressed(wire: result.wire) : .failed(reason: result.reason ?? "confirm_failed")
        case "READY":
            let result = pairing.handleReady(wireText)
            outcome = result.ok ? .progressed(wire: nil) : .failed(reason: result.reason ?? "ready_failed")
        case "UNPAIR":
            // SECUTG-HOOK (fix A9): the peer's own explicit unpair notice — deactivates this
            // device's current binding too (`V2Processor.handleUnpair`), the same way v1's `U1`
            // already makes both sides stop trusting a key one side gave up on. Nothing to send
            // onward: the peer already knows, since they are the one who sent this.
            // SECUTG-HOOK (fix, 2026-09-29 真机): our own chat id, so an UNPAIR naming another binding of this chat can
            // set aside a binding the rest of the chat has moved on from (`handleUnpair`'s superseded rule).
            let result = pairing.handleUnpair(wireText, localChatId: chatId)
            // SECUTG-HOOK (feature, 2026-09-27, "一键恢复" — one side resets, BOTH sides return to the
            // initial state): the peer unpairing is also the moment to drop anything ELSE this side
            // still holds for the chat — a stuck transaction in either role, a cached invite — so the
            // peer's reset does not leave this side half-reset. Authenticated: `handleUnpair` verified
            // the signature against the txn's own peer identity first. The CANCEL wires this local
            // sweep builds are deliberately discarded, never sent back (nothing left to cancel there).
            if result.ok { resetLocallyForPeer(runtime, chatId: chatId) }
            // PLAN.md 3.39.6: a sibling's UNPAIR is this ACCOUNT unpairing — worded like our own ("已解除配对"),
            // never like the peer's; `ignoredLine` maps `own_echo:unpair` to exactly that line.
            if result.ok, isSibling {
                outcome = .ignored(reason: "own_echo:unpair")
            } else {
                outcome = result.ok ? .progressed(wire: nil) : .failed(reason: result.reason ?? "unpair_failed")
            }
        case "CANCEL":
            // SECUTG-HOOK (fix): the peer's own explicit "abandon this in-flight exchange" notice —
            // was previously just ignored here (grouped with MERGE/BUSY/ROSTER_COMMIT, none of which
            // are acted on), so a device that cancelled its own stuck transaction never told the
            // other side, leaving THEIR copy of the same transaction stuck forever too.
            // `V2Processor.handleCancel` already existed and is already tested; it was simply never
            // reached from here.
            var result = pairing.handleCancel(wireText)
            // SECUTG-HOOK (fix, 2026-09-27): no txn for it here, but maybe the INVITE it cancels is only
            // cached (the peer cancelled/reset before this side ever tapped 同意). Authenticated against
            // that cached invite; on success the dead invite stops being offered and can no longer be
            // accepted. Otherwise the original refusal stands.
            if !result.ok, let cachedInvite = runtime.persisted.incomingInviteStore.get(chatId),
               pairing.handleCancelOfCachedInvite(cancelWire: wireText, cachedInviteWire: cachedInvite).ok {
                runtime.persisted.incomingInviteStore.remove(chatId)
                result = V2Processor.SimpleOutcome.ok()
            }
            // SECUTG-HOOK (feature, 2026-09-27, "一键恢复"): a CANCEL whose reason is `user_reset` is the
            // peer's reset button, not an ordinary "abandon this one exchange" — mirror the full local
            // sweep here too (see UNPAIR above), and let `handleP2` render it as the peer resetting.
            if result.ok, V2Messages.parseCancel(wireText)?.body.reason == "user_reset" {
                resetLocallyForPeer(runtime, chatId: chatId)
            }
            outcome = result.ok ? .progressed(wire: nil) : .failed(reason: result.reason ?? "cancel_failed")
        case "ROSTER_COMMIT":
            // SECUTG-HOOK (fix): the peer's own "换新密钥"/rekey commit — was lumped into the ignored
            // bucket with MERGE/BUSY, same shape of bug as CANCEL/UNPAIR above. `V2Roster.handleRosterCommit`
            // already existed and is already tested; it was simply never reached from here.
            // PLAN.md 3.39: an `add_device` commit — from the peer, from a sibling device of this account (3.39.6),
            // or the pre-signed one that completes THIS device's own join — gets its own line.
            outcome = handleRosterCommitWire(runtime, chatId: chatId, wireText: wireText, isSibling: isSibling)
        case "MERGE", "BUSY":
            outcome = .ignored(reason: envelope.type.lowercased())
        default:
            outcome = .ignored(reason: "unknown")
        }
        // PLAN.md 3.39.13: a wire this step built (SELECT / CONFIRM / READY / MERGE / BUSY / a crossed ACCEPT) is this
        // device's own from the moment it exists — recorded before the caller sends it and renders its local copy.
        if case let .progressed(onward?) = outcome { runtime.noteSent(onward) }
        // SECUTG-HOOK (fix E1, updated by the incoming-invite fix above): persist once per real P2
        // message this device just finished processing, matching every other real dispatch entry
        // point (`V2Dispatch`, `startPairing`/`acceptInvite`/`unpair` above). An `.invited` outcome
        // now DOES touch a persisted store (`incomingInviteStore`, set above); `.ignored`/`.failed`
        // still touch none (CANCEL/MERGE/BUSY/ROSTER_COMMIT are still not acted on) — persisting there
        // too is simply a harmless no-op save of whatever was already durable.
        runtime.persisted.persist()
        return outcome
    }

    // MARK: PLAN.md 3.39.6 — messages another device of this account sent

    /// The carve-outs for a message another device of this account sent under an identity of its own (PLAN.md
    /// 3.39.6). INVITE-type traffic (v1.4 section 6: the other device is initiating — this one shows the account's own
    /// line and changes no state; SELECT/CONFIRM/READY/MERGE/BUSY are addressed to the peer and verified against ITS
    /// key, so they are not ours to act on). A sibling's ACCEPT is the one exception with a real job: P-12's
    /// `observeAccept`, which is what later lets this device tell "my other device won the race" from a forged
    /// `accept_hash`. nil for the types that go through the ordinary switch (CANCEL, UNPAIR, ROSTER_COMMIT).
    private static func siblingOutcome(_ runtime: V2Runtime, chatId: String, type: String, wireText: String) -> V2PairingReceiveOutcome? {
        switch type {
        case "ACCEPT":
            _ = runtime.pairing.observeAccept(wireText)
            let closed = closeInviteTakenBySibling(runtime, chatId: chatId, acceptWire: wireText)
            runtime.persisted.persist()
            return closed ? .ignored(reason: siblingAcceptedReason) : .ignored(reason: "sibling:accept")
        case "CANCEL", "UNPAIR", "ROSTER_COMMIT":
            return nil
        default:
            return .ignored(reason: "sibling:\(type.lowercased())")
        }
    }

    /// A ROSTER_COMMIT that failed only because its binding is gone here (unpaired, replaced) — this account's
    /// history, worded as its own like any own echo.
    private static let historicalCommitReasons: Set<String> = ["unpaired", "unknown_binding", "wrong_binding"]

    /// PLAN.md 3.39.13: an outgoing P2 signed by this device's own identity for the chat that this device did NOT
    /// build — its clone's. Whatever the account did, this device follows, worded as the account's own action
    /// (mirrors Web A `handleCloneSiblingWire`):
    ///  - ROSTER_COMMIT (「必改项」 1): processed normally — the package for the shared device opens with the shared
    ///    encapsulation key, so the clone's rekey is adopted here too;
    ///  - UNPAIR (「必改项」 1): applied here too (binding-based fallback / the superseded rule);
    ///  - INVITE / ACCEPT / CONFIRM / READY (「必改项」 3): the clone pairing this chat AGAIN retires this device's
    ///    binding (`V2CloneSibling`), on this render and on every re-render of the same message; otherwise, as 3.39.6,
    ///    recognised without a state change (an ACCEPT still feeds P-12's `observeAccept`);
    ///  - CANCEL: the line only (the transaction is the clone's, never this device's);
    ///  - SELECT / MERGE / BUSY: recognised.
    private static func handleCloneSiblingWire(_ runtime: V2Runtime, chatId: String, ownDevice: String, envelope: V2Envelope, wireText: String) -> V2PairingReceiveOutcome {
        let pairing = runtime.pairing
        let type = envelope.type
        switch type {
        case "INVITE", "ACCEPT", "CONFIRM", "READY":
            let retired = V2CloneSibling.retireOnSiblingRepair(pairing, localChatId: chatId, ownDeviceId: ownDevice, wire: wireText, nowMs: runtime.now())
            // SECUTG-HOOK (fix, 2026-10-01 真机): the account accepted an invite on the clone — the same invite this
            // device was offered is closed here too, whether or not this device's binding had to be set aside for it.
            if type == "ACCEPT", closeInviteTakenBySibling(runtime, chatId: chatId, acceptWire: wireText) { runtime.persisted.persist() }
            if case .retired = retired {
                runtime.persisted.persist()
                return .join(.cloneSiblingRepaired)
            }
            if V2CloneSibling.wasRetiredBy(pairing, localChatId: chatId, eventId: envelope.eventId) { return .join(.cloneSiblingRepaired) }
            if type == "ACCEPT", pairing.observeAccept(wireText) { runtime.persisted.persist() }
            return .ignored(reason: "sibling:\(type.lowercased())")
        case "CANCEL":
            return .ignored(reason: "own_echo:cancel")
        case "UNPAIR":
            if pairing.handleUnpair(wireText, localChatId: chatId).ok {
                // The account unpaired: the same local sweep a peer's UNPAIR makes (any stuck exchange, any cached
                // invite), nothing sent.
                resetLocallyForPeer(runtime, chatId: chatId)
                runtime.persisted.persist()
            }
            return .ignored(reason: "own_echo:unpair")
        case "ROSTER_COMMIT":
            let result = runtime.roster.handleRosterCommit(wireText, localChatId: chatId)
            if result.ok, result.kind == .installed { runtime.persisted.persist() }
            if result.ok || historicalCommitReasons.contains(result.reason ?? "") {
                return ownRosterCommitEchoLine(runtime, chatId: chatId, wireText: wireText)
            }
            return .failed(reason: result.reason ?? "roster_commit_failed")
        default:
            return .ignored(reason: "sibling:\(type.lowercased())")
        }
    }

    private static func isRosterMember(_ runtime: V2Runtime, chatId: String, deviceId: String) -> Bool {
        return runtime.pairing.bindingStore.current(chatId)?.deviceKeys[deviceId] != nil
    }

    /// The line an `add_device` commit gets on every device that sees it (PLAN.md 3.39.3–3.39.5), by whose device joined.
    private static func joinNotice(_ runtime: V2Runtime, chatId: String, newDevice: V2Messages.NewDevice, actorUser: String, isSibling: Bool) -> V2PairingReceiveOutcome {
        let ownNow = V2OwnIdentity.ownDeviceId(for: runtime.pairing.bindingStore.current(chatId), fallback: runtime.identity)
        if newDevice.deviceId == ownNow { return .join(.done(safetyCode: runtime.pairing.safetyCodeForChat(chatId))) }
        let deviceCode = V2JoinCoordinator.deviceCode(encapsulationPkB64: newDevice.encapsulationPk, fallback: newDevice.deviceId)
        return isSibling ? .join(.siblingAdded(deviceCode: deviceCode)) : .join(.peerAdded(fromUser: actorUser, deviceCode: deviceCode))
    }

    /// A ROSTER_COMMIT from the peer, or from a sibling device of this account with its own identity (PLAN.md 3.39.6;
    /// a clone's goes through `handleCloneSiblingWire`).
    /// SECUTG-HOOK (fix C0, 2026-09-27): the binding lives under our own chat id, not the sender's.
    private static func handleRosterCommitWire(_ runtime: V2Runtime, chatId: String, wireText: String, isSibling: Bool) -> V2PairingReceiveOutcome {
        guard let parsed = V2Messages.parseRosterCommit(wireText) else { return .failed(reason: "malformed") }
        let result = runtime.roster.handleRosterCommit(wireText, localChatId: chatId)
        runtime.persisted.persist()
        guard result.ok else { return .failed(reason: result.reason ?? "roster_commit_failed") }
        // PLAN.md 3.39: an `add_device` line must read the same every time its message renders — freshly installed
        // now, or `already_applied` on a later history scroll — so both outcomes word it alike. `already_applied`
        // gets the line only if that device really is in the roster now: saying "added a device" about a commit
        // nobody adopted would be false.
        if parsed.body.reason == "add_device", let newDevice = parsed.body.newDevice {
            if result.kind == .installed || (result.kind == .alreadyApplied && isRosterMember(runtime, chatId: chatId, deviceId: newDevice.deviceId)) {
                return joinNotice(runtime, chatId: chatId, newDevice: newDevice, actorUser: parsed.envelope.actorUser, isSibling: isSibling)
            }
            return .ignored(reason: "roster_commit_stale")
        }
        return .progressed(wire: nil)
    }

    /// This device's OWN ROSTER_COMMIT coming back — never processed (the issuer already applied it), only worded:
    /// an `add_device` this device issued (a 3.39.12 code it showed, re-rendering) — the sibling-joined line while that
    /// device is in the roster; every other commit — the ordinary own-echo line (`v2rekey:own_echo`).
    private static func ownRosterCommitEchoLine(_ runtime: V2Runtime, chatId: String, wireText: String) -> V2PairingReceiveOutcome {
        let plainEcho = V2PairingReceiveOutcome.ignored(reason: "own_echo:roster_commit")
        guard let parsed = V2Messages.parseRosterCommit(wireText) else { return plainEcho }
        if parsed.body.reason == "add_device", let newDevice = parsed.body.newDevice {
            // Same rule as `handleRosterCommitWire`: the line only while that device is actually in the roster.
            guard isRosterMember(runtime, chatId: chatId, deviceId: newDevice.deviceId) else { return .ignored(reason: "roster_commit_stale") }
            return .join(.siblingAdded(deviceCode: V2JoinCoordinator.deviceCode(encapsulationPkB64: newDevice.encapsulationPk, fallback: newDevice.deviceId)))
        }
        return plainEcho
    }
}
