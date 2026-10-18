import XCTest
@testable import SecutgCore

/// SECUTG-HOOK (fix, 2026-09-27): end-to-end coverage, through the real dispatch surface
/// (`V2PairingDispatch` / `V2Dispatch` / `V2PairingStatus`), for the pairing fixes of this date:
///
/// - BUG A: a P2 control wire on a BOUND chat used to be wrapped as E2. Every wire either side emits
///   here goes through `sendPath` first — the ordinary text send path, which must hand a P2 wire back
///   untouched — so BUG A is exercised on every single hop, not just in one dedicated test.
/// - BUG B: crossed invites deadlocked (the loser only sent MERGE; nobody ever ACCEPTed).
/// - BUG B2: a genuinely newer invite on an already-bound chat could not be accepted.
/// - C0: real 1:1 chat ids are ASYMMETRIC — each side names the chat after the OTHER user (A = user
///   "100" calls it "200", B = user "200" calls it "100"). Every earlier test used one shared chat id for
///   both sides, which is exactly how the responder filing everything under its own user id went unseen.
/// - Status rules: unpaired reads as nothing, an expired own INVITE stops reading "invited", an expired
///   or cancelled cached invite is not offered.
final class V2PairingRealChatIdTests: XCTestCase {
    private let keyA = "deviceA"
    private let keyB = "deviceB"
    private let userA = "100"
    private let userB = "200"

    /// Each side's OWN name for the one 1:1 chat.
    private struct Chats {
        let a: String
        let b: String
    }

    /// What real clients use: each side names the chat after the other user.
    private let real = Chats(a: "200", b: "100")
    /// The single shared id every older test used.
    private let shared = Chats(a: "4200", b: "4200")

    private final class Clock {
        var ms: Int64 = 1_700_000_000_000
    }

    private let clock = Clock()

    override func tearDown() {
        V2RuntimeRegistry.shared.reset(for: keyA)
        V2RuntimeRegistry.shared.reset(for: keyB)
        super.tearDown()
    }

    // MARK: harness

    private func makeStoredIdentity() -> KeyRing.Identity {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        return KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
    }

