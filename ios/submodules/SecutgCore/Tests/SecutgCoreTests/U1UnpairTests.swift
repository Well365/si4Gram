import XCTest
@testable import SecutgCore

/// `U1` at the wire level (PLAN.md 3.31.3), ported from Web A's `U1 unpair notice` block.
///
/// The format is a cross-client contract: the signature covers the UTF-8 bytes of `U1:<user_id>:<at>`
/// exactly. A port that signs any other string produces notices no other client can verify, and the
/// failure looks like a forgery rather than like a bug.
final class U1FormatTests: XCTestCase {
    let user = "4242"
    let at: Int64 = 1_789_000_000
    let sig = [UInt8](repeating: 7, count: 64)

    func testRoundTripsAndTheSignedTextIsExactlyTheFirstTwoSegments() {
        let wire = Rekey.serializeU1(userId: user, at: at, signature: sig)
        XCTAssertEqual(wire, "U1:\(user):\(at):\(Base64Url.encode(sig))")
        XCTAssertTrue(Rekey.isU1(wire))
        let parsed = Rekey.parseU1(wire)!
        XCTAssertEqual(parsed.userId, user)
        XCTAssertEqual(parsed.at, at)
        XCTAssertEqual(parsed.signature, sig)
        // Every port must sign this exact string, byte for byte, or the five clients cannot read each other
        XCTAssertEqual(parsed.signedText, "U1:\(user):\(at)")
        XCTAssertEqual(Rekey.buildU1SignedText(userId: user, at: at), parsed.signedText)
    }

    /// Without this the notice is dropped one layer earlier and shows up in the chat as a line of raw text
    func testTheInboundGateLetsItThrough() {
        XCTAssertTrue(Rekey.isControlMessage(Rekey.serializeU1(userId: user, at: at, signature: sig)))
    }

    func testIsNotConfusedWithTheOtherControlMessages() {
        XCTAssertFalse(Rekey.isU1("P1:1:a:b:c"))
        XCTAssertFalse(Rekey.isU1("R1:rotate:0123456789abcdef.20260911:cGF5:c2ln"))
        XCTAssertFalse(Rekey.isU1("E1:whatever"))
    }

    func testRejectsAnythingMalformedRatherThanGuessingAtIt() {
        let b64 = Base64Url.encode(sig)
        XCTAssertNil(Rekey.parseU1("U1:\(user):\(at):\(Base64Url.encode([UInt8](repeating: 0, count: 63)))"))
        XCTAssertNil(Rekey.parseU1("U1:notdigits:\(at):\(b64)"))
        XCTAssertNil(Rekey.parseU1("U1:\(user):notdigits:\(b64)"))
        XCTAssertNil(Rekey.parseU1("U1:\(user):\(at)"))
        XCTAssertNil(Rekey.parseU1("U1:\(user):\(at):\(b64):extra"))
        XCTAssertNil(Rekey.parseU1("U1:\(user):\(at):\(b64)\(String(repeating: "A", count: 4096))"))
        // `\d{1,20}` admits more than Web A can hold exactly, and "what counts as malformed" is part of the
        // contract, so this port refuses the same range its JavaScript twin does instead of accepting quietly.
        XCTAssertNil(Rekey.parseU1("U1:\(user):9007199254740993:\(b64)"))
    }
}

/// `U1` applied: the peer tells us to destroy this chat's key too (PLAN.md 3.31.3), ported from Web A.
///
/// Every check has to pass, in order, and any one of them failing leaves the keyring exactly as it was —
/// this is a message that destroys keys, so "probably fine" is not a state it may act on.
final class U1AppliedTests: XCTestCase {
    let alice = "801"
    let bobby = "802"
    /// Server date of the `P1` that completed the pairing, and therefore the pairing's own `pairedAt`
    let pairedAt: Int64 = 1_789_000_000

    struct Peer {
        let userId: String
        let ring: KeyRing
        let processor: RekeyProcessor
    }

    func makePeer(_ userId: String) throws -> Peer {
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { vectorNowMs }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        return Peer(userId: userId, ring: ring, processor: RekeyProcessor(ring: ring, clock: { vectorNowMs }))
    }

    func p1(_ peer: Peer) throws -> String {
        let id = peer.ring.identity!
        return try Rekey.buildP1(userId: peer.userId, x25519Pk: id.x25519Pk, ed25519Pk: id.ed25519Pk, ed25519Sk: id.ed25519Sk)
    }

