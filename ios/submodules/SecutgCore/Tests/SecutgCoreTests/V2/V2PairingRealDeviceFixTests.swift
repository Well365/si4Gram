import XCTest
@testable import SecutgCore

/// SECUTG-HOOK (fix, 2026-09-27 真机): the pure pieces behind the real-device report of this date — Android and
/// iOS were v2-paired, both still carried leftover v1 pairing records, and:
///
/// - the status read the leftover v1 "invited" first (menu stuck on 等待对方同意) and a pairing tap sent a v1 P1
///   the peer could never accept → `V2PairingStatus.resolve` (v2-first, v1 only when really "paired");
/// - every intermediate v2 step rendered as an EMPTY bubble, every refused P2 as a raw reason code →
///   `V2PairingLine` / `V2PairingDispatch.ownEchoLine` & co.;
/// - a v1 U1 that had nothing to unpair rendered "换钥消息已忽略：no_peer_key" → `RekeyProcessor.isNothingToUnpair`;
/// - 〔在本机重新配对〕 on a CONFLICT chat could never start a fresh INVITE → `dropConflictsForChat`.
final class V2PairingRealDeviceFixTests: XCTestCase {
    private let keyA = "fixDeviceA"
    private let keyB = "fixDeviceB"
    private let userA = "100"
    private let userB = "200"
    /// Real 1:1 chat ids: each side names the chat after the other user.
    private let chatA = "200"
    private let chatB = "100"

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