    /// A fresh device for `userId`, registered under `key` (replacing whatever was there — a reinstall).
    @discardableResult
    private func makeRuntime(userId: String, key: String, storage: V2Storage = V2MemoryStorage()) -> V2Runtime {
        let identity = V2IdentityBridge.identity(userId: userId, from: makeStoredIdentity())!
        let clock = self.clock
        let runtime = V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: storage), now: { clock.ms })
        V2RuntimeRegistry.shared.set(runtime, for: key)
        return runtime
    }

    private func chat(of key: String, _ chats: Chats) -> String {
        return key == keyA ? chats.a : chats.b
    }

    private func peer(of key: String) -> String {
        return key == keyA ? keyB : keyA
    }

    private func status(_ key: String, _ chats: Chats) -> V2PairingStatus {
        return V2PairingStatus.of(accountKey: key, chatId: chat(of: key, chats))
    }

    /// What a real client does with any P2 wire before it goes out: the ordinary text send path, which
    /// must return `.notOnV2` (send it raw) even on a bound chat — BUG A.
    @discardableResult
    private func sendPath(_ from: String, _ wire: String, _ chats: Chats, file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(wire.hasPrefix("P2:"), "not a P2 wire: \(wire.prefix(12))", file: file, line: line)
        XCTAssertEqual(V2Dispatch.prepareOutgoingText(accountKey: from, chatId: chat(of: from, chats), text: wire), .notOnV2,
                       "a P2 wire must leave through the send path untouched", file: file, line: line)
        return wire
    }

    /// Delivers each (sender, wire) to the other side through `V2PairingDispatch.handleIncoming`, sends
    /// every automatic reply back the same way, and stops once nothing is left in flight.
    @discardableResult
    private func pump(_ initial: [(from: String, wire: String)], _ chats: Chats, file: StaticString = #filePath, line: UInt = #line) -> [(at: String, outcome: V2PairingReceiveOutcome)] {
        var queue: [(to: String, wire: String)] = initial.map { (to: peer(of: $0.from), wire: sendPath($0.from, $0.wire, chats, file: file, line: line)) }
        var seen: [(at: String, outcome: V2PairingReceiveOutcome)] = []
        while !queue.isEmpty {
            guard seen.count < 40 else {
                XCTFail("the exchange never settled", file: file, line: line)
                break
            }
            let next = queue.removeFirst()
            let outcome = V2PairingDispatch.handleIncoming(accountKey: next.to, chatId: chat(of: next.to, chats), wireText: next.wire, isOutgoing: false)
            seen.append((at: next.to, outcome: outcome))
            if case .progressed(let reply?) = outcome {
                queue.append((to: peer(of: next.to), wire: sendPath(next.to, reply, chats, file: file, line: line)))
            }
        }
        return seen
    }

    /// A invites, B receives and taps accept, everything else is pumped until both sides are bound.
    private func pairThroughDispatch(_ chats: Chats, file: StaticString = #filePath, line: UInt = #line) -> (a: V2Runtime, b: V2Runtime) {
        let a = makeRuntime(userId: userA, key: keyA)
        let b = makeRuntime(userId: userB, key: keyB)
        guard case .sent(let invite) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: chats.a, targetUser: userB) else {
            XCTFail("startPairing did not send", file: file, line: line)
            return (a, b)
        }
        let received = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chats.b, wireText: sendPath(keyA, invite, chats, file: file, line: line), isOutgoing: false)
        guard case .invited(let fromUser, _, let cached) = received else {
            XCTFail("expected .invited, got \(received)", file: file, line: line)
            return (a, b)
        }
        XCTAssertEqual(fromUser, userA, file: file, line: line)
        guard case .sent(let accept) = V2PairingDispatch.acceptInvite(accountKey: keyB, chatId: chats.b, inviteWire: cached) else {
            XCTFail("acceptInvite did not send", file: file, line: line)
            return (a, b)
        }
        pump([(from: keyB, wire: accept)], chats, file: file, line: line)
        XCTAssertNotNil(a.pairing.bindingStore.current(chats.a), "A must be bound under its own chat id", file: file, line: line)
        XCTAssertNotNil(b.pairing.bindingStore.current(chats.b), "B must be bound under its own chat id", file: file, line: line)
        return (a, b)
    }

    /// One E2 business message through the real send/receive surface.
    private func assertE2(from: String, _ text: String, _ chats: Chats, file: StaticString = #filePath, line: UInt = #line) {
        let to = peer(of: from)
        let sent = V2Dispatch.prepareOutgoingText(accountKey: from, chatId: chat(of: from, chats), text: text)
        guard case .sent(let wire) = sent else {
            return XCTFail("expected an E2 send, got \(sent)", file: file, line: line)
        }
        XCTAssertTrue(wire.hasPrefix("E2:"), file: file, line: line)
        XCTAssertEqual(V2Dispatch.decryptIncomingText(accountKey: to, chatId: chat(of: to, chats), wireText: wire), .decrypted(text: text), file: file, line: line)
    }

    /// Both sides agree on one binding, one non-nil safety code, nothing in flight, nothing offered, and
    /// (C0) nothing filed under either side's own user id — its Saved Messages chat.
    private func assertBothPaired(_ a: V2Runtime, _ b: V2Runtime, _ chats: Chats, file: StaticString = #filePath, line: UInt = #line) {
        let bindingA = a.pairing.bindingStore.current(chats.a)
        let bindingB = b.pairing.bindingStore.current(chats.b)
        XCTAssertNotNil(bindingA, file: file, line: line)
        XCTAssertEqual(bindingA?.bindingId, bindingB?.bindingId, file: file, line: line)
        let statusA = status(keyA, chats)
        let statusB = status(keyB, chats)
        XCTAssertEqual(statusA.pairingState, "paired", file: file, line: line)
        XCTAssertEqual(statusB.pairingState, "paired", file: file, line: line)
        XCTAssertNotNil(statusA.safetyCode, file: file, line: line)
        XCTAssertEqual(statusA.safetyCode, statusB.safetyCode, "both sides must read out the same safety code", file: file, line: line)
        XCTAssertFalse(statusA.hasIncomingInvite, file: file, line: line)
        XCTAssertFalse(statusB.hasIncomingInvite, file: file, line: line)
        XCTAssertNil(a.pairing.currentTransactionForChat(chats.a), file: file, line: line)
        XCTAssertNil(b.pairing.currentTransactionForChat(chats.b), file: file, line: line)
        if chats.a != chats.b {
            XCTAssertNil(a.pairing.bindingStore.current(userA), "nothing may be filed under A's own user id", file: file, line: line)
            XCTAssertNil(b.pairing.bindingStore.current(userB), "nothing may be filed under B's own user id", file: file, line: line)
        }
    }

    private func txnId(of wire: String) -> String? {
        return V2Envelope.parse(prefix: V2Messages.prefix, text: wire)?.txnId
    }

    // MARK: BUG A — protocol wires are never wrapped as E2

    func testProtocolWiresOnABoundChatAreNeverWrappedAsE2ButPlainTextIs() {
        let (a, _) = pairThroughDispatch(shared)
        let chatA = shared.a
        guard case .sent(let e2Wire) = V2Dispatch.prepareOutgoingText(accountKey: keyA, chatId: chatA, text: "plain text") else {
            return XCTFail("plain text on a bound chat must be sent as E2")
        }
        XCTAssertTrue(e2Wire.hasPrefix("E2:"))
        // An already-built E2 wire goes out exactly as it is.
        XCTAssertEqual(V2Dispatch.prepareOutgoingText(accountKey: keyA, chatId: chatA, text: e2Wire), .notOnV2)
        XCTAssertTrue(V2Dispatch.isProtocolWire(e2Wire))
        // Text that merely STARTS like a wire is text, and is encrypted (review finding, 2026-09-27: a prefix
        // test would have sent these words in the clear).
        for typed in ["E2:anything", "N2:x", "W2:x", "E1:x", "E1: hi", "P2:INVITE:x", "P2: see you"] {
            XCTAssertFalse(V2Dispatch.isProtocolWire(typed), typed)
            guard case .sent(let wire) = V2Dispatch.prepareOutgoingText(accountKey: keyA, chatId: chatA, text: typed) else {
                XCTFail("typed text must be E2-encrypted: \(typed)")
                continue
            }
            XCTAssertEqual(V2Dispatch.decryptIncomingText(accountKey: keyB, chatId: shared.b, wireText: wire), .decrypted(text: typed), typed)
        }
        // v1 control lines, recognised through `Rekey.isControlMessage`.
        let u1 = try? Rekey.buildU1(userId: userA, at: 1_700_000_000, ed25519Sk: V2Suite.generateEd25519().secretKey)
        XCTAssertNotNil(u1)
        if let u1 = u1 {
            XCTAssertEqual(V2Dispatch.prepareOutgoingText(accountKey: keyA, chatId: chatA, text: u1), .notOnV2)
        }
        // The rekey entry point's own ROSTER_COMMIT — the wire that used to strand the peer on missing_key.
        guard case .sent(let rekeyWire) = V2PairingDispatch.rekey(accountKey: keyA, chatId: chatA) else { return XCTFail("rekey did not send") }
        XCTAssertEqual(V2Dispatch.prepareOutgoingText(accountKey: keyA, chatId: chatA, text: rekeyWire), .notOnV2)
        XCTAssertFalse(V2Dispatch.isProtocolWire("hello"))
        XCTAssertNotNil(a.pairing.bindingStore.current(chatA))
    }

    private func runRekeyBothWays(_ chats: Chats, file: StaticString = #filePath, line: UInt = #line) {
        let (a, b) = pairThroughDispatch(chats, file: file, line: line)
        assertE2(from: keyA, "before rekey", chats, file: file, line: line)
        assertE2(from: keyB, "before rekey, reply", chats, file: file, line: line)

        guard case .sent(let rekeyA) = V2PairingDispatch.rekey(accountKey: keyA, chatId: chats.a) else { return XCTFail("A rekey", file: file, line: line) }
        let atB = pump([(from: keyA, wire: rekeyA)], chats, file: file, line: line)
        XCTAssertEqual(atB.first?.outcome, .progressed(wire: nil), file: file, line: line)
        XCTAssertEqual(a.pairing.bindingStore.current(chats.a)?.epoch, 2, file: file, line: line)
        XCTAssertEqual(b.pairing.bindingStore.current(chats.b)?.epoch, 2, file: file, line: line)
        assertE2(from: keyA, "hello", chats, file: file, line: line)
        assertE2(from: keyB, "hello back", chats, file: file, line: line)

        guard case .sent(let rekeyB) = V2PairingDispatch.rekey(accountKey: keyB, chatId: chats.b) else { return XCTFail("B rekey", file: file, line: line) }
        let atA = pump([(from: keyB, wire: rekeyB)], chats, file: file, line: line)
        XCTAssertEqual(atA.first?.outcome, .progressed(wire: nil), file: file, line: line)
        XCTAssertEqual(a.pairing.bindingStore.current(chats.a)?.epoch, 3, file: file, line: line)
        XCTAssertEqual(b.pairing.bindingStore.current(chats.b)?.epoch, 3, file: file, line: line)
        assertE2(from: keyA, "after second rekey", chats, file: file, line: line)
        assertE2(from: keyB, "after second rekey, reply", chats, file: file, line: line)
        assertBothPaired(a, b, chats, file: file, line: line)
    }

    func testRekeyWireGoesOutRawAndBothSidesKeepTalkingSharedChatId() {
        runRekeyBothWays(shared)
    }

    // MARK: BUG B — crossed invites

    private func runCrossedInvites(_ chats: Chats, deliverToBFirst: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let a = makeRuntime(userId: userA, key: keyA)
        let b = makeRuntime(userId: userB, key: keyB)
        guard case .sent(let inviteA) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: chats.a, targetUser: userB),
              case .sent(let inviteB) = V2PairingDispatch.startPairing(accountKey: keyB, chatId: chats.b, targetUser: userA),
              let txnA = txnId(of: inviteA), let txnB = txnId(of: inviteB) else {
            return XCTFail("both sides must be able to invite", file: file, line: line)
        }
        let fromA = (from: keyA, wire: inviteA)
        let fromB = (from: keyB, wire: inviteB)
        let seen = pump(deliverToBFirst ? [fromA, fromB] : [fromB, fromA], chats, file: file, line: line)

        // Each side's answer to the other's INVITE: exactly one MERGE (the winner) and one ACCEPT (the loser).
        let answers = seen.prefix(2).compactMap { entry -> String? in
            guard case .progressed(let wire?) = entry.outcome else { return nil }
            return V2Envelope.parse(prefix: V2Messages.prefix, text: wire)?.type
        }
        XCTAssertEqual(Set(answers), ["MERGE", "ACCEPT"], file: file, line: line)
        XCTAssertTrue(seen.contains { $0.outcome == .ignored(reason: "merge") }, "the MERGE is informational only", file: file, line: line)
        XCTAssertFalse(seen.contains { if case .invited = $0.outcome { return true } else { return false } },
                       "a crossed invite must never be cached for a tap", file: file, line: line)

        assertBothPaired(a, b, chats, file: file, line: line)
        XCTAssertEqual(a.pairing.bindingStore.current(chats.a)?.txnId, V2Processor.smallerTxnId(txnA, txnB), file: file, line: line)
        XCTAssertNil(a.persisted.incomingInviteStore.get(chats.a), file: file, line: line)
        XCTAssertNil(b.persisted.incomingInviteStore.get(chats.b), file: file, line: line)
        assertE2(from: keyA, "crossed and paired", chats, file: file, line: line)
        assertE2(from: keyB, "crossed and paired, reply", chats, file: file, line: line)
    }

    func testCrossedInvitesConvergeThroughDispatchInBothDeliveryOrdersSharedChatId() {
        runCrossedInvites(shared, deliverToBFirst: true)
        runCrossedInvites(shared, deliverToBFirst: false)
    }

    // MARK: BUG B2 — a newer invite on a bound chat

    func testIsInviteNewerComparesTheInvitesCreationTimeWithTheBindingsInstallTime() {
        let a = makeRuntime(userId: userA, key: keyA)
        let created = clock.ms
        let invite = a.pairing.startPairing(real.a, userB)!.wire
        XCTAssertTrue(V2PairingDispatch.isInviteNewer(thanBindingInstalledAtMs: created - 1, inviteWire: invite))
        XCTAssertFalse(V2PairingDispatch.isInviteNewer(thanBindingInstalledAtMs: created, inviteWire: invite))
        XCTAssertFalse(V2PairingDispatch.isInviteNewer(thanBindingInstalledAtMs: created + 60_000, inviteWire: invite))
        XCTAssertFalse(V2PairingDispatch.isInviteNewer(thanBindingInstalledAtMs: 0, inviteWire: "P2:not-an-envelope"))
        XCTAssertFalse(V2PairingDispatch.isInviteNewer(thanBindingInstalledAtMs: 0, inviteWire: "hello"))
    }

    private func runNewerInviteReplacesBinding(_ chats: Chats, file: StaticString = #filePath, line: UInt = #line) {
        let (_, b) = pairThroughDispatch(chats, file: file, line: line)
        guard let oldBinding = b.pairing.bindingStore.current(chats.b) else { return XCTFail("not paired", file: file, line: line) }
        let oldCode = status(keyB, chats).safetyCode
        XCTAssertFalse(status(keyB, chats).hasIncomingInvite, file: file, line: line)

        // A reinstalls (new identity, empty state) a minute later and pairs afresh.
        clock.ms += 60_000
        let a2 = makeRuntime(userId: userA, key: keyA)
        guard case .sent(let invite2) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: chats.a, targetUser: userB) else {
            return XCTFail("A2 could not invite", file: file, line: line)
        }
        let received = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chats.b, wireText: sendPath(keyA, invite2, chats, file: file, line: line), isOutgoing: false)
        // PLAN.md 3.43: A came back with a NEW identity, which B's binding does not know — the offer is the key-changed
        // variant now, cached and accepted exactly like an ordinary invite, and nothing adopted until B accepts.
        guard case .invitedKeyChanged(_, _, let cached, _, _) = received else { return XCTFail("expected .invitedKeyChanged, got \(received)", file: file, line: line) }
        let offered = status(keyB, chats)
        XCTAssertEqual(offered.pairingState, "paired", file: file, line: line)
        XCTAssertTrue(offered.hasIncomingInvite, "a newer invite on a bound chat must be offered", file: file, line: line)
        XCTAssertEqual(offered.safetyCode, oldCode, "until it is accepted, the old binding still speaks", file: file, line: line)

        // Accepting on the bound chat: the ACCEPT (and every later hop) must still leave raw — BUG A.
        guard case .sent(let accept) = V2PairingDispatch.acceptInvite(accountKey: keyB, chatId: chats.b, inviteWire: cached) else {
            return XCTFail("B could not accept the newer invite", file: file, line: line)
        }
        pump([(from: keyB, wire: accept)], chats, file: file, line: line)

        let newBinding = b.pairing.bindingStore.current(chats.b)
        XCTAssertNotEqual(newBinding?.bindingId, oldBinding.bindingId, "the new pairing replaces the old key", file: file, line: line)
        XCTAssertTrue(b.pairing.bindingStore.historical(chats.b).contains { $0.bindingId == oldBinding.bindingId }, file: file, line: line)
        assertBothPaired(a2, b, chats, file: file, line: line)
        XCTAssertNotEqual(status(keyB, chats).safetyCode, oldCode, file: file, line: line)
        assertE2(from: keyA, "hello again", chats, file: file, line: line)
        assertE2(from: keyB, "welcome back", chats, file: file, line: line)
    }

    func testANewerInviteOnABoundChatIsOfferedAndAcceptingReplacesTheBindingSharedChatId() {
        runNewerInviteReplacesBinding(shared)
    }

    // MARK: C0 — real (asymmetric) 1:1 chat ids

    func testRealChatIdsPairingFilesEverythingUnderEachSidesOwnChatWithTheSameCode() {
        let (a, b) = pairThroughDispatch(real)
        assertBothPaired(a, b, real)
        // B's own user id is B's Saved Messages chat: nothing v2 there, so nothing sent to it is E2-wrapped.
        XCTAssertEqual(V2PairingStatus.of(accountKey: keyB, chatId: userB), .none)
        XCTAssertEqual(V2Dispatch.prepareOutgoingText(accountKey: keyB, chatId: userB, text: "note to self"), .notOnV2)
    }

    func testRealChatIdsE2BothDirections() {
        _ = pairThroughDispatch(real)
        assertE2(from: keyA, "hi B", real)
        assertE2(from: keyB, "hi A", real)
    }

    func testRealChatIdsRekeyBothDirections() {
        runRekeyBothWays(real)
    }

    func testRealChatIdsUnpairFromEitherSideLeavesBothSidesWithNoStateAndNoCode() {
        for unpairing in [keyB, keyA] {
            let (a, b) = pairThroughDispatch(real)
            guard case .sent(let unpairWire) = V2PairingDispatch.unpair(accountKey: unpairing, chatId: chat(of: unpairing, real)) else {
                return XCTFail("\(unpairing) could not unpair")
            }
            let seen = pump([(from: unpairing, wire: unpairWire)], real)
            XCTAssertEqual(seen.first?.outcome, .progressed(wire: nil))
            XCTAssertNil(a.pairing.bindingStore.current(real.a))
            XCTAssertNil(b.pairing.bindingStore.current(real.b))
            XCTAssertEqual(status(keyA, real), .none, "an unpaired chat reads as no state, never \"paired\"")
            XCTAssertEqual(status(keyB, real), .none, "an unpaired chat reads as no state, never \"paired\"")
            XCTAssertEqual(V2Dispatch.prepareOutgoingText(accountKey: keyA, chatId: real.a, text: "after unpair"), .notOnV2)
        }
    }

    func testRealChatIdsInitiatorResetClearsTheResponderStuckMidExchange() {
        let a = makeRuntime(userId: userA, key: keyA)
        let b = makeRuntime(userId: userB, key: keyB)
        guard case .sent(let invite) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: real.a, targetUser: userB) else { return XCTFail("invite") }
        guard case .invited(_, _, let cached) = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: real.b, wireText: sendPath(keyA, invite, real), isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        guard case .sent = V2PairingDispatch.acceptInvite(accountKey: keyB, chatId: real.b, inviteWire: cached) else { return XCTFail("accept") }
        // B's ACCEPT is lost; A presses 一键恢复.
        XCTAssertEqual(status(keyB, real).pairingState, "invited")
        let resetWires = a.pairing.cancelAllForChat(real.a)
        XCTAssertEqual(resetWires.count, 1)
        let seen = pump(resetWires.map { (from: keyA, wire: $0) }, real)
        XCTAssertEqual(seen.first?.outcome, .progressed(wire: nil))
        XCTAssertNil(b.pairing.currentTransactionForChat(real.b))
        XCTAssertEqual(status(keyA, real), .none)
        XCTAssertEqual(status(keyB, real), .none)
    }

    /// A peer's CANCEL is only verifiable once the receiver knows the peer's identity key — for the
    /// initiator, that is after it has seen the ACCEPT. So: B's ACCEPT reaches A, A's SELECT is lost,
    /// B presses 一键恢复; A must end with no state, and the lost SELECT arriving late must change nothing.
    func testRealChatIdsResponderResetClearsTheInitiatorAndALateSelectIsIgnored() {
        let a = makeRuntime(userId: userA, key: keyA)
        let b = makeRuntime(userId: userB, key: keyB)
        guard case .sent(let invite) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: real.a, targetUser: userB) else { return XCTFail("invite") }
        guard case .invited(_, _, let cached) = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: real.b, wireText: sendPath(keyA, invite, real), isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        guard case .sent(let accept) = V2PairingDispatch.acceptInvite(accountKey: keyB, chatId: real.b, inviteWire: cached) else { return XCTFail("accept") }
        let atA = V2PairingDispatch.handleIncoming(accountKey: keyA, chatId: real.a, wireText: sendPath(keyB, accept, real), isOutgoing: false)
        guard case .progressed(let lostSelect?) = atA else { return XCTFail("expected a SELECT, got \(atA)") }
        sendPath(keyA, lostSelect, real)

        let resetWires = b.pairing.cancelAllForChat(real.b)
        XCTAssertEqual(resetWires.count, 1)
        let seen = pump(resetWires.map { (from: keyB, wire: $0) }, real)
        XCTAssertEqual(seen.first?.outcome, .progressed(wire: nil))
        XCTAssertNil(a.pairing.currentTransactionForChat(real.a))
        XCTAssertEqual(status(keyA, real), .none)

        let late = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: real.b, wireText: lostSelect, isOutgoing: false)
        XCTAssertEqual(late, .failed(reason: "cancelled"))
        XCTAssertEqual(status(keyB, real), .none)
        XCTAssertNil(b.pairing.bindingStore.current(real.b))
    }

    func testRealChatIdsCrossedInvitesConvergeInBothDeliveryOrders() {
        runCrossedInvites(real, deliverToBFirst: true)
        runCrossedInvites(real, deliverToBFirst: false)
    }

    func testRealChatIdsNewerInviteOnABoundChatReplacesTheBinding() {
        runNewerInviteReplacesBinding(real)
    }

    // MARK: status — expired invites

    func testAnOwnInvitePastItsExpiryReadsAsNoStateAndAnExpiredCachedInviteIsNotOffered() {
        let a = makeRuntime(userId: userA, key: keyA)
        let b = makeRuntime(userId: userB, key: keyB)
        guard case .sent(let invite) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: real.a, targetUser: userB), let txn = txnId(of: invite) else {
            return XCTFail("invite")
        }
        guard case .invited = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: real.b, wireText: sendPath(keyA, invite, real), isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        let ttl: Int64 = 10 * 60 * 1000
        clock.ms += ttl - 1
        XCTAssertFalse(a.pairing.isOwnInviteExpired(txn))
        XCTAssertFalse(b.pairing.isInviteExpired(invite))
        XCTAssertEqual(status(keyA, real).pairingState, "invited")
        XCTAssertEqual(status(keyB, real), V2PairingStatus(pairingState: nil, verified: false, hasIncomingInvite: true, safetyCode: nil))

        clock.ms += 1
        XCTAssertTrue(a.pairing.isOwnInviteExpired(txn))
        XCTAssertTrue(a.pairing.isInviteExpired(invite))
        XCTAssertTrue(b.pairing.isInviteExpired(invite))
        XCTAssertTrue(b.pairing.isInviteExpired("P2:garbage"), "an unparseable invite can never be accepted either")
        XCTAssertEqual(status(keyA, real), .none, "no endless 等待对方同意… for an invite nobody can accept")
        XCTAssertEqual(status(keyB, real), .none, "an expired invite is not offered")
        XCTAssertEqual(V2PairingDispatch.acceptInvite(accountKey: keyB, chatId: real.b, inviteWire: invite), .failed(reason: "expired"))
    }

    func testIsOwnInviteExpiredIsFalseForAResponderTxnAndOnceTheExchangeHasMovedOn() {
        let (a, b) = pairThroughDispatch(real)
        guard let bindingTxn = a.pairing.bindingStore.current(real.a)?.txnId else { return XCTFail("not paired") }
        clock.ms += 24 * 60 * 60 * 1000
        XCTAssertFalse(a.pairing.isOwnInviteExpired(bindingTxn), "DONE, not INVITED")
        XCTAssertFalse(b.pairing.isOwnInviteExpired(bindingTxn), "a responder txn is never 'own invite'")
        XCTAssertFalse(a.pairing.isOwnInviteExpired("no-such-txn"))
        XCTAssertEqual(status(keyA, real).pairingState, "paired", "a binding does not expire with its invite")
    }

    // MARK: CANCEL of an invite that was only cached

    func testAPeersCancelOfAnInviteThisSideOnlyCachedWithdrawsItAndAForgedOneDoesNot() {
        let a = makeRuntime(userId: userA, key: keyA)
        let b = makeRuntime(userId: userB, key: keyB)
        guard case .sent(let invite) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: real.a, targetUser: userB) else { return XCTFail("invite") }
        guard case .invited = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: real.b, wireText: sendPath(keyA, invite, real), isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        XCTAssertTrue(status(keyB, real).hasIncomingInvite)

        // A presses 一键恢复 before B ever taps 同意: B holds no txn, only the cached invite.
        let resetWires = a.pairing.cancelAllForChat(real.a)
        XCTAssertEqual(resetWires.count, 1)
        let seen = pump(resetWires.map { (from: keyA, wire: $0) }, real)
        XCTAssertEqual(seen.first?.outcome, .progressed(wire: nil))
        XCTAssertFalse(status(keyB, real).hasIncomingInvite, "a cancelled invite is no longer offered")
        XCTAssertNil(b.persisted.incomingInviteStore.get(real.b))
        XCTAssertEqual(b.pairing.acceptInvite(invite, localChatId: real.b).kind, "cancelled")

        // A fresh invite, then a CANCEL for its txn signed by some other key: ignored, invite stays on offer.
        guard case .sent(let invite2) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: real.a, targetUser: userB), let txn2 = txnId(of: invite2) else {
            return XCTFail("second invite")
        }
        guard case .invited(_, _, let cached2) = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: real.b, wireText: sendPath(keyA, invite2, real), isOutgoing: false) else {
            return XCTFail("expected .invited")
        }
        let impostor = V2Suite.generateEd25519()
        let forged = V2Messages.buildCancel(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: txn2, chatId: real.a, actorUser: userA, actorIdentityPk: impostor.publicKey,
            actorIdentitySk: impostor.secretKey, parentBinding: nil, createdMs: String(clock.ms), expiresMs: String(clock.ms + 600_000)
        ), V2Messages.CancelBody(targetTxnId: txn2, reason: "user_reset"))!
        let forgedOutcome = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: real.b, wireText: forged, isOutgoing: false)
        XCTAssertEqual(forgedOutcome, .failed(reason: "unknown_txn"))
        XCTAssertTrue(status(keyB, real).hasIncomingInvite, "a forged CANCEL must not withdraw a real invite")
        XCTAssertEqual(b.persisted.incomingInviteStore.get(real.b), cached2)

        // ...and that invite still pairs all the way through.
        guard case .sent(let accept) = V2PairingDispatch.acceptInvite(accountKey: keyB, chatId: real.b, inviteWire: cached2) else { return XCTFail("accept") }
        pump([(from: keyB, wire: accept)], real)
        assertBothPaired(a, b, real)
    }

    // MARK: C0 — one-time repair of state written before the fix

    /// Strips `PendingTxn`'s new field from a snapshot, through a real JSON round trip, so it looks exactly
    /// like one written before `localChatId` existed.
    private func legacySnapshot(_ snapshot: V2PersistedState.Snapshot) throws -> V2PersistedState.Snapshot {
        func strip(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, inner) in object where key != "persistedLocalChatId" { out[key] = strip(inner) }
                return out
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        let stripped = try JSONSerialization.data(withJSONObject: strip(json))
        XCTAssertFalse(String(decoding: stripped, as: UTF8.self).contains("persistedLocalChatId"))
        return try JSONDecoder().decode(V2PersistedState.Snapshot.self, from: stripped)
    }

    func testReloadRepairsAResponderBindingThatTheOldCodeFiledUnderOwnUserId() throws {
        let storageB = V2MemoryStorage()
        let a = makeRuntime(userId: userA, key: keyA)
        let b = makeRuntime(userId: userB, key: keyB, storage: storageB)
        guard case .sent(let invite) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: real.a, targetUser: userB) else { return XCTFail("invite") }
        // The OLD placement: the one-argument accept files under the envelope's chat id — A's view, "200",
        // which is B's own user id.
        let accepted = b.pairing.acceptInvite(invite)
        XCTAssertEqual(accepted.kind, "accept")
        pump([(from: keyB, wire: accepted.wire!)], real)
        XCTAssertNotNil(b.pairing.bindingStore.current(userB), "reproduces the old misplacement")
        XCTAssertNil(b.pairing.bindingStore.current(real.b))
        XCTAssertEqual(V2Dispatch.prepareOutgoingText(accountKey: keyB, chatId: real.b, text: "leaks in the clear"), .notOnV2, "the live symptom")
        b.persisted.persist()

        // Restart B from what it had persisted.
        let clock = self.clock
        let restored = V2Runtime(identity: b.identity, persisted: V2PersistedState.load(storage: V2MemoryStorage(try legacySnapshot(storageB.saved!))),
                                 now: { clock.ms })
        V2RuntimeRegistry.shared.set(restored, for: keyB)
        XCTAssertNotNil(restored.pairing.bindingStore.current(real.b), "re-filed under B's own name for the chat")
        XCTAssertNil(restored.pairing.bindingStore.current(userB), "nothing left current under B's own user id")
        XCTAssertEqual(restored.pairing.bindingStore.current(real.b)?.bindingId, a.pairing.bindingStore.current(real.a)?.bindingId)
        XCTAssertEqual(V2Dispatch.prepareOutgoingText(accountKey: keyB, chatId: userB, text: "wipe phrase to self"), .notOnV2,
                       "Saved Messages must not be E2-wrapped any more")
        assertBothPaired(a, restored, real)
        assertE2(from: keyA, "after the repair", real)
        assertE2(from: keyB, "and back", real)
        XCTAssertFalse(restored.pairing.repairResponderTxnsFiledUnderOwnUserId(), "idempotent: nothing left to repair")
    }
}
