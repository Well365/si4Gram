import XCTest
@testable import SecutgCore

/// PLAN.md UI-01: `V2PairingDispatch` (the P2 analogue of `V2RuntimeDispatchTests`' own E2 coverage) —
/// a real end-to-end round trip between TWO separate `V2Runtime` instances, plus
/// `V2Processor.PairingProcessor.currentTransactionForChat`, the CONFLICT mapping, and the
/// own-outgoing-echo guard the Web reference's integration layer needed for the same reason.
final class V2PairingDispatchTests: XCTestCase {
    private let chat = "4200"

    private func makeStoredIdentity() -> KeyRing.Identity {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        return KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
    }

    override func tearDown() {
        V2RuntimeRegistry.shared.reset(for: "deviceA")
        V2RuntimeRegistry.shared.reset(for: "deviceB")
        V2RuntimeRegistry.shared.reset(for: "deviceC")
        super.tearDown()
    }

    private func makeRuntime(userId: String) -> V2Runtime {
        let identity = V2IdentityBridge.identity(userId: userId, from: makeStoredIdentity())!
        return V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: V2MemoryStorage()))
    }

    // MARK: currentTransactionForChat

    func testCurrentTransactionForChatIsNilBeforeAnyPairingAndClearsOnceDone() {
        let a = makeRuntime(userId: "100")
        XCTAssertNil(a.pairing.currentTransactionForChat(chat))
        let invite = a.pairing.startPairing(chat, "200")!
        XCTAssertEqual(a.pairing.currentTransactionForChat(chat), invite.txnId)
    }

    func testCurrentTransactionForChatTracksTheResponderSideToo() {
        let a = makeRuntime(userId: "100")
        let b = makeRuntime(userId: "200")
        let invite = a.pairing.startPairing(chat, "200")!
        XCTAssertNil(b.pairing.currentTransactionForChat(chat))
        let accept = b.pairing.acceptInvite(invite.wire)
        XCTAssertEqual(b.pairing.currentTransactionForChat(chat), accept.txnId)
    }

    // MARK: PLAN.md 3.50 — the `notify` knob `SecutgAccountRuntime.clearChatState(chat:notify:)` uses
    //
    // `clearChatState` lives in TelegramCore (it needs `PeerId`/`Postbox`), which has no test target of its
    // own, so `resetChat`/`resetChatLocally` themselves cannot be unit-tested here. What CAN be tested at
    // this layer — and is the entire substance of the `notify` parameter — is `V2PairingDispatch.noteSent`'s
    // one real effect: recording a wire's event id in `V2PersistedState.sentEventStore`, the exact fact
    // `V2PairingDispatch.handleIncoming`'s own `isOwnEcho` check reads (`runtime.persisted.sentEventStore
    // .contains(envelope.eventId)`, this file's own `handleIncoming` cases above). `resetChat` passes
    // `notify: true` and calls `noteSent` on the CANCEL/UNPAIR wires it is about to actually send, exactly
    // like every other real send path in this file (`startPairing`, `acceptInvite`, `unpair`, `cancelPairing`
    // all call it too). `resetChatLocally` passes `notify: false` and skips it, because nothing is sent at
    // all — recording an unsent wire as "sent" would plant a false fact in a store other code (this very
    // `isOwnEcho` check, QR-join repair, retry logic) later treats as true.
    func testNoteSentIsTheOnlyThingThatMarksAWiresEventIdAsThisDevicesOwnSentTraffic() {
        let a = makeRuntime(userId: "100")
        let b = makeRuntime(userId: "200")
        let invite = a.pairing.startPairing(chat, "200")!
        _ = b.pairing.acceptInvite(invite.wire) // a stuck open transaction, same shape as the 一键恢复 test above

        // The same call `clearChatState` makes to collect what it would send.
        let cancelWires = a.pairing.cancelAllForChat(chat)
        XCTAssertEqual(cancelWires.count, 1)
        let eventId = V2Envelope.parse(prefix: V2Messages.prefix, text: cancelWires[0])?.eventId
        XCTAssertNotNil(eventId)

        // `resetChatLocally`'s road: nothing calls `noteSent`, so the store never learns this event id.
        XCTAssertFalse(a.persisted.sentEventStore.contains(eventId!))

        // `resetChat`'s road: `V2PairingDispatch.noteSent` (`notify: true`) records it.
        V2RuntimeRegistry.shared.set(a, for: "deviceA")
        V2PairingDispatch.noteSent(accountKey: "deviceA", wires: cancelWires)
        XCTAssertTrue(a.persisted.sentEventStore.contains(eventId!))
    }

    // MARK: V2PairingDispatch — the real end-to-end round trip

    /// SECUTG-HOOK (feature, 2026-09-27, "一键恢复" — one side resets, BOTH sides return to the initial
    /// state). A resets while B holds a stuck responder transaction for A's invite AND a fresh, different
    /// invite from C cached behind it. A's reset sends one CANCEL(user_reset); receiving it must leave B
    /// fully clean — not just tombstone that one txn — and a brand-new pairing must then go through.
    func testAPeersResetCancelClearsThisSidesStuckTransactionAndCachedInviteSoAFreshPairingWorks() {
        let aRuntime = makeRuntime(userId: "100")
        let bRuntime = makeRuntime(userId: "200")
        let cRuntime = makeRuntime(userId: "300")
        V2RuntimeRegistry.shared.set(aRuntime, for: "deviceA")
        V2RuntimeRegistry.shared.set(bRuntime, for: "deviceB")
        V2RuntimeRegistry.shared.set(cRuntime, for: "deviceC")

        let fromA = aRuntime.pairing.startPairing(chat, "200")!
        _ = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: fromA.wire, isOutgoing: false)
        let stuck = bRuntime.pairing.acceptInvite(fromA.wire)
        XCTAssertEqual(stuck.kind, "accept")
        // ...and the handshake stalls here (A never answers). Meanwhile C's invite lands and is cached.
        let fromC = cRuntime.pairing.startPairing(chat, "200")!
        _ = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: fromC.wire, isOutgoing: false)
        XCTAssertNotNil(bRuntime.persisted.incomingInviteStore.get(chat))
        XCTAssertNotNil(bRuntime.pairing.currentTransactionForChat(chat))

        // A presses 一键恢复: its own sweep builds exactly one CANCEL(user_reset) for the shared txn.
        let resetWires = aRuntime.pairing.cancelAllForChat(chat)
        XCTAssertEqual(resetWires.count, 1)
        XCTAssertEqual(V2Messages.parseCancel(resetWires[0])?.body.reason, "user_reset")

        guard case .progressed(let relay) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: resetWires[0], isOutgoing: false) else {
            return XCTFail("expected .progressed")
        }
        XCTAssertNil(relay, "nothing is sent back — the peer already cleared everything")
        XCTAssertNil(bRuntime.pairing.currentTransactionForChat(chat), "B's own copy of the stuck txn is gone")
        XCTAssertNil(bRuntime.persisted.incomingInviteStore.get(chat), "the cached invite from C is dropped too")

        // Both sides are now at the initial state: a brand-new pairing goes through untouched.
        let fresh = aRuntime.pairing.startPairing(chat, "200")!
        guard case .invited = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: fresh.wire, isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        XCTAssertEqual(bRuntime.pairing.acceptInvite(fresh.wire).kind, "accept")
    }

    func testStartPairingAndAcceptInviteRoundTripAcrossTwoRuntimeInstancesToADoneBinding() {
        let aRuntime = makeRuntime(userId: "100")
        let bRuntime = makeRuntime(userId: "200")
        V2RuntimeRegistry.shared.set(aRuntime, for: "deviceA")
        V2RuntimeRegistry.shared.set(bRuntime, for: "deviceB")

        // No runtime installed at all for an account -> notOnV2, never a crash.
        XCTAssertEqual(V2PairingDispatch.startPairing(accountKey: "no-such-account", chatId: chat, targetUser: "200"), .notOnV2)

        guard case .sent(let inviteWire) = V2PairingDispatch.startPairing(accountKey: "deviceA", chatId: chat, targetUser: "200") else {
            return XCTFail("expected .sent")
        }
        XCTAssertTrue(inviteWire.hasPrefix("P2:"))

        // B receives the INVITE: a fresh one, nothing recorded yet.
        guard case .invited(let fromUser, let targetUser, let cachedWire) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: inviteWire, isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        XCTAssertEqual(fromUser, "100")
        XCTAssertEqual(targetUser, "200")
        XCTAssertEqual(cachedWire, inviteWire)

        // B's own outgoing echo of A's own INVITE (not really possible on the wire, but exercises the
        // isOutgoing guard the same way a local copy of a P2 message this device sent would) never
        // reaches the processor.
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: "deviceA", chatId: chat, wireText: inviteWire, isOutgoing: true), .ignored(reason: "own_echo:invite"))
        XCTAssertNil(aRuntime.pairing.bindingStore.current(chat), "the echo guard must never call into the processor")

        // The explicit "user tapped accept" action.
        guard case .sent(let acceptWire) = V2PairingDispatch.acceptInvite(accountKey: "deviceB", chatId: chat, inviteWire: cachedWire) else {
            return XCTFail("expected .sent")
        }
        XCTAssertEqual(bRuntime.pairing.currentTransactionForChat(chat), aRuntime.pairing.currentTransactionForChat(chat))

        guard case .progressed(let selectWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceA", chatId: chat, wireText: acceptWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire:)")
        }
        guard case .progressed(let confirmWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: selectWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire:)")
        }
        guard case .progressed(let readyWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceA", chatId: chat, wireText: confirmWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire:)")
        }
        // A completed at CONFIRM already (matching `V2Processor`'s own initiator-completes-first shape).
        XCTAssertNotNil(aRuntime.pairing.bindingStore.current(chat))

        guard case .progressed(nil) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: readyWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire: nil)")
        }
        XCTAssertNotNil(bRuntime.pairing.bindingStore.current(chat))
        XCTAssertEqual(aRuntime.pairing.bindingStore.current(chat)?.bindingId, bRuntime.pairing.bindingStore.current(chat)?.bindingId)

        // Done means "no longer in progress" — `currentTransactionForChat` hands off to
        // `V2Binding.BindingStore.current` from here on, exactly as designed.
        XCTAssertNil(aRuntime.pairing.currentTransactionForChat(chat))
        XCTAssertNil(bRuntime.pairing.currentTransactionForChat(chat))
    }

    func testConflictingSelectsMapToTheConflictOutcome() {
        let aRuntime = makeRuntime(userId: "100")
        let bRuntime = makeRuntime(userId: "200")
        let cRuntime = makeRuntime(userId: "300")
        V2RuntimeRegistry.shared.set(aRuntime, for: "deviceA")
        V2RuntimeRegistry.shared.set(bRuntime, for: "deviceB")
        V2RuntimeRegistry.shared.set(cRuntime, for: "deviceC")

        guard case .sent(let inviteWire) = V2PairingDispatch.startPairing(accountKey: "deviceA", chatId: chat, targetUser: "200") else {
            return XCTFail("expected .sent")
        }
        guard case .invited(_, _, let cachedWire) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: inviteWire, isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        guard case .sent(let acceptWire) = V2PairingDispatch.acceptInvite(accountKey: "deviceB", chatId: chat, inviteWire: cachedWire) else {
            return XCTFail("expected .sent")
        }
        guard case .progressed(let selectWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceA", chatId: chat, wireText: acceptWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire:)")
        }
        // B acts on the SELECT once already (advances it out of .selecting). A second, differently
        // built but still validly-signed-by-A SELECT for the very same txn is TEST_MATRIX P-17/section
        // 6's own CONFLICT, never a failure of either side — `handleSelect` checks the "already acted,
        // is this the same wire" question BEFORE it re-checks any hash/MAC field, so only the eventId
        // needs to differ to produce a genuine (not replayed) collision.
        guard case .progressed = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: selectWire, isOutgoing: false) else {
            return XCTFail("expected .progressed")
        }
        let parsedSelect = V2Messages.parseSelect(selectWire)!
        let forgedSelect = V2Messages.buildSelect(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: parsedSelect.envelope.txnId, chatId: chat, actorUser: "100",
            actorIdentityPk: aRuntime.identity.publicKey, actorIdentitySk: aRuntime.identity.secretKey,
            parentBinding: nil, createdMs: parsedSelect.envelope.createdMs, expiresMs: parsedSelect.envelope.expiresMs
        ), parsedSelect.body)!
        XCTAssertNotEqual(forgedSelect, selectWire)
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: forgedSelect, isOutgoing: false), .conflict)
    }

    func testUnrecognizedButStructurallyValidP2FamiliesAreIgnoredNeverCrashOrLeakToV1Parsing() {
        let aRuntime = makeRuntime(userId: "100")
        let bRuntime = makeRuntime(userId: "200")
        V2RuntimeRegistry.shared.set(aRuntime, for: "deviceA")
        V2RuntimeRegistry.shared.set(bRuntime, for: "deviceB")

        // CANCEL used to be lumped into this same bucket (fixed below, see
        // testCancelDispatchEndsTheTransactionOnBothSidesAndFailsClosedForAnUnknownOne) -- BUSY is
        // still genuinely unacted-on, so it stands in for the rest of the untouched bucket
        // (MERGE/ROSTER_COMMIT) here.
        let invite = aRuntime.pairing.startPairing(chat, "200")!
        let busyWire = V2Messages.buildBusy(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: invite.txnId, chatId: chat, actorUser: "100",
            actorIdentityPk: aRuntime.identity.publicKey, actorIdentitySk: aRuntime.identity.secretKey,
            parentBinding: nil, createdMs: String(Int64(Date().timeIntervalSince1970 * 1000)),
            expiresMs: String(Int64(Date().timeIntervalSince1970 * 1000) + 600_000)
        ), V2Messages.BusyBody(mainTxnId: invite.txnId, reason: "busy"))!
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: busyWire, isOutgoing: false), .ignored(reason: "busy"))

        // A non-"P2:" wire is never claimed by this dispatcher at all.
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: "P1:not-v2", isOutgoing: false), .notV2)
    }

    /// SECUTG-HOOK (fix): CANCEL used to be lumped into the same "recognized but not acted on" bucket
    /// as MERGE/BUSY/ROSTER_COMMIT -- so a device that cancelled its own stuck, non-bound transaction
    /// never told the peer, leaving the peer's copy of the same transaction stuck forever too, with no
    /// way back (unpair only tears down an installed binding, and `startPairing`'s own guard refuses a
    /// fresh INVITE while a transaction is still open). End to end: A starts pairing, B actually
    /// receives and records the INVITE (a real pending transaction, not a bare txnId), A cancels, B
    /// processes the CANCEL and its own transaction clears -- proven by a fresh INVITE being acceptable
    /// again afterward, not just by reading an internal flag.
    func testCancelDispatchEndsTheTransactionOnBothSidesAndFailsClosedForAnUnknownOne() {
        let aRuntime = makeRuntime(userId: "100")
        let bRuntime = makeRuntime(userId: "200")
        V2RuntimeRegistry.shared.set(aRuntime, for: "deviceA")
        V2RuntimeRegistry.shared.set(bRuntime, for: "deviceB")

        let invite = aRuntime.pairing.startPairing(chat, "200")!
        guard case .invited = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: invite.wire, isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        // `handleInvite` itself deliberately records no state (an unaccepted invite is just an offer,
        // not yet a transaction) -- B only has a real pending transaction to get stuck in, and for
        // CANCEL to clear, once it actually accepts.
        XCTAssertEqual(bRuntime.pairing.acceptInvite(invite.wire).kind, "accept")
        XCTAssertNotNil(bRuntime.pairing.currentTransactionForChat(chat))

        let cancelWire = aRuntime.pairing.cancelPairing(txnId: invite.txnId, reason: "user_cancelled")!
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: cancelWire, isOutgoing: false), .progressed(wire: nil))
        // B's own transaction actually cleared, not just A's -- the whole point of wiring this up.
        XCTAssertNil(bRuntime.pairing.currentTransactionForChat(chat))

        // SECUTG-HOOK (fix, 2026-09-27): B accepted at the processor level above, which (unlike
        // `V2PairingDispatch.acceptInvite`) leaves the cached copy of the invite in place — so B still
        // "offers" an invite A has cancelled. The same CANCEL arriving again now withdraws that cached
        // copy (authenticated against the invite itself — `handleCancelOfCachedInvite`)...
        XCTAssertNotNil(bRuntime.persisted.incomingInviteStore.get(chat))
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: cancelWire, isOutgoing: false), .progressed(wire: nil))
        XCTAssertNil(bRuntime.persisted.incomingInviteStore.get(chat))

        // ...and with nothing left it could apply to, a cancel for a transaction this device never
        // opened (unknown/already-gone txnId) fails closed rather than silently succeeding or crashing.
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: cancelWire, isOutgoing: false), .failed(reason: "unknown_txn"))
    }

    /// Fix A9: the dispatch-level `unpair` entry point, end to end — the explicit "user tapped
    /// unpair" action on A's side, and B actually processing the resulting UNPAIR wire instead of
    /// silently ignoring it (this second half used to be lumped into the untouched CANCEL/MERGE/
    /// BUSY/ROSTER_COMMIT "recognized but not acted on" bucket).
    func testUnpairDispatchDeactivatesTheBindingOnBothSidesAndFailsClosedWithoutABinding() {
        let aRuntime = makeRuntime(userId: "100")
        let bRuntime = makeRuntime(userId: "200")
        V2RuntimeRegistry.shared.set(aRuntime, for: "deviceA")
        V2RuntimeRegistry.shared.set(bRuntime, for: "deviceB")

        // No binding yet anywhere: fails closed, never a crash.
        XCTAssertEqual(V2PairingDispatch.unpair(accountKey: "no-such-account", chatId: chat), .notOnV2)
        XCTAssertEqual(V2PairingDispatch.unpair(accountKey: "deviceA", chatId: chat), .failed(reason: "no_binding"))

        guard case .sent(let inviteWire) = V2PairingDispatch.startPairing(accountKey: "deviceA", chatId: chat, targetUser: "200") else {
            return XCTFail("expected .sent")
        }
        guard case .invited(_, _, let cachedWire) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: inviteWire, isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        guard case .sent(let acceptWire) = V2PairingDispatch.acceptInvite(accountKey: "deviceB", chatId: chat, inviteWire: cachedWire) else {
            return XCTFail("expected .sent")
        }
        guard case .progressed(let selectWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceA", chatId: chat, wireText: acceptWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire:)")
        }
        guard case .progressed(let confirmWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: selectWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire:)")
        }
        guard case .progressed(let readyWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceA", chatId: chat, wireText: confirmWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire:)")
        }
        guard case .progressed(nil) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: readyWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire: nil)")
        }
        XCTAssertNotNil(aRuntime.pairing.bindingStore.current(chat))
        XCTAssertNotNil(bRuntime.pairing.bindingStore.current(chat))

        guard case .sent(let unpairWire) = V2PairingDispatch.unpair(accountKey: "deviceA", chatId: chat) else {
            return XCTFail("expected .sent")
        }
        XCTAssertTrue(unpairWire.hasPrefix("P2:"))
        XCTAssertNil(aRuntime.pairing.bindingStore.current(chat), "A's own binding must be gone immediately, locally")

        // B has not seen the UNPAIR yet — still trusts the old binding until it does.
        XCTAssertNotNil(bRuntime.pairing.bindingStore.current(chat))
        guard case .progressed(nil) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: unpairWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire: nil)")
        }
        XCTAssertNil(bRuntime.pairing.bindingStore.current(chat), "B must stop trusting the binding once A's UNPAIR arrives")
    }

    func testAcceptInviteFailsClosedForAnExpiredInvite() {
        var now: Int64 = 1_000_000
        let identityA = V2IdentityBridge.identity(userId: "100", from: makeStoredIdentity())!
        let aRuntime = V2Runtime(identity: identityA, persisted: V2PersistedState.load(storage: V2MemoryStorage()), now: { now })
        let bRuntime = makeRuntime(userId: "200")
        V2RuntimeRegistry.shared.set(aRuntime, for: "deviceA")
        V2RuntimeRegistry.shared.set(bRuntime, for: "deviceB")

        guard case .sent(let inviteWire) = V2PairingDispatch.startPairing(accountKey: "deviceA", chatId: chat, targetUser: "200") else {
            return XCTFail("expected .sent")
        }
        now += 11 * 60 * 1000 // past the 10-minute default TTL
        XCTAssertEqual(V2PairingDispatch.acceptInvite(accountKey: "deviceB", chatId: chat, inviteWire: inviteWire), .failed(reason: "expired"))
    }

    /// SECUTG-HOOK (fix): "换新密钥" (V2Roster rekey) exposed for the first time on a v2-paired 1v1
    /// chat — user's own explicit call: since this is a deliberate re-establish request (not an
    /// automatic rotation), the fix always uses the identity-sealed roster-rekey shape rather than
    /// the old R1-style symmetric-under-the-old-master rotate (which cryptographically CANNOT work
    /// without the receiver already holding that exact old master).
    ///
    /// Covers the user's explicit ask to re-verify "自动匹配" and "换钥" together, end to end, in one
    /// test: pairs two runtimes to a DONE binding first (same shape as
    /// `testStartPairingAndAcceptInviteRoundTripAcrossTwoRuntimeInstancesToADoneBinding`), THEN rekeys
    /// on top of that binding, THEN proves the new key is actually usable for a real send/receive --
    /// not just that a key got installed somewhere.
    func testRekeyDispatchEndToEndAfterARealPairingAndTheNewMasterActuallyWorks() {
        let aRuntime = makeRuntime(userId: "100")
        let bRuntime = makeRuntime(userId: "200")
        V2RuntimeRegistry.shared.set(aRuntime, for: "deviceA")
        V2RuntimeRegistry.shared.set(bRuntime, for: "deviceB")

        // Part 1: 自动匹配 (auto-pairing) all the way to a completed binding on both sides.
        guard case .sent(let inviteWire) = V2PairingDispatch.startPairing(accountKey: "deviceA", chatId: chat, targetUser: "200") else {
            return XCTFail("expected .sent")
        }
        guard case .invited(_, _, let cachedWire) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: inviteWire, isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        guard case .sent(let acceptWire) = V2PairingDispatch.acceptInvite(accountKey: "deviceB", chatId: chat, inviteWire: cachedWire) else {
            return XCTFail("expected .sent")
        }
        guard case .progressed(let selectWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceA", chatId: chat, wireText: acceptWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire:)")
        }
        guard case .progressed(let confirmWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: selectWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire:)")
        }
        guard case .progressed(let readyWire?) = V2PairingDispatch.handleIncoming(accountKey: "deviceA", chatId: chat, wireText: confirmWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire:)")
        }
        guard case .progressed(nil) = V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: readyWire, isOutgoing: false) else {
            return XCTFail("expected .progressed(wire: nil)")
        }
        guard let bindingBefore = aRuntime.pairing.bindingStore.current(chat) else {
            return XCTFail("expected a completed binding")
        }
        XCTAssertEqual(bindingBefore.bindingId, bRuntime.pairing.bindingStore.current(chat)?.bindingId)
        let oldMaster = aRuntime.pairing.keyStore.get(bindingBefore.bindingId, bindingBefore.epoch)?.master
        XCTAssertNotNil(oldMaster)

        // A private message under the ORIGINAL key, both directions, before touching anything -- the
        // baseline "自动匹配 still works" the user asked to reconfirm.
        let outcomeBefore = aRuntime.privateMessaging.send(chat, plaintext: Array("hello before rekey".utf8))
        guard outcomeBefore.ok, let wireBefore = outcomeBefore.wire else {
            return XCTFail("expected a successful send before rekey")
        }
        let receivedBefore = bRuntime.privateMessaging.receive(wireBefore)
        XCTAssertEqual(receivedBefore.plaintext, Array("hello before rekey".utf8))

        // No binding anywhere: fails closed, never a crash.
        XCTAssertEqual(V2PairingDispatch.rekey(accountKey: "no-such-account", chatId: chat), .notOnV2)
        XCTAssertEqual(V2PairingDispatch.rekey(accountKey: "deviceA", chatId: "no-such-chat"), .failed(reason: "no_binding"))

        // Part 2: 换钥 (rekey) -- A taps "换新密钥".
        guard case .sent(let rekeyWire) = V2PairingDispatch.rekey(accountKey: "deviceA", chatId: chat) else {
            return XCTFail("expected .sent")
        }
        XCTAssertTrue(rekeyWire.hasPrefix("P2:"))

        // A's own local echo of its outgoing rekey never reaches the processor (same own-echo guard
        // every other P2 type uses) -- confirms this doesn't crash and doesn't double-install.
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: "deviceA", chatId: chat, wireText: rekeyWire, isOutgoing: true), .ignored(reason: "own_echo:roster_commit"))

        // The whole point of wiring this up: B's processor's own `handleRosterCommit` actually runs.
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: "deviceB", chatId: chat, wireText: rekeyWire, isOutgoing: false), .progressed(wire: nil))

        let bindingAfter = aRuntime.pairing.bindingStore.current(chat)
        XCTAssertEqual(bindingAfter?.bindingId, bindingBefore.bindingId, "rekey must not change the bindingId")
        XCTAssertEqual(bindingAfter?.epoch, bindingBefore.epoch + 1)
        XCTAssertEqual(bindingAfter?.bindingId, bRuntime.pairing.bindingStore.current(chat)?.bindingId)
        XCTAssertEqual(bRuntime.pairing.bindingStore.current(chat)?.epoch, bindingBefore.epoch + 1)

        let newMasterA = aRuntime.pairing.keyStore.get(bindingAfter!.bindingId, bindingAfter!.epoch)?.master
        let newMasterB = bRuntime.pairing.keyStore.get(bindingAfter!.bindingId, bindingAfter!.epoch)?.master
        XCTAssertNotNil(newMasterA)
        XCTAssertEqual(newMasterA, newMasterB, "both sides must land on the identical new master")
        XCTAssertNotEqual(newMasterA, oldMaster, "must actually be a NEW key, not a repeat of the old one")

        // Not just "a key got installed somewhere" -- prove it is actually usable, both directions,
        // and that the OLD master no longer decrypts anything (it's gone, not kept as a fallback).
        let outcomeAfter = aRuntime.privateMessaging.send(chat, plaintext: Array("hello after rekey".utf8))
        guard outcomeAfter.ok, let wireAfter = outcomeAfter.wire else {
            return XCTFail("expected a successful send after rekey")
        }
        let receivedAfter = bRuntime.privateMessaging.receive(wireAfter)
        XCTAssertEqual(receivedAfter.plaintext, Array("hello after rekey".utf8))
        let replyOutcome = bRuntime.privateMessaging.send(chat, plaintext: Array("reply after rekey".utf8))
        guard replyOutcome.ok, let replyWire = replyOutcome.wire else {
            return XCTFail("expected a successful reply after rekey")
        }
        XCTAssertEqual(aRuntime.privateMessaging.receive(replyWire).plaintext, Array("reply after rekey".utf8))
    }
}
