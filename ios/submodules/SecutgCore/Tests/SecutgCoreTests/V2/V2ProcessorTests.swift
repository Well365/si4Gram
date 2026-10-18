import XCTest
@testable import SecutgCore

/// Ported from Android's `ProcessorTest.java` — P-01 through P-11 happy path and the signature/MAC/
/// replay failure points, plus P-12/P-16/P-17 concurrency rows.
final class V2ProcessorTests: XCTestCase {
    private let chat = "4200"
    private let targetUser = "200"

    private func makeIdentity(_ userId: String) -> V2Identity {
        let ed = V2Suite.generateEd25519()
        let enc = V2Suite.generateX25519()
        return V2Identity(userId: userId, publicKey: ed.publicKey, secretKey: ed.secretKey, encapsulationPk: enc.publicKey, encapsulationSk: enc.secretKey)
    }

    private final class Pair {
        let aIdentity: V2Identity
        let bIdentity: V2Identity
        let a: V2Processor.PairingProcessor
        let b: V2Processor.PairingProcessor
        let clockBox: Box<Int64>

        init(makeIdentity: (String) -> V2Identity) {
            aIdentity = makeIdentity("100")
            bIdentity = makeIdentity("200")
            let clockBox = Box<Int64>(1_000_000)
            a = V2Processor.PairingProcessor(identity: aIdentity, now: { clockBox.value })
            b = V2Processor.PairingProcessor(identity: bIdentity, now: { clockBox.value })
            self.clockBox = clockBox
        }

        func advanceClock(by ms: Int64) {
            clockBox.value += ms
        }
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private struct Completed {
        var aTxnId: String = ""
        var bTxnId: String = ""
        var master: [UInt8] = []
    }

    @discardableResult
    private func runHappyPath(_ p: Pair) -> Completed {
        var out = Completed()
        let invite = p.a.startPairing(chat, targetUser)!
        out.aTxnId = invite.txnId

        let inviteSeenByB = p.b.handleInvite(invite.wire)
        XCTAssertTrue(inviteSeenByB.ok)
        XCTAssertEqual(inviteSeenByB.targetUser, targetUser)

        let accept = p.b.acceptInvite(invite.wire)
        XCTAssertEqual(accept.kind, "accept")
        out.bTxnId = accept.txnId!

        let select = p.a.handleAccept(accept.wire!)
        XCTAssertTrue(select.ok, "handleAccept failed: \(select.reason ?? "")")
        XCTAssertEqual(select.kind, "select_sent")

        let confirm = p.b.handleSelect(select.wire!)
        XCTAssertTrue(confirm.ok, "handleSelect failed: \(confirm.reason ?? "")")
        XCTAssertEqual(confirm.kind, "confirm_sent")

        let ready = p.a.handleConfirm(confirm.wire!)
        XCTAssertTrue(ready.ok, "handleConfirm failed: \(ready.reason ?? "")")
        XCTAssertEqual(ready.kind, "ready_sent")
        XCTAssertNotNil(ready.master)

        let complete = p.b.handleReady(ready.wire!)
        XCTAssertTrue(complete.ok, "handleReady failed: \(complete.reason ?? "")")
        XCTAssertEqual(complete.kind, "complete")
        XCTAssertEqual(ready.master, complete.master)

        out.master = ready.master!
        return out
    }

    func testP01FullFiveStepExchangeCompletesOnBothSidesWithTheSameMaster() {
        let p = Pair(makeIdentity: makeIdentity)
        let done = runHappyPath(p)
        XCTAssertEqual(p.a.phaseOf(done.aTxnId), .done)
        XCTAssertEqual(p.b.phaseOf(done.bTxnId), .done)
    }

    func testP02CompletionInstallsAUsableBindingOnBothSides() {
        let p = Pair(makeIdentity: makeIdentity)
        runHappyPath(p)
        XCTAssertTrue(p.a.canSend(chat))
        XCTAssertTrue(p.b.canSend(chat))
        XCTAssertNotNil(p.a.bindingStore.current(chat))
        XCTAssertEqual(p.a.bindingStore.current(chat)?.bindingId, p.b.bindingStore.current(chat)?.bindingId)
    }