    /// Alice invites, Bob accepts, and Alice's pairing records `pairedAt` as the server date of Bob's `P1` —
    /// which is what rule 5 below judges a notice's own `at` against.
    func pairedPeers() throws -> (alice: Peer, bob: Peer) {
        let a = try makePeer(alice)
        let b = try makePeer(bobby)
        _ = try a.processor.startPairing(chatId: bobby, peerId: bobby)
        _ = b.processor.handle(text: try p1(a), chatId: alice, senderId: alice, ownUserId: bobby, messageDate: pairedAt)
        _ = try b.processor.startPairing(chatId: alice, peerId: alice)
        _ = a.processor.handle(text: try p1(b), chatId: bobby, senderId: bobby, ownUserId: alice, messageDate: pairedAt)
        return (a, b)
    }

    func u1(from peer: Peer, at: Int64) throws -> String {
        return try Rekey.buildU1(userId: peer.userId, at: at, ed25519Sk: peer.ring.identity!.ed25519Sk)
    }

    func testThePairedPeersNoticeUnpairsThisSideAndDestroysTheKey() throws {
        let (a, b) = try pairedPeers()
        let masterId = a.ring.chatMasterId(bobby)!
        let key = a.ring.currentKey(chatId: bobby)!
        let wire = try E1Codec.encrypt(text: "still readable?", entities: nil, keyId: key.keyId, sessionKey: key.sessionKey)

        let result = a.processor.handle(text: try u1(from: b, at: pairedAt + 60), chatId: bobby, senderId: bobby, ownUserId: alice)
        XCTAssertEqual(result?.isUnpair, true)
        XCTAssertEqual(result?.ok, true)
        XCTAssertNil(result?.reason)

        XCTAssertNil(a.ring.chatPairing(bobby))
        XCTAssertFalse(a.ring.isChatEncrypted(bobby))
        XCTAssertFalse(a.ring.listMasterIds().contains(masterId))
        XCTAssertFalse(E1Codec.decrypt(wire: wire, lookup: { a.ring.lookupSessionKey($0) }).ok)
    }