    @discardableResult
    private func makeRuntime(userId: String, key: String) -> V2Runtime {
        let identity = V2IdentityBridge.identity(userId: userId, from: makeStoredIdentity())!
        let runtime = V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: V2MemoryStorage()))
        V2RuntimeRegistry.shared.set(runtime, for: key)
        return runtime
    }

    private func params(_ identity: V2Identity) -> V2Messages.EnvelopeParams {
        return V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: V2Envelope.randomId(), chatId: chatA, actorUser: identity.userId,
            actorIdentityPk: identity.publicKey, actorIdentitySk: identity.secretKey, parentBinding: nil,
            createdMs: "1700000000000", expiresMs: "1700000600000"
        )
    }

    /// One structurally valid, signed wire of every P2 type. The bodies are placeholders: every mapping under
    /// test reads the envelope type (and a CANCEL's reason), never a hash or a MAC.
    private func wire(_ type: String, cancelReason: String = "user_cancelled") -> String {
        let id = V2IdentityBridge.identity(userId: userA, from: makeStoredIdentity())!
        let b64 = Base64Url.encode(V2Suite.sha256(V2Suite.utf8(type)))
        let p = params(id)
        let built: String?
        switch type {
        case "INVITE":
            built = V2Messages.buildInvite(p, V2Messages.InviteBody(intent: "new", identityPk: b64, ephemeralPk: b64, encapsulationPk: b64, targetUser: userB, challenge: b64))
        case "ACCEPT":
            built = V2Messages.buildAccept(p, V2Messages.AcceptBody(inviteHash: b64, identityPk: b64, ephemeralPk: b64, encapsulationPk: b64, challenge: b64))
        case "SELECT":
            built = V2Messages.buildSelect(p, V2Messages.SelectBody(inviteHash: b64, acceptHash: b64, transcriptHash: b64, macA: b64))
        case "CONFIRM":
            built = V2Messages.buildConfirm(p, V2Messages.ConfirmBody(selectHash: b64, transcriptHash: b64, macB: b64))
        case "READY":
            built = V2Messages.buildReady(p, V2Messages.ReadyBody(selectHash: b64, transcriptHash: b64, macReady: b64))
        case "CANCEL":
            built = V2Messages.buildCancel(p, V2Messages.CancelBody(targetTxnId: p.txnId ?? "", reason: cancelReason))
        case "UNPAIR":
            built = V2Messages.buildUnpair(p, V2Messages.UnpairBody(bindingId: b64))
        case "ROSTER_COMMIT":
            built = V2Messages.buildRosterCommit(p, V2Messages.RosterCommitBody(reason: "rekey", bindingId: b64, epoch: "2", deviceRoster: [b64], packages: [], newDevice: nil))
        case "MERGE":
            built = V2Messages.buildMerge(p, V2Messages.MergeBody(inviteHashA: b64, inviteHashB: b64, mainTxnId: p.txnId ?? ""))
        case "BUSY":
            built = V2Messages.buildBusy(p, V2Messages.BusyBody(mainTxnId: p.txnId ?? "", reason: "busy"))
        default:
            built = nil
        }
        guard let built else {
            XCTFail("could not build \(type)")
            return ""
        }
        XCTAssertEqual(V2Envelope.parse(prefix: V2Messages.prefix, text: built)?.type, type)
        return built
    }

    // MARK: I5 — own echoes

    func testOwnEchoLineMapsEveryP2TypeLikeAndroid() {
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("INVITE")), .inviteSent)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("ACCEPT")), .handshake)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("SELECT")), .handshake)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("CONFIRM")), .handshake)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("MERGE")), .handshake)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("BUSY")), .handshake)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("READY")), .readySent)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("UNPAIR")), .unpairedByYou)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("ROSTER_COMMIT")), .rotatedByYou)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("CANCEL", cancelReason: "user_cancelled")), .cancelled)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("CANCEL", cancelReason: "expired")), .cancelled)
        // The reset button's CANCEL reads exactly like this device's own unpair.
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(wire("CANCEL", cancelReason: "user_reset")), .unpairedByYou)
    }

    func testOwnEchoLineOfAMalformedOrForeignTextIsIgnoredNeverEmpty() {
        XCTAssertEqual(V2PairingDispatch.ownEchoLine("P2:"), .ignored)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine("P2:not-base64-json"), .ignored)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine("P1:1:a:b:c"), .ignored)
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(""), .ignored)
        // A truncated envelope no longer parses at all.
        let invite = wire("INVITE")
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(String(invite.dropLast(2))), .ignored)
    }

    func testTheDetailOfEveryLineIsNeverEmptyAndOnlyTheTwoLegacyEchoesKeepTheirShape() {
        XCTAssertEqual(V2PairingLine.unpairedByYou.detail, "unpair:own_echo")
        XCTAssertEqual(V2PairingLine.rotatedByYou.detail, "v2rekey:own_echo")
        XCTAssertEqual(V2PairingLine.inviteSent.detail, "v2line:invite_sent")
        XCTAssertEqual(V2PairingLine.handshake.detail, "v2line:handshake")
        XCTAssertEqual(V2PairingLine.readySent.detail, "v2line:ready_sent")
        XCTAssertEqual(V2PairingLine.cancelled.detail, "v2line:cancelled")
        XCTAssertEqual(V2PairingLine.peerBusy.detail, "v2line:peer_busy")
        XCTAssertEqual(V2PairingLine.ignored.detail, "v2line:ignored")
        let details = V2PairingLine.allCases.map { $0.detail }
        XCTAssertEqual(Set(details).count, details.count, "two lines may never share a detail")
        for line in V2PairingLine.allCases where line != .unpairedByYou && line != .rotatedByYou {
            XCTAssertEqual(V2PairingLine(rawValue: String(line.detail.dropFirst(V2PairingLine.detailKind.count + 1))), line)
        }
    }

    // MARK: I5 — received steps

    func testReceivedProgressLineIsCancelledOnlyForAPlainCancel() {
        XCTAssertEqual(V2PairingDispatch.receivedProgressLine(wire("CANCEL", cancelReason: "user_cancelled")), .cancelled)
        XCTAssertEqual(V2PairingDispatch.receivedProgressLine(wire("ACCEPT")), .handshake)
        XCTAssertEqual(V2PairingDispatch.receivedProgressLine(wire("SELECT")), .handshake)
        XCTAssertEqual(V2PairingDispatch.receivedProgressLine(wire("CONFIRM")), .handshake)
        XCTAssertEqual(V2PairingDispatch.receivedProgressLine(wire("INVITE")), .handshake)
        // A reset is rendered by the caller as the peer unpairing; this function never calls it "cancelled".
        XCTAssertNotEqual(V2PairingDispatch.receivedProgressLine(wire("CANCEL", cancelReason: "user_reset")), .cancelled)
        XCTAssertTrue(V2PairingDispatch.isResetCancel(wire("CANCEL", cancelReason: "user_reset")))
        XCTAssertFalse(V2PairingDispatch.isResetCancel(wire("CANCEL", cancelReason: "user_cancelled")))
        XCTAssertFalse(V2PairingDispatch.isResetCancel(wire("UNPAIR")))
    }

    func testIgnoredLineNamesAPeersMergeAndBusyAndSendsOwnEchoesToTheEchoMapping() {
        XCTAssertEqual(V2PairingDispatch.ignoredLine(reason: "merge", wire: wire("MERGE")), .handshake)
        XCTAssertEqual(V2PairingDispatch.ignoredLine(reason: "busy", wire: wire("BUSY")), .peerBusy)
        XCTAssertEqual(V2PairingDispatch.ignoredLine(reason: "unknown", wire: "P2:x"), .ignored)
        XCTAssertEqual(V2PairingDispatch.ignoredLine(reason: "own_echo:invite", wire: wire("INVITE")), .inviteSent)
        XCTAssertEqual(V2PairingDispatch.ignoredLine(reason: "own_echo:ready", wire: wire("READY")), .readySent)
        XCTAssertEqual(V2PairingDispatch.ignoredLine(reason: "own_echo:unpair", wire: wire("UNPAIR")), .unpairedByYou)
    }

    /// Every wire a real pairing produces, on both sides, maps to a line — as the sender's echo and as the
    /// receiver's step. Nothing in a real exchange is `.ignored`, so nothing renders as "已忽略".
    func testEveryWireOfARealPairingHasARealLineOnBothSides() {
        makeRuntime(userId: userA, key: keyA)
        makeRuntime(userId: userB, key: keyB)
        guard case .sent(let invite) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: chatA, targetUser: userB) else {
            return XCTFail("startPairing did not send")
        }
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(invite), .inviteSent)
        guard case .invited(_, _, let cached) = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chatB, wireText: invite, isOutgoing: false),
              case .sent(let accept) = V2PairingDispatch.acceptInvite(accountKey: keyB, chatId: chatB, inviteWire: cached) else {
            return XCTFail("B could not accept")
        }
        var queue: [(to: String, chat: String, wire: String)] = [(keyA, chatA, accept)]
        var echoes: [V2PairingLine] = [V2PairingDispatch.ownEchoLine(accept)]
        var steps = 0
        while let next = queue.first, steps < 10 {
            queue.removeFirst()
            steps += 1
            // The sender's own copy of the same wire, which never reaches a processor.
            XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: next.to == keyA ? keyB : keyA, chatId: next.to == keyA ? chatB : chatA,
                                                            wireText: next.wire, isOutgoing: true),
                           .ignored(reason: "own_echo:\(V2Envelope.parse(prefix: V2Messages.prefix, text: next.wire)!.type.lowercased())"))
            let outcome = V2PairingDispatch.handleIncoming(accountKey: next.to, chatId: next.chat, wireText: next.wire, isOutgoing: false)
            guard case .progressed(let reply) = outcome else { return XCTFail("expected .progressed, got \(outcome)") }
            XCTAssertEqual(V2PairingDispatch.receivedProgressLine(next.wire), .handshake)
            if let reply {
                echoes.append(V2PairingDispatch.ownEchoLine(reply))
                queue.append(next.to == keyA ? (keyB, chatB, reply) : (keyA, chatA, reply))
            }
        }
        XCTAssertEqual(echoes, [.handshake, .handshake, .handshake, .readySent], "ACCEPT, SELECT, CONFIRM, READY")
        XCTAssertEqual(V2PairingStatus.of(accountKey: keyA, chatId: chatA).pairingState, "paired")
        XCTAssertEqual(V2PairingStatus.of(accountKey: keyB, chatId: chatB).pairingState, "paired")
    }

    // MARK: I1 — v2-first status

    private func v2(_ state: String?, verified: Bool = false, invite: Bool = false) -> V2PairingStatus {
        return V2PairingStatus(pairingState: state, verified: verified, hasIncomingInvite: invite, safetyCode: state == "paired" ? "123456" : nil)
    }

    func testAV2BindingWinsOverALeftoverV1InvitedAndTheLeftoverIsFlagged() {
        let resolved = V2PairingStatus.resolve(v2("paired", verified: true), v1State: "invited", v1Verified: false)
        XCTAssertEqual(resolved, V2PairingStatus.Resolved(source: .v2, pairingState: "paired", verified: true, hasIncomingInvite: false, hasResidualV1Pairing: true))
    }

    func testEveryV2StateWinsOverEveryV1State() {
        for v2State in ["paired", "invited", "other_device"] {
            for v1State: String? in [nil, "invited", "paired", "key_changed", "other_device"] {
                let resolved = V2PairingStatus.resolve(v2(v2State), v1State: v1State, v1Verified: true)
                XCTAssertEqual(resolved.source, .v2)
                XCTAssertEqual(resolved.pairingState, v2State, "v2 \(v2State) / v1 \(v1State ?? "nil")")
                XCTAssertFalse(resolved.verified, "the verified flag is v2's own, never the v1 leftover's")
                XCTAssertEqual(resolved.hasResidualV1Pairing, v1State != nil)
            }
        }
    }

    func testAPendingV2InviteAloneCountsAsV2StateAndIsTheOnlyIncomingInvite() {
        let resolved = V2PairingStatus.resolve(v2(nil, invite: true), v1State: "key_changed", v1Verified: false)
        XCTAssertEqual(resolved, V2PairingStatus.Resolved(source: .v2, pairingState: nil, verified: false, hasIncomingInvite: true, hasResidualV1Pairing: true))
        XCTAssertTrue(v2(nil, invite: true).hasAnyState)
        XCTAssertFalse(V2PairingStatus.none.hasAnyState)
    }

    func testWithNothingInV2OnlyARealV1PairedChatStillReadsPaired() {
        XCTAssertEqual(V2PairingStatus.resolve(.none, v1State: "paired", v1Verified: true),
                       V2PairingStatus.Resolved(source: .v1, pairingState: "paired", verified: true, hasIncomingInvite: false, hasResidualV1Pairing: false))
        for leftover in ["invited", "key_changed", "other_device"] {
            XCTAssertEqual(V2PairingStatus.resolve(.none, v1State: leftover, v1Verified: true),
                           V2PairingStatus.Resolved(source: .none, pairingState: nil, verified: false, hasIncomingInvite: false, hasResidualV1Pairing: true),
                           "a v1 \(leftover) is a leftover: no state, offer 〔自动配对〕")
        }
        XCTAssertEqual(V2PairingStatus.resolve(.none, v1State: nil, v1Verified: false),
                       V2PairingStatus.Resolved(source: .none, pairingState: nil, verified: false, hasIncomingInvite: false, hasResidualV1Pairing: false))
    }

    /// The report itself, through real runtimes: paired over v2 with a leftover v1 "invited" on file reads
    /// paired; once the peer unpairs over v2 it reads as nothing (not 等待对方同意) with the leftover flagged.
    func testTheReportedDevicesReadPairedThenNothingDespiteTheV1Leftover() {
        makeRuntime(userId: userA, key: keyA)
        makeRuntime(userId: userB, key: keyB)
        guard case .sent(let invite) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: chatA, targetUser: userB),
              case .invited(_, _, let cached) = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chatB, wireText: invite, isOutgoing: false),
              case .sent(let accept) = V2PairingDispatch.acceptInvite(accountKey: keyB, chatId: chatB, inviteWire: cached),
              case .progressed(let select?) = V2PairingDispatch.handleIncoming(accountKey: keyA, chatId: chatA, wireText: accept, isOutgoing: false),
              case .progressed(let confirm?) = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chatB, wireText: select, isOutgoing: false),
              case .progressed(let ready?) = V2PairingDispatch.handleIncoming(accountKey: keyA, chatId: chatA, wireText: confirm, isOutgoing: false),
              case .progressed = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chatB, wireText: ready, isOutgoing: false) else {
            return XCTFail("the pairing did not complete")
        }
        let paired = V2PairingStatus.resolve(V2PairingStatus.of(accountKey: keyB, chatId: chatB), v1State: "invited", v1Verified: false)
        XCTAssertEqual(paired.source, .v2)
        XCTAssertEqual(paired.pairingState, "paired")
        XCTAssertTrue(paired.hasResidualV1Pairing)

        guard case .sent(let unpair) = V2PairingDispatch.unpair(accountKey: keyA, chatId: chatA) else { return XCTFail("A could not unpair") }
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(unpair), .unpairedByYou)
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chatB, wireText: unpair, isOutgoing: false), .progressed(wire: nil))
        let after = V2PairingStatus.resolve(V2PairingStatus.of(accountKey: keyB, chatId: chatB), v1State: "invited", v1Verified: false)
        XCTAssertEqual(after, V2PairingStatus.Resolved(source: .none, pairingState: nil, verified: false, hasIncomingInvite: false, hasResidualV1Pairing: true))
    }

    // MARK: I2 — 〔在本机重新配对〕 after a CONFLICT

    func testAConflictedChatCanStartAFreshInviteOnceItsLocalConflictIsDropped() {
        let chat = "4200"
        let a = makeRuntime(userId: userA, key: keyA)
        let b = makeRuntime(userId: userB, key: keyB)
        guard case .sent(let inviteWire) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: chat, targetUser: userB),
              case .invited(_, _, let cachedWire) = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chat, wireText: inviteWire, isOutgoing: false),
              case .sent(let acceptWire) = V2PairingDispatch.acceptInvite(accountKey: keyB, chatId: chat, inviteWire: cachedWire),
              case .progressed(let selectWire?) = V2PairingDispatch.handleIncoming(accountKey: keyA, chatId: chat, wireText: acceptWire, isOutgoing: false),
              case .progressed = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chat, wireText: selectWire, isOutgoing: false) else {
            return XCTFail("setup did not reach SELECT")
        }
        // A second, validly signed SELECT for the same txn: TEST_MATRIX P-17's CONFLICT (see V2PairingDispatchTests).
        let parsedSelect = V2Messages.parseSelect(selectWire)!
        let secondSelect = V2Messages.buildSelect(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: parsedSelect.envelope.txnId, chatId: chat, actorUser: userA,
            actorIdentityPk: a.identity.publicKey, actorIdentitySk: a.identity.secretKey,
            parentBinding: nil, createdMs: parsedSelect.envelope.createdMs, expiresMs: parsedSelect.envelope.expiresMs
        ), parsedSelect.body)!
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chat, wireText: secondSelect, isOutgoing: false), .conflict)
        XCTAssertEqual(V2PairingStatus.of(b, chatId: chat).pairingState, "other_device")
        XCTAssertNotNil(b.pairing.currentTransactionForChat(chat), "CONFLICT still blocks a fresh INVITE")
        // The reset button's sweep leaves CONFLICT alone on purpose; this is the dedicated way out.
        XCTAssertTrue(b.pairing.cancelAllForChat(chat).isEmpty)

        XCTAssertEqual(b.pairing.dropConflictsForChat(chat), 1)
        XCTAssertNil(b.pairing.currentTransactionForChat(chat))
        XCTAssertEqual(V2PairingStatus.of(b, chatId: chat), .none)
        XCTAssertEqual(b.pairing.dropConflictsForChat(chat), 0, "idempotent")
        guard case .sent(let fresh) = V2PairingDispatch.startPairing(accountKey: keyB, chatId: chat, targetUser: userA) else {
            return XCTFail("a fresh INVITE must go out once the CONFLICT is dropped")
        }
        XCTAssertEqual(V2PairingDispatch.ownEchoLine(fresh), .inviteSent)
        XCTAssertEqual(V2PairingStatus.of(b, chatId: chat).pairingState, "invited")
    }

    func testDropConflictsLeavesAnInFlightExchangeAlone() {
        let a = makeRuntime(userId: userA, key: keyA)
        guard case .sent = V2PairingDispatch.startPairing(accountKey: keyA, chatId: chatA, targetUser: userB) else { return XCTFail("no INVITE") }
        XCTAssertEqual(a.pairing.dropConflictsForChat(chatA), 0)
        XCTAssertNotNil(a.pairing.currentTransactionForChat(chatA))
    }

    // MARK: self-healing after the identity was replaced (addendum 2)

    private final class Clock {
        var ms: Int64 = 1_700_000_000_000
    }

    private func newV2Identity(_ userId: String) -> V2Identity {
        return V2IdentityBridge.identity(userId: userId, from: makeStoredIdentity())!
    }

    /// Delivers each wire to the other side through the dispatch layer and relays every automatic reply.
    private func pump(_ first: (to: String, chat: String, wire: String)) {
        var queue = [first]
        var hops = 0
        while !queue.isEmpty, hops < 12 {
            let next = queue.removeFirst()
            hops += 1
            let outcome = V2PairingDispatch.handleIncoming(accountKey: next.to, chatId: next.chat, wireText: next.wire, isOutgoing: false)
            guard case .progressed(let reply) = outcome else { return XCTFail("expected .progressed, got \(outcome)") }
            if let reply { queue.append(next.to == keyA ? (keyB, chatB, reply) : (keyA, chatA, reply)) }
        }
    }

    /// A invites B over the dispatch layer, B accepts, and every later hop is pumped until both are bound.
    private func pairThroughDispatch() {
        guard case .sent(let invite) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: chatA, targetUser: userB),
              case .invited(_, _, let cached) = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chatB, wireText: invite, isOutgoing: false),
              case .sent(let accept) = V2PairingDispatch.acceptInvite(accountKey: keyB, chatId: chatB, inviteWire: cached) else {
            return XCTFail("the pairing did not start")
        }
        pump((keyA, chatA, accept))
    }

    /// The video: 〔重新生成密钥并重新配对〕 replaced A's identity, and after the restart every E2 on A's v2 bindings
    /// failed with bad_signature. Rebuilding A's runtime over the same persisted state with the NEW identity must
    /// drop the binding that no longer names A (history kept), leave A with no state and not on v2 — and then the
    /// ordinary road back works: A invites, B (still bound to A's old key) is offered the newer invite, accepts,
    /// and E2 from the rebuilt A opens on B.
    func testABindingInstalledUnderAReplacedIdentityIsDroppedAndThePairRecoversThroughANewInvite() {
        let clock = Clock()
        let now: () -> Int64 = { clock.ms }
        let storageA = V2MemoryStorage()
        let a = V2Runtime(identity: newV2Identity(userA), persisted: V2PersistedState.load(storage: storageA), now: now)
        let b = V2Runtime(identity: newV2Identity(userB), persisted: V2PersistedState.load(storage: V2MemoryStorage()), now: now)
        V2RuntimeRegistry.shared.set(a, for: keyA)
        V2RuntimeRegistry.shared.set(b, for: keyB)
        pairThroughDispatch()
        guard let oldA = a.pairing.bindingStore.current(chatA), let oldB = b.pairing.bindingStore.current(chatB) else {
            return XCTFail("not paired")
        }
        XCTAssertEqual(oldA.bindingId, oldB.bindingId)
        XCTAssertEqual(a.pairing.dropBindingsWithoutOwnIdentity(), [], "a binding that names this device is never dropped")
        a.persisted.persist()

        // The restart after the identity was replaced: same persisted state, new keys.
        clock.ms += 1_000
        let a2 = V2Runtime(identity: newV2Identity(userA), persisted: V2PersistedState.load(storage: storageA), now: now)
        V2RuntimeRegistry.shared.set(a2, for: keyA)
        XCTAssertNil(a2.pairing.bindingStore.current(chatA), "the binding naming A's old device is dropped")
        XCTAssertTrue(a2.pairing.bindingStore.historical(chatA).contains { $0.bindingId == oldA.bindingId }, "history stays")
        XCTAssertEqual(V2PairingStatus.of(accountKey: keyA, chatId: chatA), .none)
        XCTAssertEqual(V2Dispatch.prepareOutgoingText(accountKey: keyA, chatId: chatA, text: "not on v2 any more"), .notOnV2)
        XCTAssertEqual(a2.pairing.dropBindingsWithoutOwnIdentity(), [], "idempotent")
        // The drop was persisted: a further restart with the same new keys finds nothing to drop and no binding.
        XCTAssertNil(V2PersistedState.load(storage: storageA).bindingStore.current(chatA))

        // B knows nothing of it and still speaks the old binding.
        XCTAssertEqual(b.pairing.bindingStore.current(chatB)?.bindingId, oldB.bindingId)

        // A short while later A pairs afresh.
        clock.ms += 1_000
        guard case .sent(let invite) = V2PairingDispatch.startPairing(accountKey: keyA, chatId: chatA, targetUser: userB) else {
            return XCTFail("the rebuilt A could not invite")
        }
        // PLAN.md 3.43: A's replaced identity is not in B's binding roster, so B is offered the key-changed variant —
        // cached and accepted exactly like an ordinary invite, nothing adopted until B accepts.
        guard case .invitedKeyChanged(_, _, let cached, _, _) = V2PairingDispatch.handleIncoming(accountKey: keyB, chatId: chatB, wireText: invite, isOutgoing: false) else {
            return XCTFail("B was not offered the invite")
        }
        let offered = V2PairingStatus.of(accountKey: keyB, chatId: chatB)
        XCTAssertEqual(offered.pairingState, "paired")
        XCTAssertTrue(offered.hasIncomingInvite, "newer than B's binding, so it is offered")
        guard case .sent(let accept) = V2PairingDispatch.acceptInvite(accountKey: keyB, chatId: chatB, inviteWire: cached) else {
            return XCTFail("B could not accept")
        }
        pump((keyA, chatA, accept))
        guard let newA = a2.pairing.bindingStore.current(chatA), let newB = b.pairing.bindingStore.current(chatB) else {
            return XCTFail("the fresh pairing did not complete")
        }
        XCTAssertEqual(newA.bindingId, newB.bindingId)
        XCTAssertNotEqual(newB.bindingId, oldB.bindingId)
        guard case .sent(let e2) = V2Dispatch.prepareOutgoingText(accountKey: keyA, chatId: chatA, text: "hello from the new keys") else {
            return XCTFail("A is not on v2 after re-pairing")
        }
        XCTAssertEqual(V2Dispatch.decryptIncomingText(accountKey: keyB, chatId: chatB, wireText: e2), .decrypted(text: "hello from the new keys"))
    }

    // MARK: I4 — a v1 U1 with nothing to unpair

    private struct V1Peer {
        let userId: String
        let ring: KeyRing
        let processor: RekeyProcessor
    }

    private func makeV1Peer(_ userId: String) throws -> V1Peer {
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { vectorNowMs }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        return V1Peer(userId: userId, ring: ring, processor: RekeyProcessor(ring: ring, clock: { vectorNowMs }))
    }

    private func u1(from peer: V1Peer) throws -> String {
        return try Rekey.buildU1(userId: peer.userId, at: 1_789_000_060, ed25519Sk: peer.ring.identity!.ed25519Sk)
    }

    func testAU1ForAChatWithNoPairingIsNothingToUnpair() throws {
        let ios = try makeV1Peer(userB)
        let android = try makeV1Peer(userA)
        let result = ios.processor.handle(text: try u1(from: android), chatId: userA, senderId: userA, ownUserId: userB)
        XCTAssertEqual(result?.isUnpair, true)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "not_paired_peer")
        XCTAssertTrue(RekeyProcessor.isNothingToUnpair(result?.reason ?? ""))
    }

    /// The report: a leftover v1 "invited" that never learned the peer's signing key.
    func testAU1AgainstALeftoverV1InvitedIsNothingToUnpairAndChangesNothing() throws {
        let ios = try makeV1Peer(userB)
        let android = try makeV1Peer(userA)
        _ = try ios.processor.startPairing(chatId: userA, peerId: userA)
        XCTAssertEqual(ios.ring.chatPairing(userA)?.state, .invited)
        let result = ios.processor.handle(text: try u1(from: android), chatId: userA, senderId: userA, ownUserId: userB)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "no_peer_key")
        XCTAssertTrue(RekeyProcessor.isNothingToUnpair(result?.reason ?? ""))
        XCTAssertEqual(ios.ring.chatPairing(userA)?.state, .invited, "a refused notice leaves the keyring as it was")
    }

    func testGenuineU1RefusalsAreNotNothingToUnpair() {
        for reason in ["bad_signature", "sender_mismatch", "stale", "no_sender", "not_private", "malformed", "ok", "own_echo", ""] {
            XCTAssertFalse(RekeyProcessor.isNothingToUnpair(reason), reason)
        }
    }
}