    func testP06SafetyCodeAgreesOnBothSidesForTheSameTransaction() {
        let p = Pair(makeIdentity: makeIdentity)
        let done = runHappyPath(p)
        let aCode = p.a.getSafetyCode(done.aTxnId)
        let bCode = p.b.getSafetyCode(done.bTxnId)
        XCTAssertNotNil(aCode)
        XCTAssertNotNil(bCode)
        XCTAssertEqual(aCode!.fingerprint, bCode!.fingerprint)
        XCTAssertEqual(aCode!.shortCode, bCode!.shortCode)
        XCTAssertEqual(aCode!.shortCode.count, 12)
    }

    func testP07BadSignatureOnSelectIsRejectedByB() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let accept = p.b.acceptInvite(invite.wire)
        let select = p.a.handleAccept(accept.wire!)
        let tampered = String(select.wire!.dropLast(4)) + "AAAA"
        let confirm = p.b.handleSelect(tampered)
        XCTAssertFalse(confirm.ok)
    }

    func testP08BadMacAOnSelectIsRejectedByB() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let accept = p.b.acceptInvite(invite.wire)

        let inviteHash = V2Messages.hashWire(invite.wire)
        let acceptHash = V2Messages.hashWire(accept.wire!)
        let input = V2Transcript.Input(
            chatId: chat, txnId: invite.txnId, parentBinding: nil, initiatorUser: "100",
            initiatorDevice: Base64Url.encode(V2Suite.sha256(p.aIdentity.publicKey)), responderUser: targetUser,
            responderDevice: Base64Url.encode(V2Suite.sha256(p.bIdentity.publicKey)),
            inviteHash: Base64Url.encode(inviteHash), acceptHash: Base64Url.encode(acceptHash)
        )
        let transcriptHash = V2Transcript.computeTranscriptHash(input)!
        let forgedMacA = [UInt8](repeating: 0, count: 32)
        let forgedSelect = V2Messages.buildSelect(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: invite.txnId, chatId: chat, actorUser: "100", actorIdentityPk: p.aIdentity.publicKey,
            actorIdentitySk: p.aIdentity.secretKey, parentBinding: nil, createdMs: "1000000", expiresMs: "1600000"
        ), V2Messages.SelectBody(
            inviteHash: Base64Url.encode(inviteHash), acceptHash: Base64Url.encode(acceptHash),
            transcriptHash: Base64Url.encode(transcriptHash), macA: Base64Url.encode(forgedMacA)
        ))
        XCTAssertNotNil(forgedSelect)
        let confirm = p.b.handleSelect(forgedSelect!)
        XCTAssertFalse(confirm.ok)
        XCTAssertEqual(confirm.reason, "bad_mac")
    }

    func testP09BadMacBOnConfirmIsRejectedByA() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let accept = p.b.acceptInvite(invite.wire)
        let select = p.a.handleAccept(accept.wire!)
        let confirm = p.b.handleSelect(select.wire!)
        let tampered = String(confirm.wire!.dropLast(4)) + "BBBB"
        let ready = p.a.handleConfirm(tampered)
        XCTAssertFalse(ready.ok)
    }

    func testP10BadMacReadyOnReadyIsRejectedByB() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let accept = p.b.acceptInvite(invite.wire)
        let select = p.a.handleAccept(accept.wire!)
        let confirm = p.b.handleSelect(select.wire!)
        let ready = p.a.handleConfirm(confirm.wire!)
        let tampered = String(ready.wire!.dropLast(4)) + "CCCC"
        let complete = p.b.handleReady(tampered)
        XCTAssertFalse(complete.ok)
    }

    func testP11AnInviteExpiredBeforeAcceptIsRejected() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        p.advanceClock(by: 11 * 60 * 1000) // past the 10-minute default TTL
        let accept = p.b.acceptInvite(invite.wire)
        XCTAssertEqual(accept.kind, "expired")
    }

    func testReplayOfAcceptAfterSelectAlreadySentReturnsTheSameSelectWire() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let accept = p.b.acceptInvite(invite.wire)
        let firstSelect = p.a.handleAccept(accept.wire!)
        let replaySelect = p.a.handleAccept(accept.wire!)
        XCTAssertTrue(replaySelect.ok)
        XCTAssertEqual(replaySelect.kind, "replay")
        XCTAssertEqual(firstSelect.wire, replaySelect.wire)
    }

    func testReplayOfReadyAfterCompleteReturnsAlreadyComplete() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let accept = p.b.acceptInvite(invite.wire)
        let select = p.a.handleAccept(accept.wire!)
        let confirm = p.b.handleSelect(select.wire!)
        let ready = p.a.handleConfirm(confirm.wire!)
        let firstComplete = p.b.handleReady(ready.wire!)
        XCTAssertTrue(firstComplete.ok)
        XCTAssertEqual(firstComplete.kind, "complete")

        let replayComplete = p.b.handleReady(ready.wire!)
        XCTAssertTrue(replayComplete.ok)
        XCTAssertEqual(replayComplete.kind, "already_complete")
        XCTAssertEqual(firstComplete.master, replayComplete.master)
    }

    func testCancelledTxnRejectsAnyFurtherMessageForIt() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let accept = p.b.acceptInvite(invite.wire)
        let cancelWire = p.a.cancelPairing(txnId: invite.txnId, reason: "user_cancelled")
        XCTAssertNotNil(cancelWire)
        let cancelledOnB = p.b.handleCancel(cancelWire!)
        XCTAssertTrue(cancelledOnB.ok)
        let select = p.a.handleAccept(accept.wire!)
        XCTAssertFalse(select.ok)
        XCTAssertEqual(select.reason, "cancelled")
    }

    /// Fix E1 (P-25/P-29): "this device restarted while an exchange was in flight" — the exact
    /// scenario this class's own module doc (`PairingProcessor`'s injectable `pendingStore`
    /// constructor) says is testable this way, but which no test exercised until now, because
    /// `PendingTxn`/`InMemoryTxnStore` had no snapshot support at all before this fix. Builds ONE
    /// `PairingProcessor` over a fresh `InMemoryTxnStore`, starts pairing, snapshots that store (the
    /// "process about to die" moment), and constructs a SECOND, otherwise-independent
    /// `PairingProcessor` from the restored snapshot (the "process restarted, reloaded from disk"
    /// moment) — never touching the original, still-live instance again. The peer's ACCEPT, built
    /// against the pre-restart INVITE, must still resolve on the post-restart processor instead of
    /// "unknown_txn".
    func testP25P29ARestartMidPairingRestoresThePendingTransactionFromASnapshot() {
        let aIdentity = makeIdentity("100")
        let bIdentity = makeIdentity("200")
        let clockBox = Box<Int64>(1_000_000)

        let originalStore = V2Processor.InMemoryTxnStore()
        let aBeforeRestart = V2Processor.PairingProcessor(identity: aIdentity, now: { clockBox.value }, pendingStore: originalStore)
        let invite = aBeforeRestart.startPairing(chat, targetUser)!

        // The peer accepts only after A's process has already restarted — A's in-memory `pending`
        // from `aBeforeRestart` is gone by construction here (never referenced again below).
        let b = V2Processor.PairingProcessor(identity: bIdentity, now: { clockBox.value })
        let accept = b.acceptInvite(invite.wire)
        XCTAssertEqual(accept.kind, "accept")

        // "App restart": snapshot the store as it stood right after `startPairing`, then build a
        // brand-new `InMemoryTxnStore`/`PairingProcessor` pair from that snapshot alone.
        let snapshot = originalStore.toSnapshot()
        let restoredStore = V2Processor.InMemoryTxnStore.fromSnapshot(snapshot)
        XCTAssertEqual(restoredStore.get(invite.txnId)?.chatId, chat, "the pending INVITE txn must survive the round trip")
        let aAfterRestart = V2Processor.PairingProcessor(identity: aIdentity, now: { clockBox.value }, pendingStore: restoredStore)

        let select = aAfterRestart.handleAccept(accept.wire!)
        XCTAssertTrue(select.ok, "handleAccept failed after restart: \(select.reason ?? "")")
        XCTAssertNotEqual(select.reason, "unknown_txn")
        XCTAssertEqual(select.kind, "select_sent")
    }

    func testUnpairDeactivatesTheBindingOnBothSidesAndCanSendBecomesFalse() {
        let p = Pair(makeIdentity: makeIdentity)
        runHappyPath(p)
        let unpairWire = p.a.unpair(chat)
        XCTAssertNotNil(unpairWire)
        XCTAssertFalse(p.a.canSend(chat))
        let onB = p.b.handleUnpair(unpairWire!)
        XCTAssertTrue(onB.ok)
        XCTAssertFalse(p.b.canSend(chat))
    }

    func testP16TwoAcceptsForTheSameChatSlotOnlyOneWinsTheOtherGetsBusy() {
        let p = Pair(makeIdentity: makeIdentity)
        let otherInitiator = Pair(makeIdentity: makeIdentity)
        let inviteFromA = p.a.startPairing(chat, targetUser)!
        let inviteFromC = otherInitiator.a.startPairing(chat, targetUser)!

        let first = p.b.acceptInvite(inviteFromA.wire)
        XCTAssertEqual(first.kind, "accept")
        let second = p.b.acceptInvite(inviteFromC.wire)
        XCTAssertEqual(second.kind, "busy")
        XCTAssertEqual(first.txnId, second.txnId)
    }

    /// SECUTG-HOOK (feature, 2026-09-27, "一键恢复"): the real-device scenario behind `cancelAllForChat`
    /// — a chat stuck exactly like the busy test above, except nobody ever explicitly cancels the first
    /// (stuck) transaction, so every subsequent accept attempt keeps getting "busy" forever.
    /// `cancelAllForChat` is the escape hatch: cancel everything this device holds for the chat, in
    /// whichever role, and a fresh invite can be accepted normally again.
    func testCancelAllForChatFreesAChatSlotStuckForeverAsBusySoAFreshInviteCanBeAccepted() {
        let p = Pair(makeIdentity: makeIdentity)
        let otherInitiator = Pair(makeIdentity: makeIdentity)
        let inviteFromA = p.a.startPairing(chat, targetUser)!
        let stuck = p.b.acceptInvite(inviteFromA.wire)
        XCTAssertEqual(stuck.kind, "accept")
        XCTAssertEqual(p.b.phaseOf(stuck.txnId!), .selecting)

        // Nobody ever explicitly cancels `stuck` (peer vanished, app backgrounded) — every later accept
        // attempt for this chat is "busy" forever.
        let inviteFromC = otherInitiator.a.startPairing(chat, targetUser)!
        let stillBusy = p.b.acceptInvite(inviteFromC.wire)
        XCTAssertEqual(stillBusy.kind, "busy")
        XCTAssertEqual(stillBusy.txnId, stuck.txnId)

        let cancelWires = p.b.cancelAllForChat(chat)
        XCTAssertEqual(cancelWires.count, 1)

        let fresh = p.b.acceptInvite(inviteFromC.wire)
        XCTAssertEqual(fresh.kind, "accept")
        XCTAssertEqual(fresh.txnId, inviteFromC.txnId)
        XCTAssertEqual(p.b.currentTransactionForChat(chat), inviteFromC.txnId)
    }

    func testCancelAllForChatIsANoOpOnAChatWithNothingPendingAndOnlyCancelsTheGivenChat() {
        let p = Pair(makeIdentity: makeIdentity)
        XCTAssertTrue(p.a.cancelAllForChat(chat).isEmpty)

        let done = runHappyPath(p)
        // A DONE transaction is not "open" — cancelAllForChat must not touch a completed pairing.
        XCTAssertTrue(p.a.cancelAllForChat(chat).isEmpty)
        XCTAssertEqual(p.a.phaseOf(done.aTxnId), .done)

        let otherChat = "9999"
        let inviteOnOtherChat = p.a.startPairing(otherChat, targetUser)!
        XCTAssertTrue(p.a.cancelAllForChat(chat).isEmpty)
        XCTAssertEqual(p.a.phaseOf(inviteOnOtherChat.txnId), .invited)
    }

    func testP17TwoSimultaneousInvitesOnTheSameChatMergeToTheSmallerTxnId() {
        let p = Pair(makeIdentity: makeIdentity)
        let inviteA = p.a.startPairing(chat, targetUser)!
        // b now ALSO becomes an initiator for the same chat, racing a.
        let inviteFromB = p.b.startPairing(chat, "100")!
        let observedByB = p.b.handleInvite(inviteA.wire)
        XCTAssertTrue(observedByB.ok)
        let expectedMain = V2Processor.smallerTxnId(inviteA.txnId, inviteFromB.txnId)
        XCTAssertEqual(expectedMain, observedByB.mainTxnId)
        // SECUTG-HOOK (fix, 2026-09-27): only the WINNER answers with MERGE now. The loser accepts the
        // main invite as the responder (实施设计 v1.4 line 147) instead of emitting a MERGE nobody acts on.
        if expectedMain == inviteFromB.txnId {
            XCTAssertEqual(observedByB.kind, "merge_sent")
            XCTAssertEqual(p.b.phaseOf(inviteFromB.txnId), .invited, "the winner keeps its own INVITE open")
        } else {
            XCTAssertEqual(observedByB.kind, "merged_accept")
            XCTAssertNotNil(observedByB.wire.flatMap { V2Messages.parseAccept($0) })
            XCTAssertNil(p.b.phaseOf(inviteFromB.txnId), "the losing INVITE is dropped")
            XCTAssertEqual(p.b.phaseOf(inviteA.txnId), .selecting)
        }
    }

    /// SECUTG-HOOK (fix, 2026-09-27): crossed invites used to deadlock — the loser deleted its own txn
    /// and sent only a MERGE, nobody ever ACCEPTed, and the winner waited in INVITED forever. Both
    /// sides now see the other's INVITE; exactly one answers MERGE (the winner, whose txn is the smaller
    /// decoded txn_id) and the other ACCEPTs the winner's invite, and the ordinary five steps finish.
    func testCrossedInvitesTheLoserAcceptsTheMainInviteAndBothSidesBindWithTheSameCode() {
        let p = Pair(makeIdentity: makeIdentity)
        let inviteA = p.a.startPairing(chat, targetUser)!
        let inviteB = p.b.startPairing(chat, "100")!
        let main = V2Processor.smallerTxnId(inviteA.txnId, inviteB.txnId)
        let aWins = main == inviteA.txnId
        let winner = aWins ? p.a : p.b
        let loser = aWins ? p.b : p.a
        let winnerInvite = aWins ? inviteA : inviteB
        let loserInvite = aWins ? inviteB : inviteA

        let atWinner = winner.handleInvite(loserInvite.wire)
        XCTAssertTrue(atWinner.ok)
        XCTAssertEqual(atWinner.kind, "merge_sent")
        XCTAssertEqual(atWinner.mainTxnId, main)
        XCTAssertEqual(winner.phaseOf(winnerInvite.txnId), .invited)

        let atLoser = loser.handleInvite(winnerInvite.wire)
        XCTAssertTrue(atLoser.ok)
        XCTAssertEqual(atLoser.kind, "merged_accept")
        XCTAssertEqual(atLoser.mainTxnId, main)
        XCTAssertNil(loser.phaseOf(loserInvite.txnId), "the losing INVITE is dropped once the ACCEPT exists")
        guard let acceptWire = atLoser.wire, V2Messages.parseAccept(acceptWire) != nil else { return XCTFail("expected an ACCEPT wire") }

        let select = winner.handleAccept(acceptWire)
        XCTAssertEqual(select.kind, "select_sent", select.reason ?? "")
        let confirm = loser.handleSelect(select.wire!)
        XCTAssertEqual(confirm.kind, "confirm_sent", confirm.reason ?? "")
        let ready = winner.handleConfirm(confirm.wire!)
        XCTAssertEqual(ready.kind, "ready_sent", ready.reason ?? "")
        XCTAssertNotNil(winner.bindingStore.current(chat))
        let complete = loser.handleReady(ready.wire!)
        XCTAssertEqual(complete.kind, "complete", complete.reason ?? "")

        let winnerBinding = winner.bindingStore.current(chat)
        let loserBinding = loser.bindingStore.current(chat)
        XCTAssertNotNil(loserBinding)
        XCTAssertEqual(winnerBinding?.bindingId, loserBinding?.bindingId)
        XCTAssertEqual(winnerBinding?.txnId, main)
        XCTAssertEqual(ready.master, complete.master)
        let winnerCode = winner.getSafetyCode(main)?.shortCode
        XCTAssertNotNil(winnerCode)
        XCTAssertEqual(winnerCode, loser.getSafetyCode(main)?.shortCode)
        XCTAssertNil(winner.currentTransactionForChat(chat))
        XCTAssertNil(loser.currentTransactionForChat(chat))
    }

    /// SECUTG-HOOK (fix, 2026-09-27): a loser that cannot accept (here: this side already holds a
    /// cancelled tombstone for the winner's txn) keeps its own INVITE exactly as it was and says so,
    /// rather than dropping it for nothing.
    func testCrossedInviteLoserThatCannotAcceptKeepsItsOwnInviteUntouched() {
        let p = Pair(makeIdentity: makeIdentity)
        let inviteA = p.a.startPairing(chat, targetUser)!
        let inviteB = p.b.startPairing(chat, "100")!
        let aWins = V2Processor.smallerTxnId(inviteA.txnId, inviteB.txnId) == inviteA.txnId
        let loser = aWins ? p.b : p.a
        let winnerInvite = aWins ? inviteA : inviteB
        let loserInvite = aWins ? inviteB : inviteA
        loser.tombstoneStore.recordCancelled(txnId: winnerInvite.txnId, eventId: V2Envelope.randomId(), atMs: 1)

        let atLoser = loser.handleInvite(winnerInvite.wire)
        XCTAssertFalse(atLoser.ok)
        XCTAssertEqual(atLoser.reason, "merge_accept_failed")
        XCTAssertEqual(loser.phaseOf(loserInvite.txnId), .invited)
        XCTAssertNil(loser.phaseOf(winnerInvite.txnId))
    }

    /// SECUTG-HOOK (fix, 2026-09-27): an own INVITE nobody can accept any more (expired) must not win a
    /// crossed race — the peer's fresh invite is offered like any other instead, and accepting it works.
    func testAnExpiredOwnInviteDoesNotCountAsACrossedInvite() {
        let p = Pair(makeIdentity: makeIdentity)
        let staleA = p.a.startPairing(chat, targetUser)!
        p.advanceClock(by: 11 * 60 * 1000) // past the 10-minute default TTL
        XCTAssertTrue(p.a.isOwnInviteExpired(staleA.txnId))
        let freshB = p.b.startPairing(chat, "100")!

        let atA = p.a.handleInvite(freshB.wire)
        XCTAssertTrue(atA.ok)
        XCTAssertNil(atA.kind, "a plain offer — neither MERGE nor an automatic ACCEPT")
        XCTAssertNil(atA.wire)
        XCTAssertEqual(atA.targetUser, "100")
        XCTAssertEqual(p.a.acceptInvite(freshB.wire).kind, "accept")
    }

    func testSmallerTxnIdIsAStableTotalOrderOverTheTwoCandidates() {
        let one = "AAAAAAAAAAAAAAAAAAAAAA"
        let other = "BBBBBBBBBBBBBBBBBBBBBB"
        let winner1 = V2Processor.smallerTxnId(one, other)
        let winner2 = V2Processor.smallerTxnId(other, one)
        XCTAssertEqual(winner1, winner2)
        XCTAssertEqual(winner1, V2Processor.smallerTxnId(winner1, winner1))
    }
}