    /// Rule 4, the one that keeps this from being a remote destruct button anyone could press
    func testASignatureFromAnyoneButThisChatsPeerDoesNothing() throws {
        let (a, _) = try pairedPeers()
        let masterId = a.ring.chatMasterId(bobby)!
        let stranger = try Rekey.generateIdentity()
        // Correctly formed, correctly self-consistent, signed by a key this chat never registered.
        let forged = try Rekey.buildU1(userId: bobby, at: pairedAt + 60, ed25519Sk: stranger.ed25519Sk)
        let result = a.processor.handle(text: forged, chatId: bobby, senderId: bobby, ownUserId: alice)
        XCTAssertEqual(result?.isUnpair, true)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "bad_signature")
        XCTAssertNotNil(a.ring.chatPairing(bobby))
        XCTAssertTrue(a.ring.listMasterIds().contains(masterId))
    }

    /// Rule 2: without it a copy of somebody's valid notice could be replayed into the chat by anyone at all
    func testTheTelegramSenderMustBeTheUserTheNoticeNames() throws {
        let (a, b) = try pairedPeers()
        let result = a.processor.handle(text: try u1(from: b, at: pairedAt + 60), chatId: bobby, senderId: "999", ownUserId: alice)
        XCTAssertEqual(result?.isUnpair, true)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "sender_mismatch")
        XCTAssertNotNil(a.ring.chatPairing(bobby))
    }

    /// Rule 3: a stranger saying this about a chat they are not the peer of means nothing
    func testANoticeFromSomeoneWhoIsNotThisChatsPairedPeerChangesNothing() throws {
        let (a, _) = try pairedPeers()
        let carol = try Rekey.generateIdentity()
        let wire = try Rekey.buildU1(userId: "999", at: pairedAt + 60, ed25519Sk: carol.ed25519Sk)
        let result = a.processor.handle(text: wire, chatId: bobby, senderId: "999", ownUserId: alice)
        XCTAssertEqual(result?.isUnpair, true)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "not_paired_peer")
        XCTAssertNotNil(a.ring.chatPairing(bobby))
    }

    /// Rule 5: Bob unpaired, both re-paired, and only now does Bob's original notice arrive
    func testANoticeOlderThanThePairingIsAReplayAndMustNotKillAPairingRebuiltSince() throws {
        let (a, b) = try pairedPeers()
        let masterId = a.ring.chatMasterId(bobby)!
        let result = a.processor.handle(text: try u1(from: b, at: pairedAt - 1), chatId: bobby, senderId: bobby, ownUserId: alice)
        XCTAssertEqual(result?.isUnpair, true)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "stale")
        XCTAssertNotNil(a.ring.chatPairing(bobby))
        XCTAssertTrue(a.ring.listMasterIds().contains(masterId))
    }

    /// The sender sees its own notice come back. It unpaired before sending, so there is nothing left to do —
    /// and nothing to complain about either, which is why this is `ok`.
    func testOurOwnNoticeEchoingBackIsANoOpNotASecondUnpair() throws {
        let (a, _) = try pairedPeers()
        a.processor.unpair(chatId: bobby)
        let own = try Rekey.buildU1(userId: alice, at: pairedAt + 60, ed25519Sk: a.ring.identity!.ed25519Sk)
        let result = a.processor.handle(text: own, chatId: bobby, senderId: alice, ownUserId: alice)
        XCTAssertEqual(result?.isUnpair, true)
        XCTAssertEqual(result?.ok, true)
        XCTAssertEqual(result?.reason, "own_echo")
    }

    /// The three shapes the rendered line is chosen from (PLAN.md 3.31.3, the receiving NOTICE).
    ///
    /// Every client folds `ok` and `reason` into one visible sentence: a refusal reads as
    /// `SecutgRekeyRejected(reason)`, this device's own echo as `SecutgUnpaired`, and a peer's notice that was
    /// acted on as `SecutgUnpairedByPeer`. iOS and macOS carry that decision through a single `detail` segment
    /// (`unpair:<ok|own_echo|reason>`, read by `SecutgAccountRuntime.controlSummary`), which is only
    /// unambiguous while these three sets stay disjoint — so it is pinned here rather than left as a habit.
    func testSuccessAndRefusalReasonsNeverCollide() throws {
        let (a, b) = try pairedPeers()
        let stranger = try Rekey.generateIdentity()

        // A peer's notice that was acted on: ok, and no reason at all.
        let (fresh, freshPeer) = try pairedPeers()
        let applied = fresh.processor.handle(text: try u1(from: freshPeer, at: pairedAt + 60), chatId: bobby, senderId: bobby, ownUserId: alice)
        XCTAssertEqual(applied?.ok, true)
        XCTAssertNil(applied?.reason)

        // Our own echo: also ok, and the ONE success that carries a reason.
        a.processor.unpair(chatId: bobby)
        let own = try Rekey.buildU1(userId: alice, at: pairedAt + 60, ed25519Sk: a.ring.identity!.ed25519Sk)
        XCTAssertEqual(a.processor.handle(text: own, chatId: bobby, senderId: alice, ownUserId: alice)?.reason, "own_echo")

        // Every refusal this chat can produce names itself, and never with a word a success could use.
        let refusals: [String?] = [
            b.processor.handle(text: "U1:not a notice", chatId: alice, senderId: alice, ownUserId: bobby)?.reason,
            b.processor.handle(text: try u1(from: b, at: pairedAt + 60), chatId: alice, senderId: nil, ownUserId: bobby)?.reason,
            b.processor.handle(text: try u1(from: b, at: pairedAt + 60), chatId: alice, senderId: "999", ownUserId: bobby)?.reason,
            b.processor.handle(text: try u1(from: b, at: pairedAt + 60), chatId: "-1009", senderId: bobby, ownUserId: alice)?.reason,
            b.processor.handle(text: try Rekey.buildU1(userId: "999", at: pairedAt + 60, ed25519Sk: stranger.ed25519Sk), chatId: "999", senderId: "999", ownUserId: bobby)?.reason,
            b.processor.handle(text: try Rekey.buildU1(userId: alice, at: pairedAt + 60, ed25519Sk: stranger.ed25519Sk), chatId: alice, senderId: alice, ownUserId: bobby)?.reason,
            b.processor.handle(text: try u1(from: a, at: pairedAt - 1), chatId: alice, senderId: alice, ownUserId: bobby)?.reason,
        ]
        for reason in refusals {
            XCTAssertNotNil(reason)
            XCTAssertNotEqual(reason, "ok")
            XCTAssertNotEqual(reason, "own_echo")
        }
    }

    /// Unpairing is a one-to-one idea, so a `U1` in a group is ignored
    func testIgnoredInAGroup() throws {
        let (_, b) = try pairedPeers()
        let result = b.processor.handle(text: try u1(from: b, at: pairedAt + 60), chatId: "-1009", senderId: bobby, ownUserId: alice)
        XCTAssertEqual(result?.isUnpair, true)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "not_private")
    }
}
