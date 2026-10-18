import XCTest
@testable import SecutgCore

/// Adversarial / malformed-input coverage for the v2 pairing (P2) processor
/// (`Sources/SecutgCore/V2/Pairing/V2Processor.swift`) and its dispatch layer
/// (`Sources/SecutgCore/V2/Hooks/V2PairingDispatch.swift`), added alongside the happy-path +
/// protocol-failure-point coverage in `V2ProcessorTests` (P-01..P-17, ported from Android's
/// `ProcessorTest`, itself backed by `TEST_MATRIX.md`). None of the scenarios below are TEST_MATRIX
/// rows — they attack the fix-E1-era P2 layer the way a hostile peer or a corrupted transport would,
/// not the way the spec's own happy-path table already does:
/// 1. a forged message signed by the WRONG identity key impersonating a real party (UNPAIR/ACCEPT/
///    SELECT/CONFIRM),
/// 2. replay of an already-consumed, still-valid INVITE/ACCEPT long after the exchange finished,
/// 3. a single tampered protocol field (not just a corrupted signature tail like P-07..P-10 already
///    cover),
/// 4. exact millisecond boundaries around the expiry deadline, and the documented absence of any
///    "not yet valid" check on `created_ms`,
/// 5. a message that belongs to one transaction fed to a totally unrelated `PairingProcessor`
///    instance.
/// Every assertion below is tied to a real, named guard in `V2Processor`/`V2Messages`/`V2Envelope` —
/// see the doc comment on each test for exactly which one.
final class V2ProcessorAdversarialTests: XCTestCase {
    private let chat = "4200"
    private let targetUser = "200"

    private func makeIdentity(_ userId: String) -> V2Identity {
        let ed = V2Suite.generateEd25519()
        let enc = V2Suite.generateX25519()
        return V2Identity(userId: userId, publicKey: ed.publicKey, secretKey: ed.secretKey, encapsulationPk: enc.publicKey, encapsulationSk: enc.secretKey)
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
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
    }

    private struct Completed {
        var aTxnId: String = ""
        var bTxnId: String = ""
        var inviteWire: String = ""
        var acceptWire: String = ""
        var selectWire: String = ""
        var confirmWire: String = ""
        var readyWire: String = ""
        var master: [UInt8] = []
    }

    @discardableResult
    private func runHappyPath(_ p: Pair) -> Completed {
        var out = Completed()
        let invite = p.a.startPairing(chat, targetUser)!
        out.aTxnId = invite.txnId
        out.inviteWire = invite.wire

        let accept = p.b.acceptInvite(invite.wire)
        XCTAssertEqual(accept.kind, "accept")
        out.bTxnId = accept.txnId!
        out.acceptWire = accept.wire!

        let select = p.a.handleAccept(accept.wire!)
        XCTAssertTrue(select.ok, "handleAccept failed: \(select.reason ?? "")")
        out.selectWire = select.wire!

        let confirm = p.b.handleSelect(select.wire!)
        XCTAssertTrue(confirm.ok, "handleSelect failed: \(confirm.reason ?? "")")
        out.confirmWire = confirm.wire!

        let ready = p.a.handleConfirm(confirm.wire!)
        XCTAssertTrue(ready.ok, "handleConfirm failed: \(ready.reason ?? "")")
        out.readyWire = ready.wire!

        let complete = p.b.handleReady(ready.wire!)
        XCTAssertTrue(complete.ok, "handleReady failed: \(complete.reason ?? "")")
        out.master = complete.master!
        return out
    }

    // MARK: 1. Forged signature — a wrong identity keypair signs, never silently accepted.

    /// `V2Messages.verifyTyped` checks the envelope signature against the CLAIMED `identity_pk` field
    /// in an ACCEPT's own body — an attacker with no key material at all can put a real user's
    /// identity_pk into that field, but cannot produce a signature (or a matching `actor_device`
    /// digest) that verifies under it without that user's secret key. Guard:
    /// `V2Processor.handleAccept`'s `guard V2Messages.verifyTyped(...) else { return .fail("bad_signature") }`.
    func testForgedAcceptClaimingToBeBIsRejectedAsBadSignatureNotSilentlyAccepted() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let mallory = makeIdentity("666") // unrelated to this exchange; has no access to B's secret key
        let malloryEphemeral = V2Suite.generateX25519()
        let forgedAccept = V2Messages.buildAccept(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: invite.txnId, chatId: chat, actorUser: targetUser,
            actorIdentityPk: mallory.publicKey, actorIdentitySk: mallory.secretKey, parentBinding: nil,
            createdMs: "1000000", expiresMs: "1600000"
        ), V2Messages.AcceptBody(
            inviteHash: Base64Url.encode(V2Messages.hashWire(invite.wire)),
            identityPk: Base64Url.encode(p.bIdentity.publicKey), // claims to BE B, without B's secret key
            ephemeralPk: Base64Url.encode(malloryEphemeral.publicKey),
            encapsulationPk: Base64Url.encode(mallory.encapsulationPk),
            challenge: Base64Url.encode(V2Suite.randomBytes(16))
        ))!

        let result = p.a.handleAccept(forgedAccept)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "bad_signature")
        XCTAssertEqual(p.a.phaseOf(invite.txnId), .invited, "the forgery must not advance A's transaction at all")
    }

    /// By the time A sends SELECT, B has already recorded A's REAL identity key from the ACCEPT round
    /// trip (`PendingTxn.peerIdentityPk`) — unlike ACCEPT, there is no attacker-controlled body field
    /// to route around it. A SELECT with A's exact real payload but re-signed by a different key must
    /// fail against that already-recorded key. Guard: `handleSelect`'s
    /// `guard V2Messages.verifyTyped(parsed.envelope, identityPkB64: Base64Url.encode(peerIdentityPk)) else { return .fail("bad_signature") }`.
    func testForgedSelectReplacingAsRealSignerIsRejectedAsBadSignature() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let accept = p.b.acceptInvite(invite.wire)
        let legitSelect = p.a.handleAccept(accept.wire!)
        XCTAssertTrue(legitSelect.ok)
        let parsedSelect = V2Messages.parseSelect(legitSelect.wire!)!

        let mallory = makeIdentity("666")
        let forged = V2Messages.buildSelect(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: invite.txnId, chatId: chat, actorUser: "100",
            actorIdentityPk: mallory.publicKey, actorIdentitySk: mallory.secretKey, parentBinding: nil,
            createdMs: "1000000", expiresMs: "1600000"
        ), V2Messages.SelectBody(
            inviteHash: parsedSelect.body.inviteHash, acceptHash: parsedSelect.body.acceptHash,
            transcriptHash: parsedSelect.body.transcriptHash, macA: parsedSelect.body.macA
        ))!

        let confirm = p.b.handleSelect(forged)
        XCTAssertFalse(confirm.ok)
        XCTAssertEqual(confirm.reason, "bad_signature")
    }

    /// Same shape one step later: A already recorded B's real identity from SELECT/ACCEPT
    /// (`peerIdentityPk`); a CONFIRM with B's exact real payload but signed by a stranger must fail.
    /// Guard: `handleConfirm`'s own `verifyTyped(... identityPkB64: peerIdentityPk ...)` check.
    func testForgedConfirmReplacingAsRealSignerIsRejectedAsBadSignature() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let accept = p.b.acceptInvite(invite.wire)
        let select = p.a.handleAccept(accept.wire!)
        let legitConfirm = p.b.handleSelect(select.wire!)
        XCTAssertTrue(legitConfirm.ok)
        let parsedConfirm = V2Messages.parseConfirm(legitConfirm.wire!)!

        let mallory = makeIdentity("666")
        let forged = V2Messages.buildConfirm(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: invite.txnId, chatId: chat, actorUser: "200",
            actorIdentityPk: mallory.publicKey, actorIdentitySk: mallory.secretKey, parentBinding: nil,
            createdMs: "1000000", expiresMs: "1600000"
        ), V2Messages.ConfirmBody(
            selectHash: parsedConfirm.body.selectHash, transcriptHash: parsedConfirm.body.transcriptHash, macB: parsedConfirm.body.macB
        ))!

        let ready = p.a.handleConfirm(forged)
        XCTAssertFalse(ready.ok)
        XCTAssertEqual(ready.reason, "bad_signature")
    }

    /// UNPAIR is checked against the pending transaction's own recorded `peerIdentityPk`
    /// (`handleUnpair`'s `guard let txn = pending.get(txnId), let peerIdentityPk = txn.peerIdentityPk`
    /// then `verifyTyped(... identityPkB64: peerIdentityPk ...)`). A forged UNPAIR impersonating B must
    /// fail closed, and — the actual security property a user cares about — A's binding must stay
    /// exactly as active as it was before the forgery arrived.
    func testForgedUnpairIsRejectedAndTheBindingStaysActive() {
        let p = Pair(makeIdentity: makeIdentity)
        let done = runHappyPath(p)
        let bindingBefore = p.a.bindingStore.current(chat)!.bindingId
        let mallory = makeIdentity("666")

        let forgedUnpair = V2Messages.buildUnpair(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: done.bTxnId, chatId: chat, actorUser: "200",
            actorIdentityPk: mallory.publicKey, actorIdentitySk: mallory.secretKey, parentBinding: nil,
            createdMs: "1000000", expiresMs: "1600000"
        ), V2Messages.UnpairBody(bindingId: bindingBefore))!

        let result = p.a.handleUnpair(forgedUnpair)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "bad_signature")
        XCTAssertTrue(p.a.canSend(chat), "a forged UNPAIR must have zero effect on real send eligibility")
        XCTAssertEqual(p.a.bindingStore.current(chat)?.bindingId, bindingBefore)
    }

    // MARK: 2. Replay of an old, previously-valid INVITE/ACCEPT — idempotent, never a second binding.

    /// Long after the exchange finished, the network (or an attacker) redelivers A's OWN original
    /// ACCEPT. Guard: `handleAccept`'s `if txn.phase != .invited { if wire == txn.peerWire, ... return
    /// .ok("replay", ...) }` branch — applies regardless of how far past `.confirming` the phase has
    /// advanced, so it still fires once `.done`. The real property under test is not just "ok is
    /// true" but that NO second binding is ever installed as a side effect.
    func testReplayOfTheOriginalAcceptAfterFullCompletionIsIdempotentAndNeverInstallsASecondBinding() {
        let p = Pair(makeIdentity: makeIdentity)
        let done = runHappyPath(p)
        let firstBindingId = p.a.bindingStore.current(chat)!.bindingId

        let replay = p.a.handleAccept(done.acceptWire)
        XCTAssertTrue(replay.ok)
        XCTAssertEqual(replay.kind, "replay")
        XCTAssertEqual(replay.wire, done.selectWire)
        XCTAssertEqual(p.a.bindingStore.current(chat)?.bindingId, firstBindingId)
        XCTAssertEqual(p.a.bindingStore.historical(chat).count, 0, "a replayed ACCEPT must never push a second binding into history")
    }

    /// Symmetric case at B's own entry point: the ORIGINAL INVITE is redelivered (or a user double-
    /// taps an old notification) after the exchange already completed. Guard: `acceptInvite`'s `if let
    /// existing = pending.get(txnId) { return .accept with existing.ownWire }` — returns the exact
    /// same wire rather than minting a new ACCEPT/txn/binding.
    func testReplayOfTheOriginalInviteAtBAfterCompletionReturnsTheSameAcceptAndCreatesNoSecondTransaction() {
        let p = Pair(makeIdentity: makeIdentity)
        let done = runHappyPath(p)
        let firstBindingId = p.b.bindingStore.current(chat)!.bindingId

        let repeated = p.b.acceptInvite(done.inviteWire)
        XCTAssertEqual(repeated.kind, "accept")
        XCTAssertEqual(repeated.txnId, done.bTxnId)
        XCTAssertEqual(repeated.wire, done.acceptWire, "must hand back the SAME accept wire, not mint a new one")
        XCTAssertEqual(p.b.bindingStore.current(chat)?.bindingId, firstBindingId)
        XCTAssertEqual(p.b.bindingStore.historical(chat).count, 0)
    }

    // MARK: 3. Tampered payload — a single flipped field, not just a corrupted signature tail.

    /// Unlike `testP07BadSignatureOnSelectIsRejectedByB` (which corrupts the wire's trailing bytes,
    /// breaking the signature itself), this builds a technically well-formed, VALIDLY-signed ACCEPT
    /// (B's real key, real signature) whose `invite_hash` body field has one bit flipped from the hash
    /// of A's real INVITE. Guard: `handleAccept`'s explicit
    /// `guard parsed.body.inviteHash == Base64Url.encode(inviteHash) else { return .fail("hash_mismatch") }`
    /// — proves this check, not just the signature check, is load-bearing.
    func testAcceptWithATamperedInviteHashFieldIsCaughtByHashMismatchDespiteAValidSignature() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        var tamperedHash = V2Messages.hashWire(invite.wire)
        tamperedHash[0] ^= 0x01
        let ephemeral = V2Suite.generateX25519()

        let tamperedAccept = V2Messages.buildAccept(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: invite.txnId, chatId: chat, actorUser: targetUser,
            actorIdentityPk: p.bIdentity.publicKey, actorIdentitySk: p.bIdentity.secretKey, parentBinding: nil,
            createdMs: "1000000", expiresMs: "1600000"
        ), V2Messages.AcceptBody(
            inviteHash: Base64Url.encode(tamperedHash), identityPk: Base64Url.encode(p.bIdentity.publicKey),
            ephemeralPk: Base64Url.encode(ephemeral.publicKey), encapsulationPk: Base64Url.encode(p.bIdentity.encapsulationPk),
            challenge: Base64Url.encode(V2Suite.randomBytes(16))
        ))!

        let result = p.a.handleAccept(tamperedAccept)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "hash_mismatch")
    }

    /// Same idea one step later: a validly-signed SELECT (A's real key) whose `accept_hash` field has
    /// one bit flipped from the hash of B's real ACCEPT. Guard: `handleSelect`'s
    /// `if parsed.body.acceptHash != Base64Url.encode(acceptHash) { ... return .fail("hash_mismatch") }`
    /// fallback path (no sibling-device ACCEPT recorded, so the "superseded" carve-out cannot apply).
    func testSelectWithATamperedAcceptHashFieldIsCaughtByHashMismatch() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let accept = p.b.acceptInvite(invite.wire)
        let legitSelect = p.a.handleAccept(accept.wire!)
        let parsedSelect = V2Messages.parseSelect(legitSelect.wire!)!
        var tamperedAcceptHash = Base64Url.decode(parsedSelect.body.acceptHash)!
        tamperedAcceptHash[0] ^= 0x01

        let tamperedSelect = V2Messages.buildSelect(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: invite.txnId, chatId: chat, actorUser: "100",
            actorIdentityPk: p.aIdentity.publicKey, actorIdentitySk: p.aIdentity.secretKey, parentBinding: nil,
            createdMs: "1000000", expiresMs: "1600000"
        ), V2Messages.SelectBody(
            inviteHash: parsedSelect.body.inviteHash, acceptHash: Base64Url.encode(tamperedAcceptHash),
            transcriptHash: parsedSelect.body.transcriptHash, macA: parsedSelect.body.macA
        ))!

        let confirm = p.b.handleSelect(tamperedSelect)
        XCTAssertFalse(confirm.ok)
        XCTAssertEqual(confirm.reason, "hash_mismatch")
    }

    /// (Kept from the macOS copy's own adversarial suite when the two V2 trees were resynced, 2026-09-29.)
    /// `handleSelect`'s independent transcript recomputation — `guard let th =
    /// V2Transcript.computeTranscriptHash(input), parsed.body.transcriptHash == Base64Url.encode(th) else
    /// { return .fail("transcript_mismatch") }` (v1.4 section 7: "B recomputes th independently, never
    /// trusts A's claim"). The rest of the SELECT (invite_hash/accept_hash/mac_a, signature) is left
    /// genuinely correct so only this one field is under test.
    func testSelectWithATamperedTranscriptHashIsRejectedByTheResponder() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let accept = p.b.acceptInvite(invite.wire)
        let realSelect = p.a.handleAccept(accept.wire!)
        XCTAssertTrue(realSelect.ok)
        guard let parsedReal = V2Messages.parseSelect(realSelect.wire!) else { return XCTFail("setup: could not parse the real SELECT") }
        let fakeTranscriptHash = Base64Url.encode(V2Suite.randomBytes(32))

        let tamperedSelect = V2Messages.buildSelect(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: invite.txnId, chatId: chat, actorUser: p.aIdentity.userId,
            actorIdentityPk: p.aIdentity.publicKey, actorIdentitySk: p.aIdentity.secretKey, parentBinding: nil,
            createdMs: parsedReal.envelope.createdMs, expiresMs: parsedReal.envelope.expiresMs
        ), V2Messages.SelectBody(
            inviteHash: parsedReal.body.inviteHash, acceptHash: parsedReal.body.acceptHash,
            transcriptHash: fakeTranscriptHash, macA: parsedReal.body.macA
        ))!

        let result = p.b.handleSelect(tamperedSelect)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "transcript_mismatch")
    }

    // MARK: 4. Boundary timestamps.

    /// `isExpired` reads `now() >= expiresMs` — AT the deadline itself must already be rejected, not
    /// only strictly after it.
    func testInviteAcceptedAtExactlyTheExpiryBoundaryIsAlreadyRejectedAsExpired() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let expiresMs = Int64(V2Messages.parseInvite(invite.wire)!.envelope.expiresMs)!
        p.clockBox.value = expiresMs
        XCTAssertEqual(p.b.acceptInvite(invite.wire).kind, "expired")
    }

    /// The complementary boundary: exactly one millisecond BEFORE the deadline must still succeed —
    /// proving `isExpired`'s `>=` is exact in both directions, not an off-by-one in either.
    func testInviteAcceptedOneMillisecondBeforeTheExpiryBoundaryStillSucceeds() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let expiresMs = Int64(V2Messages.parseInvite(invite.wire)!.envelope.expiresMs)!
        p.clockBox.value = expiresMs - 1
        XCTAssertEqual(p.b.acceptInvite(invite.wire).kind, "accept")
    }

    /// One millisecond PAST the deadline, symmetric to the exact-boundary case above.
    func testInviteAcceptedOneMillisecondPastTheExpiryBoundaryIsRejectedAsExpired() {
        let p = Pair(makeIdentity: makeIdentity)
        let invite = p.a.startPairing(chat, targetUser)!
        let expiresMs = Int64(V2Messages.parseInvite(invite.wire)!.envelope.expiresMs)!
        p.clockBox.value = expiresMs + 1
        XCTAssertEqual(p.b.acceptInvite(invite.wire).kind, "expired")
    }

    /// Documents real, deliberate behavior rather than asserting a check that does not exist:
    /// `V2Processor.isExpired`'s own doc comment says "the deadline check uses the moment of THIS
    /// processing — every expiry check reads now(), never a claim in the message", and there is no
    /// TEST_MATRIX row or code path anywhere in `V2Processor`/`V2Messages`/`V2Envelope` comparing
    /// `created_ms` against the clock (confirmed by grep — only `expires_ms` ever reaches `isExpired`).
    /// An INVITE whose `created_ms` claims a point far in the future is therefore accepted exactly
    /// like an ordinary one, as long as `expires_ms` itself has not elapsed. This pins down that
    /// intentional absence so a future change cannot silently start treating `created_ms` as
    /// security-relevant (or silently swap which field `isExpired` reads) without an explicit, tested
    /// decision and a TEST_MATRIX row to go with it.
    func testInviteWithACreatedMsFarInTheFutureIsAcceptedBecauseOnlyExpiresMsGatesValidity() {
        let p = Pair(makeIdentity: makeIdentity)
        let farFutureCreated = p.clockBox.value + 1_000 * 24 * 60 * 60 * 1000 // ~1000 days ahead of "now"
        let ephemeral = V2Suite.generateX25519()
        let forged = V2Messages.buildInvite(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: V2Envelope.randomId(), chatId: chat, actorUser: "100",
            actorIdentityPk: p.aIdentity.publicKey, actorIdentitySk: p.aIdentity.secretKey, parentBinding: nil,
            createdMs: String(farFutureCreated), expiresMs: String(farFutureCreated + 10 * 60 * 1000)
        ), V2Messages.InviteBody(
            intent: "new", identityPk: Base64Url.encode(p.aIdentity.publicKey), ephemeralPk: Base64Url.encode(ephemeral.publicKey),
            encapsulationPk: Base64Url.encode(p.aIdentity.encapsulationPk), targetUser: targetUser, challenge: Base64Url.encode(V2Suite.randomBytes(16))
        ))!

        XCTAssertEqual(p.b.acceptInvite(forged).kind, "accept")
    }

    /// (Kept from the macOS copy's own adversarial suite when the two V2 trees were resynced, 2026-09-29.)
    /// The complement of the test above: a forged INVITE whose `created_ms` claims a point far in the
    /// future (as if to look freshly sent) but whose `expires_ms` is already in the past relative to the
    /// REAL clock. `isExpired` only ever compares the processor's own `now()` against `expires_ms` — never
    /// against `created_ms` — so a future `created_ms` claim must not grant extra life to an otherwise-stale
    /// message.
    func testAFutureCreatedMsClaimDoesNotBypassTheRealClockExpiryCheck() {
        let p = Pair(makeIdentity: makeIdentity)
        let futureCreatedMs = p.clockBox.value + 365 * 24 * 60 * 60 * 1000
        let pastExpiresMs = p.clockBox.value - 1

        let backdatedInvite = V2Messages.buildInvite(V2Messages.EnvelopeParams(
            eventId: V2Envelope.randomId(), txnId: V2Envelope.randomId(), chatId: chat, actorUser: p.aIdentity.userId,
            actorIdentityPk: p.aIdentity.publicKey, actorIdentitySk: p.aIdentity.secretKey, parentBinding: nil,
            createdMs: String(futureCreatedMs), expiresMs: String(pastExpiresMs)
        ), V2Messages.InviteBody(
            intent: "new", identityPk: Base64Url.encode(p.aIdentity.publicKey), ephemeralPk: Base64Url.encode(V2Suite.generateX25519().publicKey),
            encapsulationPk: Base64Url.encode(p.aIdentity.encapsulationPk), targetUser: targetUser, challenge: Base64Url.encode(V2Suite.randomBytes(16))
        ))!

        XCTAssertEqual(p.b.acceptInvite(backdatedInvite).kind, "expired")
    }

    // MARK: 5. Wrong actor/target — a message for one transaction fed to an unrelated processor.

    /// A SELECT that belongs to txn1 (between A1 and B1) handed to a completely unrelated third
    /// device's processor, which never received any INVITE/ACCEPT for that txnId at all. Guard:
    /// `handleSelect`'s `guard let txn = pending.get(txnId), txn.role == .responder, ... else { return
    /// .fail("unexpected_phase") }` — the equivalent-to-`unknown_txn` outcome for this entry point.
    func testASelectForOneTransactionFedToAnUnrelatedThirdPartyProcessorIsRejected() {
        let p1 = Pair(makeIdentity: makeIdentity)
        let invite1 = p1.a.startPairing(chat, targetUser)!
        let accept1 = p1.b.acceptInvite(invite1.wire)
        let select1 = p1.a.handleAccept(accept1.wire!)
        XCTAssertTrue(select1.ok)

        let stranger = V2Processor.PairingProcessor(identity: makeIdentity("999"), now: { p1.clockBox.value })
        let result = stranger.handleSelect(select1.wire!)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "unexpected_phase")
    }

    /// Same idea at `handleAccept`'s own entry point, which uses the literal `unknown_txn` reason:
    /// `guard let txn = pending.get(txnId), txn.role == .initiator else { return .fail("unknown_txn") }`.
    func testAnAcceptForOneTransactionFedToAnUnrelatedThirdPartyProcessorReturnsUnknownTxn() {
        let p1 = Pair(makeIdentity: makeIdentity)
        let invite1 = p1.a.startPairing(chat, targetUser)!
        let accept1 = p1.b.acceptInvite(invite1.wire)

        let stranger = V2Processor.PairingProcessor(identity: makeIdentity("999"), now: { p1.clockBox.value })
        let result = stranger.handleAccept(accept1.wire!)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "unknown_txn")
    }
}
