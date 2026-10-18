import XCTest
@testable import SecutgCore

/// One-to-one auto pairing through P1 (PLAN.md 3.7), mirroring Web A's processor tests.
final class PairingFlowTests: XCTestCase {
    let alice = "501", bob = "502", group = "-1001"
    /// Unix seconds of the frozen test clock
    let t0: Int64 = vectorNowMs / 1000

    /// A clock a test can move. PLAN.md 3.25.6 rule 7 refuses a takeover started within
    /// `pairingRaceWindowSeconds` of the `P1` it would replace, so a device that re-pairs "later" has to be
    /// later on its own wall clock too — left frozen at `t0` it would be judged as racing that very `P1`.
    final class MovableClock {
        var ms: Int64
        init(_ ms: Int64 = vectorNowMs) { self.ms = ms }
    }

    func peer(_ clock: MovableClock = MovableClock()) throws -> (KeyRing, RekeyProcessor) {
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { clock.ms }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        return (ring, RekeyProcessor(ring: ring, clock: { clock.ms }))
    }

    func p1(_ userId: String, _ ring: KeyRing) throws -> String {
        let id = ring.identity!
        return try Rekey.buildP1(userId: userId, x25519Pk: id.x25519Pk, ed25519Pk: id.ed25519Pk, ed25519Sk: id.ed25519Sk)
    }

    func testInviteAcceptDerivesTheSameMasterOnBothSides() throws {
        let (aRing, aProc) = try peer()
        let (bRing, bProc) = try peer()
        XCTAssertEqual(try aProc.startPairing(chatId: bob, peerId: bob), .invited)
        XCTAssertEqual(aRing.chatPairing(bob)?.state, .invited)

        let incoming = bProc.handle(text: try p1(alice, aRing), chatId: alice, senderId: alice, ownUserId: bob)
        XCTAssertEqual(incoming?.pairing, .incoming)
        XCTAssertNil(bRing.chatMasterId(alice))

        XCTAssertEqual(try bProc.startPairing(chatId: alice, peerId: alice), .paired)
        XCTAssertTrue(bRing.isChatEncrypted(alice))

        let done = aProc.handle(text: try p1(bob, bRing), chatId: bob, senderId: bob, ownUserId: alice)
        XCTAssertEqual(done?.pairing, .paired)
        XCTAssertEqual(aRing.chatMasterId(bob), bRing.chatMasterId(alice))
        XCTAssertTrue(aRing.isChatEncrypted(bob))
    }

    func testChangedPeerKeyIsReportedAndAdoptedOnSight() throws {
        let (aRing, aProc) = try peer()
        let (bRing, _) = try peer()
        _ = try aProc.startPairing(chatId: bob, peerId: bob)
        _ = aProc.handle(text: try p1(bob, bRing), chatId: bob, senderId: bob, ownUserId: alice)
        let before = aRing.chatMasterId(bob)
        let keyBefore = aRing.memberPk(chatId: bob, userId: bob)

        let (impostor, _) = try peer()
        // well after the accept race window, so this is a real key change and not a second device accepting
        let changed = aProc.handle(text: try p1(bob, impostor), chatId: bob, senderId: bob, ownUserId: alice, messageDate: t0 + 3600)
        // PLAN.md 3.25.11 (2026-09-20 用户定): still REPORTED — that the peer's key changed is worth knowing
        // and the line says so with the new safety code — but no longer blocked behind a tap. Leaving the chat
        // in `keyChanged` also made `rekeySigner` refuse every rotate the peer sent, so on real phones one
        // direction worked and the other answered `no_admin_key` for ever.
        XCTAssertEqual(changed?.pairing, .keyChanged)
        XCTAssertEqual(aRing.chatPairing(bob)?.state, .paired)
        XCTAssertNotEqual(aRing.memberPk(chatId: bob, userId: bob), keyBefore)
        // Re-derived from the peer's new public key, which is the master they already computed
        XCTAssertNotEqual(aRing.chatMasterId(bob), before)
        let adopted = aRing.chatMasterId(bob)

        // Pressing re-pair by hand is now a no-op on the key: it lands on the same master
        XCTAssertEqual(try aProc.startPairing(chatId: bob, peerId: bob), .paired)
        XCTAssertEqual(aRing.chatMasterId(bob), adopted)
        XCTAssertEqual(aProc.handle(text: try p1(bob, impostor), chatId: bob, senderId: bob, ownUserId: alice)?.pairing, .alreadyPaired)
    }

    func testGroupAndOwnEchoP1NeverPair() throws {
        let (aRing, aProc) = try peer()
        let (bRing, _) = try peer()
        let echo = aProc.handle(text: try p1(alice, aRing), chatId: bob, senderId: alice, ownUserId: alice)
        XCTAssertEqual(echo?.pairing, .selfInvited)
        XCTAssertNil(aRing.chatPairing(bob))
        XCTAssertNil(aProc.handle(text: try p1(bob, bRing), chatId: group, senderId: bob, ownUserId: alice)?.pairing)
        XCTAssertNil(aRing.chatPairing(group))
    }

    func testPairingStateSurvivesTheSnapshotCodec() throws {
        let (ring, _) = try peer()
        let full = KeyRing.Pairing(peerId: "42", state: .paired, verified: true, startedAt: t0, pairedAt: t0 + 5)
        try ring.setChatPairing(chatId: "42", full)
        try ring.setChatPairing(chatId: "43", KeyRing.Pairing(peerId: "43", state: .otherDevice, verified: false, pairedAt: t0))
        let decoded = SnapshotCodec.decode(SnapshotCodec.encode(ring.snapshot()))
        XCTAssertEqual(decoded?.chatPairings["42"], full)
        XCTAssertEqual(decoded?.chatPairings["43"]?.state, .otherDevice)
        XCTAssertEqual(decoded?.chatPairings["43"]?.pairedAt, t0)
        XCTAssertThrowsError(try ring.setChatPairing(chatId: "1", KeyRing.Pairing(peerId: "", state: .paired, verified: false)))
        ring.clearChatPairing("42")
        XCTAssertNil(ring.chatPairing("42"))

        // A snapshot written before the timestamps existed still decodes
        let legacy = #"{"v":1,"chat_pairings":{"7":{"peer_id":"7","state":"paired","verified":false}}}"#
        let old = SnapshotCodec.decode(Data(legacy.utf8))
        XCTAssertEqual(old?.chatPairings["7"], KeyRing.Pairing(peerId: "7", state: .paired, verified: false))
        XCTAssertNil(old?.chatPairings["7"]?.startedAt)
        XCTAssertNil(old?.chatPairings["7"]?.pairedAt)
    }
}

/// PLAN.md 3.7 rules 8–11: several devices per account, "the earliest P1 wins", history replays.
extension PairingFlowTests {
    func testSeveralPeerDevicesAcceptTheLatestP1TakesTheKeyAndTheDisplacedOneIsSeen() throws {
        let (aRing, aProc) = try peer()
        let (bobPhone, _) = try peer()
        let (bobTablet, _) = try peer()
        _ = try aProc.startPairing(chatId: bob, peerId: bob)

        let first = aProc.handle(text: try p1(bob, bobPhone), chatId: bob, senderId: bob, ownUserId: alice, messageDate: t0 + 10)
        XCTAssertEqual(first?.pairing, .paired)
        let phoneMaster = aRing.chatMasterId(bob)

        let second = aProc.handle(text: try p1(bob, bobTablet), chatId: bob, senderId: bob, ownUserId: alice, messageDate: t0 + 15)
        // PLAN.md 3.25.10 (2026-09-20): reported, not hidden. This used to be `duplicate` — nothing
        // written, nothing shown — because a second `P1` this soon was read as the peer's other device
        // losing the accept race. It is indistinguishable from the peer deliberately re-keying, which is
        // what the user hit on real phones.
        XCTAssertEqual(second?.pairing, .keyChanged)
        // PLAN.md 3.25.11: adopted on sight, so the tablet's key is the one in force now. In a private chat
        // there are only two parties, so "whichever the peer last announced" is a definition both sides can
        // agree on — and the shared `(at, device_id)` order keeps a re-read of the phone's older `P1` from
        // flipping it back.
        XCTAssertEqual(aRing.chatPairing(bob)?.state, .paired)
        XCTAssertNotEqual(aRing.chatMasterId(bob), phoneMaster)
        let tabletMaster = aRing.chatMasterId(bob)

        // The same key again is a repeat, and the phone's older announcement no longer moves anything.
        let later = aProc.handle(text: try p1(bob, bobTablet), chatId: bob, senderId: bob, ownUserId: alice, messageDate: t0 + 10 + 3600)
        XCTAssertEqual(later?.pairing, .alreadyPaired)
        let replayedPhone = aProc.handle(text: try p1(bob, bobPhone), chatId: bob, senderId: bob, ownUserId: alice, messageDate: t0 + 10)
        XCTAssertEqual(replayedPhone?.pairing, .duplicate)
        XCTAssertEqual(aRing.chatMasterId(bob), tabletMaster)
    }

    func testHistoryReplayOfAnOlderPeerKeyNeverTriggersKeyChanged() throws {
        let (aRing, aProc) = try peer()
        let (bobOld, _) = try peer()
        let (bobNew, _) = try peer()
        _ = try aProc.startPairing(chatId: bob, peerId: bob)
        XCTAssertEqual(aProc.handle(text: try p1(bob, bobNew), chatId: bob, senderId: bob, ownUserId: alice, messageDate: t0 + 500)?.pairing, .paired)
        let replay = aProc.handle(text: try p1(bob, bobOld), chatId: bob, senderId: bob, ownUserId: alice, messageDate: t0 - 5000)
        XCTAssertEqual(replay?.pairing, .duplicate)
        XCTAssertEqual(aRing.chatPairing(bob)?.state, .paired)
    }

    func testOwnAccountP1WithAnotherIdentityMakesThisDeviceStepOut() throws {
        let (aRing, _) = try peer()
        let (phoneRing, phoneProc) = try peer()
        let desktopClock = MovableClock()
        let (desktopRing, desktopProc) = try peer(desktopClock)
        let (laptopRing, laptopProc) = try peer()
        let aliceP1 = try p1(alice, aRing)

        // the desktop only saw the invite, never clicked: another device paired
        XCTAssertEqual(desktopProc.handle(text: aliceP1, chatId: alice, senderId: alice, ownUserId: bob, messageDate: t0)?.pairing, .incoming)
        let seenOnDesktop = desktopProc.handle(text: try p1(bob, phoneRing), chatId: alice, senderId: bob, ownUserId: bob, messageDate: t0 + 10)
        XCTAssertEqual(seenOnDesktop?.pairing, .otherDevice)
        XCTAssertEqual(desktopRing.chatPairing(alice)?.state, .otherDevice)
        XCTAssertFalse(desktopRing.isChatEncrypted(alice))
        // the peer's P1 arriving afterwards no longer reads as an invite
        XCTAssertEqual(desktopProc.handle(text: aliceP1, chatId: alice, senderId: alice, ownUserId: bob, messageDate: t0)?.pairing, .otherDevice)

        // the laptop also accepted, a moment too early: its own P1 is dated before the phone's, so the phone is
        // the one the peer ends up talking to (PLAN.md 3.25.11 flipped the direction) and the laptop's attempt
        // is void. "Too early" has to be in the message dates themselves (PLAN.md 3.7 rule 13) — they are the
        // only thing both devices can see — so the laptop's own echo lands first and stamps its date on
        // startedAt.
        _ = laptopProc.handle(text: aliceP1, chatId: alice, senderId: alice, ownUserId: bob, messageDate: t0)
        XCTAssertEqual(try laptopProc.startPairing(chatId: alice, peerId: alice), .paired)
        XCTAssertEqual(laptopProc.handle(text: try p1(bob, laptopRing), chatId: alice, senderId: bob, ownUserId: bob, messageDate: t0 + 5)?.pairing, .selfPaired)
        let lost = laptopProc.handle(text: try p1(bob, phoneRing), chatId: alice, senderId: bob, ownUserId: bob, messageDate: t0 + 10)
        XCTAssertEqual(lost?.pairing, .pairingLost)
        XCTAssertFalse(laptopRing.isChatEncrypted(alice))
        XCTAssertNil(laptopRing.chatMasterId(alice))

        // the phone itself only sees its own echo
        _ = phoneProc.handle(text: aliceP1, chatId: alice, senderId: alice, ownUserId: bob, messageDate: t0)
        _ = try phoneProc.startPairing(chatId: alice, peerId: alice)
        XCTAssertEqual(phoneProc.handle(text: try p1(bob, phoneRing), chatId: alice, senderId: bob, ownUserId: bob, messageDate: t0 + 10)?.pairing, .selfPaired)

        // Later the desktop re-pairs here: the phone learns the pairing moved and stops encrypting. "Later" is
        // on the desktop's own clock as well, because PLAN.md 3.25.6 rule 7 refuses a takeover that would land
        // inside the race window of the P1 it replaces; `confirmedTakeover` is what rule 2's confirmation
        // dialog passes once the user has read what a takeover costs the phone.
        desktopClock.ms = (t0 + 7200) * 1000
        XCTAssertEqual(try desktopProc.startPairing(chatId: alice, peerId: alice, confirmedTakeover: true), .paired)
        let moved = phoneProc.handle(text: try p1(bob, desktopRing), chatId: alice, senderId: bob, ownUserId: bob, messageDate: t0 + 7200)
        XCTAssertEqual(moved?.pairing, .pairingMoved)
        XCTAssertFalse(phoneRing.isChatEncrypted(alice))
        XCTAssertEqual(phoneRing.chatPairing(alice)?.state, .otherDevice)
    }

    func testAnOlderOwnP1ReplayedFromHistoryDoesNotDisturbTheCurrentPairing() throws {
        let (aRing, _) = try peer()
        let (bRing, bProc) = try peer()
        let (bobEarlier, _) = try peer()
        _ = bProc.handle(text: try p1(alice, aRing), chatId: alice, senderId: alice, ownUserId: bob, messageDate: t0)
        XCTAssertEqual(try bProc.startPairing(chatId: alice, peerId: alice), .paired)
        let stale = bProc.handle(text: try p1(bob, bobEarlier), chatId: alice, senderId: bob, ownUserId: bob, messageDate: t0 - 86_400)
        XCTAssertEqual(stale?.pairing, .duplicate)
        XCTAssertEqual(bRing.chatPairing(alice)?.state, .paired)
        XCTAssertTrue(bRing.isChatEncrypted(alice))
    }

    func testBothSidesStartAtOnceTheSecondP1CompletesWithoutAnAcceptStep() throws {
        let (aRing, aProc) = try peer()
        let (bRing, bProc) = try peer()
        XCTAssertEqual(try aProc.startPairing(chatId: bob, peerId: bob), .invited)
        XCTAssertEqual(try bProc.startPairing(chatId: alice, peerId: alice), .invited)
        XCTAssertEqual(aProc.handle(text: try p1(bob, bRing), chatId: bob, senderId: bob, ownUserId: alice, messageDate: t0 + 1)?.pairing, .paired)
        XCTAssertEqual(bProc.handle(text: try p1(alice, aRing), chatId: alice, senderId: alice, ownUserId: bob, messageDate: t0 + 1)?.pairing, .paired)
        XCTAssertEqual(aRing.chatMasterId(bob), bRing.chatMasterId(alice))
        XCTAssertEqual(aRing.chatPairing(bob)?.pairedAt, t0 + 1)
        // PLAN.md 3.7 rule 13: `startedAt` is this device's own P1's *server* date, so completing the pairing
        // does not fill it in — only that P1 echoing back does, and it has not yet.
        XCTAssertNil(aRing.chatPairing(bob)?.startedAt)
        XCTAssertEqual(aProc.handle(text: try p1(alice, aRing), chatId: bob, senderId: alice, ownUserId: alice, messageDate: t0 + 2)?.pairing, .selfPaired)
        XCTAssertEqual(aRing.chatPairing(bob)?.startedAt, t0 + 2)
    }
}

/// PLAN.md 3.25.3 / 3.25.6: device ids are recorded at the three points processor.ts records them, and a
/// clean takeover of this account's own pairing is flagged only on the own-device axis.
extension PairingFlowTests {
    func testCompletedPairingRecordsThePeersDeviceId() throws {
        let (aRing, aProc) = try peer()
        let (bRing, bProc) = try peer()
        _ = try aProc.startPairing(chatId: bob, peerId: bob)
        _ = bProc.handle(text: try p1(alice, aRing), chatId: alice, senderId: alice, ownUserId: bob)
        _ = try bProc.startPairing(chatId: alice, peerId: alice)
        _ = aProc.handle(text: try p1(bob, bRing), chatId: bob, senderId: bob, ownUserId: alice)

        let bobDeviceId = try DeviceIdentity.derive(x25519Pk: bRing.identity!.x25519Pk).deviceId
        XCTAssertEqual(aRing.chatPairing(bob)?.peerDeviceId, bobDeviceId)
        let aliceDeviceId = try DeviceIdentity.derive(x25519Pk: aRing.identity!.x25519Pk).deviceId
        XCTAssertEqual(bRing.chatPairing(alice)?.peerDeviceId, aliceDeviceId)
    }

    func testReplayedPeerP1RecordsItsDeviceIdWithoutTouchingTheBoundKey() throws {
        // PLAN.md 3.25.10 (2026-09-20): a replay — dated before the pairing it would displace — is the only
        // `P1` still swallowed. It carries nothing new by construction and is re-read on every scroll
        // through the history. The in-window case this test used to cover is `keyChanged` now.
        let (aRing, aProc) = try peer()
        let (bobPhone, _) = try peer()
        let (bobOld, _) = try peer()
        _ = try aProc.startPairing(chatId: bob, peerId: bob)
        _ = aProc.handle(text: try p1(bob, bobPhone), chatId: bob, senderId: bob, ownUserId: alice, messageDate: t0 + 10)
        _ = aProc.handle(text: try p1(bob, bobOld), chatId: bob, senderId: bob, ownUserId: alice, messageDate: t0 - 500)

        let phoneId = try DeviceIdentity.derive(x25519Pk: bobPhone.identity!.x25519Pk).deviceId
        let oldId = try DeviceIdentity.derive(x25519Pk: bobOld.identity!.x25519Pk).deviceId
        XCTAssertEqual(aRing.chatPairing(bob)?.peerDeviceId, phoneId)
        XCTAssertEqual(aRing.chatPairing(bob)?.peerSeenDeviceIds, [oldId])
        // still the phone's key — a lower bound on device count, nothing more
        XCTAssertEqual(aRing.memberPk(chatId: bob, userId: bob), bobPhone.identity!.x25519Pk)
    }

    func testKeyChangedMovesTheDisplacedPeerDeviceIdIntoTheSeenList() throws {
        let (aRing, aProc) = try peer()
        let (bRing, _) = try peer()
        _ = try aProc.startPairing(chatId: bob, peerId: bob)
        _ = aProc.handle(text: try p1(bob, bRing), chatId: bob, senderId: bob, ownUserId: alice)
        let oldId = try DeviceIdentity.derive(x25519Pk: bRing.identity!.x25519Pk).deviceId

        let (impostor, _) = try peer()
        // well after the accept race window, so this is a real key change and not a second device accepting
        _ = aProc.handle(text: try p1(bob, impostor), chatId: bob, senderId: bob, ownUserId: alice, messageDate: t0 + 3600)
        let newId = try DeviceIdentity.derive(x25519Pk: impostor.identity!.x25519Pk).deviceId

        // Adopted on sight since 3.25.11, so the chat is back on `paired` — but the displaced device_id still
        // moves into the seen list, which is what rule 3 is actually about
        XCTAssertEqual(aRing.chatPairing(bob)?.state, .paired)
        XCTAssertEqual(aRing.chatPairing(bob)?.peerDeviceId, newId)
        XCTAssertEqual(aRing.chatPairing(bob)?.peerSeenDeviceIds, [oldId])
    }

    /// This is the own-device axis (PLAN.md 3.25.1a), unrelated to the peer changing devices: device A wins
    /// the accept race first, another of this account's own devices (B) takes over, and re-pairing back on A
    /// — "在本机接管" — is what a clean takeover looks like: `ownDeviceId` still reads B until A's own P1
    /// echoes back, at which point exactly that completion is flagged.
    func testOwnDeviceIdIsRecordedOnTheAcceptRaceWinnerAndACleanTakeoverIsFlagged() throws {
        let (aRing, _) = try peer()
        let clockA = MovableClock()
        let (deviceA, procA) = try peer(clockA)
        let (deviceB, procB) = try peer()
        let aliceP1 = try p1(alice, aRing)

        // device A wins the accept race first
        _ = procA.handle(text: aliceP1, chatId: alice, senderId: alice, ownUserId: bob, messageDate: t0)
        XCTAssertEqual(try procA.startPairing(chatId: alice, peerId: alice), .paired)
        let selfPaired = procA.handle(text: try p1(bob, deviceA), chatId: alice, senderId: bob, ownUserId: bob, messageDate: t0 + 10)
        XCTAssertEqual(selfPaired?.pairing, .selfPaired)
        XCTAssertNil(selfPaired?.takeoverDeviceId)   // first time: nothing established yet to take over from
        let deviceAId = try DeviceIdentity.derive(x25519Pk: deviceA.identity!.x25519Pk).deviceId
        XCTAssertEqual(deviceA.chatPairing(alice)?.ownDeviceId, deviceAId)

        // device B (same account) re-pairs; its P1 also reaches device A, which steps out
        _ = procB.handle(text: aliceP1, chatId: alice, senderId: alice, ownUserId: bob, messageDate: t0)
        XCTAssertEqual(try procB.startPairing(chatId: alice, peerId: alice), .paired)
        let deviceBId = try DeviceIdentity.derive(x25519Pk: deviceB.identity!.x25519Pk).deviceId
        let stepOut = procA.handle(text: try p1(bob, deviceB), chatId: alice, senderId: bob, ownUserId: bob, messageDate: t0 + 7200)
        XCTAssertEqual(stepOut?.pairing, .pairingMoved)
        XCTAssertEqual(deviceA.chatPairing(alice)?.ownDeviceId, deviceBId)
        XCTAssertFalse(deviceA.isChatEncrypted(alice))

        // The user re-pairs on device A ("在本机接管"): ownDeviceId still reads B right after, and only once
        // A's own new P1 echoes back is the takeover actually recognised. An hour after B's P1 rather than the
        // 100 seconds a frozen clock would have made it, because PLAN.md 3.25.6 rule 7 refuses a takeover
        // inside the race window — the peer would discard it — and `confirmedTakeover` is rule 2's dialog.
        clockA.ms = (t0 + 10_800) * 1000
        XCTAssertEqual(try procA.startPairing(chatId: alice, peerId: alice, confirmedTakeover: true), .paired)
        XCTAssertEqual(deviceA.chatPairing(alice)?.ownDeviceId, deviceBId)
        let takenOver = procA.handle(text: try p1(bob, deviceA), chatId: alice, senderId: bob, ownUserId: bob, messageDate: t0 + 10_800)
        XCTAssertEqual(takenOver?.pairing, .selfPaired)
        XCTAssertEqual(takenOver?.takeoverDeviceId, deviceAId)
        XCTAssertEqual(deviceA.chatPairing(alice)?.ownDeviceId, deviceAId)
    }

    /// PLAN.md 3.25.3 rule 4 (unpair): the whole pairing record — including own/peer/seen device ids — is
    /// gone, but `deviceLabels` is untouched by an unpair, only by the emergency wipe (3.25.4 rule 3).
    func testUnpairClearsTheDeviceFieldsButNeverTheLabelsTable() throws {
        let (aRing, aProc) = try peer()
        let (bRing, _) = try peer()
        _ = try aProc.startPairing(chatId: bob, peerId: bob)
        _ = aProc.handle(text: try p1(bob, bRing), chatId: bob, senderId: bob, ownUserId: alice)
        let bobId = try DeviceIdentity.derive(x25519Pk: bRing.identity!.x25519Pk).deviceId
        try aRing.setDeviceLabel(deviceId: bobId, label: "老王的公司电脑")

        aProc.unpair(chatId: bob)
        XCTAssertNil(aRing.chatPairing(bob))
        XCTAssertEqual(aRing.deviceLabel(bobId)?.label, "老王的公司电脑")
    }
}

extension PairingFlowTests {
    func testPairedPeersRotateWithIdentityKeysAndCanUnpair() throws {
        let (aRing, aProc) = try peer()
        let (bRing, bProc) = try peer()
        _ = try aProc.startPairing(chatId: bob, peerId: bob)
        _ = bProc.handle(text: try p1(alice, aRing), chatId: alice, senderId: alice, ownUserId: bob)
        _ = try bProc.startPairing(chatId: alice, peerId: alice)
        _ = aProc.handle(text: try p1(bob, bRing), chatId: bob, senderId: bob, ownUserId: alice)

        let oldMaster = bRing.masterKey(for: bRing.chatMasterId(alice)!)!
        let fresh = KeyDerivation.generateMasterKey()
        let rotate = try Rekey.buildRotate(newMaster: fresh, oldMaster: oldMaster, adminSk: bRing.identity!.ed25519Sk, nowMs: vectorNowMs, epochDays: 1)
        try bRing.setChatMaster(chatId: alice, masterId: try bRing.addMaster(fresh), label: nil)
        XCTAssertEqual(bProc.handle(text: rotate.wire, chatId: alice, senderId: bob, ownUserId: bob)?.reason, "already_known")
        let applied = aProc.handle(text: rotate.wire, chatId: bob, senderId: bob, ownUserId: alice)
        XCTAssertTrue(applied?.ok ?? false, applied?.reason ?? "")
        XCTAssertEqual(aRing.chatMasterId(bob), bRing.chatMasterId(alice))

        let stranger = try Rekey.generateIdentity()
        let forged = try Rekey.buildRotate(newMaster: KeyDerivation.generateMasterKey(), oldMaster: fresh, adminSk: stranger.ed25519Sk, nowMs: vectorNowMs, epochDays: 1)
        XCTAssertEqual(aProc.handle(text: forged.wire, chatId: bob, senderId: bob, ownUserId: alice)?.reason, "bad_signature")

        let masterId = aRing.chatMasterId(bob)!
        aProc.unpair(chatId: bob)
        XCTAssertNil(aRing.chatPairing(bob))
        XCTAssertNil(aRing.chatMasterId(bob))
        XCTAssertNil(aRing.memberPk(chatId: bob, userId: bob))
        XCTAssertFalse(aRing.isChatEncrypted(bob))
        // PLAN.md 3.30 rule 6: the key goes with the pairing. `unpair` is purely local — nothing reaches the
        // peer, who keeps sending on the key it still holds — so leaving the material in the ring would let
        // this side go on opening those messages. Clearing the pointer is not clearing the key.
        XCTAssertFalse(aRing.listMasterIds().contains(masterId))
        XCTAssertEqual(aProc.handle(text: try p1(bob, bRing), chatId: bob, senderId: bob, ownUserId: alice)?.pairing, .incoming)
    }
}

extension PairingFlowTests {
    func testRekeyReminderCountsWholeDays() throws {
        var now: Int64 = vectorNowMs
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { now }, epochDays: 1, epochTolerance: 1)
        ring.rekeyReminderDays = 3
        XCTAssertNil(ring.keyAgeDays("c"))
        try ring.setChatMaster(chatId: "c", masterId: try ring.addMaster(KeyDerivation.generateMasterKey()), label: nil)
        XCTAssertEqual(ring.keyAgeDays("c"), 0)
        XCTAssertFalse(ring.isRekeyDue("c"))
        now += 3 * 86_400_000
        XCTAssertEqual(ring.keyAgeDays("c"), 3)
        XCTAssertTrue(ring.isRekeyDue("c"))
    }

    func testRatchetAdvancesDailyMatchesFutureKeysAndDestroysOldMasters() throws {
        var now: Int64 = 1_789_041_600_000 // 2026-09-10T12:00Z
        let a = KeyRing(storage: MemoryKeyRingStorage(), clock: { now }, epochDays: 1, epochTolerance: 1)
        let b = KeyRing(storage: MemoryKeyRingStorage(), clock: { now }, epochDays: 1, epochTolerance: 1)
        let base = KeyDerivation.generateMasterKey()
        for ring in [a, b] {
            let id = try ring.addMaster(base)
            try ring.setChatMaster(chatId: "c", masterId: id, label: "20260910")
            try ring.setChatRatchet(chatId: "c", label: "20260910", masterId: id)
        }
        let day0 = a.currentKey(chatId: "c")!
        XCTAssertTrue(day0.keyId.hasSuffix(".20260910"))
        now += 2 * 86_400_000
        let day2 = a.currentKey(chatId: "c")!
        XCTAssertTrue(day2.keyId.hasSuffix(".20260912"))
        XCTAssertNotEqual(day0.keyId.split(separator: ".")[0], day2.keyId.split(separator: ".")[0])
        XCTAssertEqual(a.chatRatchet("c")?.label, "20260912")
        XCTAssertEqual(b.chatRatchet("c")?.label, "20260910")
        XCTAssertEqual(b.lookupSessionKey(day2.keyId), day2.sessionKey)
        XCTAssertEqual(b.chatRatchet("c")?.label, "20260912")
        XCTAssertNil(a.lookupSessionKey(day0.keyId))
        XCTAssertFalse(a.listMasterIds().contains(String(day0.keyId.split(separator: ".")[0])))
        XCTAssertEqual(a.chatRatchet("c")?.masters.count, 2)
        let decoded = SnapshotCodec.decode(SnapshotCodec.encode(a.snapshot()))
        XCTAssertEqual(decoded?.chatRatchets["c"], a.chatRatchet("c"))
        XCTAssertEqual(decoded?.masterCreatedAt.count, a.snapshot().masterCreatedAt.count)
    }

    func testForwardSecrecySwitchesOnAndOffOverR1Ratchet() throws {
        var now: Int64 = vectorNowMs
        let make: () throws -> (KeyRing, RekeyProcessor) = {
            let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { now }, epochDays: 1, epochTolerance: 1)
            try ring.setIdentity(try Rekey.generateIdentity())
            return (ring, RekeyProcessor(ring: ring, clock: { now }))
        }
        let (aRing, aProc) = try make()
        let (bRing, bProc) = try make()
        _ = try aProc.startPairing(chatId: bob, peerId: bob)
        _ = bProc.handle(text: try p1(alice, aRing), chatId: alice, senderId: alice, ownUserId: bob)
        _ = try bProc.startPairing(chatId: alice, peerId: alice)
        _ = aProc.handle(text: try p1(bob, bRing), chatId: bob, senderId: bob, ownUserId: alice)

        let base = KeyDerivation.generateMasterKey()
        let ratchet = try Rekey.buildRatchet(baseMaster: base, oldMaster: aRing.masterKey(for: aRing.chatMasterId(bob)!)!, identityEdSk: aRing.identity!.ed25519Sk, nowMs: now, epochDays: 1)
        let baseId = try aRing.addMaster(base)
        try aRing.setChatMaster(chatId: bob, masterId: baseId, label: "20260911")
        try aRing.setChatRatchet(chatId: bob, label: "20260911", masterId: baseId)
        let r = bProc.handle(text: ratchet.wire, chatId: alice, senderId: alice, ownUserId: bob)
        XCTAssertTrue(r?.ok ?? false, r?.reason ?? "")
        XCTAssertEqual(r?.type, .ratchet)
        XCTAssertEqual(bRing.chatRatchet(alice)?.label, "20260911")

        now += 2 * 86_400_000
        let key = bRing.currentKey(chatId: alice)!
        XCTAssertTrue(key.keyId.hasSuffix(".20260913"))
        XCTAssertEqual(aRing.lookupSessionKey(key.keyId), key.sessionKey)
        XCTAssertEqual(aRing.chatRatchet(bob)?.label, "20260913")

        let fixed = KeyDerivation.generateMasterKey()
        let rotate = try Rekey.buildRotate(newMaster: fixed, oldMaster: bRing.masterKey(for: bRing.chatMasterId(alice)!)!, adminSk: bRing.identity!.ed25519Sk, nowMs: now, epochDays: 1)
        try bRing.setChatMaster(chatId: alice, masterId: try bRing.addMaster(fixed), label: "20260913")
        bRing.clearChatRatchet(alice)
        XCTAssertTrue(aProc.handle(text: rotate.wire, chatId: bob, senderId: bob, ownUserId: alice)?.ok ?? false)
        XCTAssertNil(aRing.chatRatchet(bob))
        XCTAssertEqual(aRing.chatMasterId(bob), bRing.chatMasterId(alice))
    }
}

// MARK: - unpair destroys the key material, not just this chat's pointer to it

extension PairingFlowTests {
    /// `RekeyProcessor.unpair` used to clear only `chatMasters[chatId]`, leaving `masters[masterId]` in place.
    /// `KeyRing.lookupSessionKey` resolves a key globally by the master id parsed out of the wire, with no chat
    /// scoping at all, so the master had to go too — and deleting the conversation never helped, because the key
    /// does not live in the conversation.
    func testUnpairDestroysTheChatsMasterKeyAndNotJustThePointerToIt() throws {
        let (aRing, aProc) = try peer()
        let (bRing, _) = try peer()
        _ = try aProc.startPairing(chatId: bob, peerId: bob)
        _ = aProc.handle(text: try p1(bob, bRing), chatId: bob, senderId: bob, ownUserId: alice)
        let masterId = try XCTUnwrap(aRing.chatMasterId(bob))
        XCTAssertTrue(aRing.listMasterIds().contains(masterId))

        aProc.unpair(chatId: bob)

        XCTAssertNil(aRing.chatMasterId(bob))
        XCTAssertFalse(aRing.listMasterIds().contains(masterId))
        XCTAssertNil(aRing.masterKey(for: masterId))
    }

    /// The property in the user's own terms. A and B are paired; A seals a message and B opens it. B unpairs —
    /// a purely local act A is never told about — and A, none the wiser, seals another on the very same key.
    /// B must open neither: not the new message, and not the one it had already read, because a key that is gone
    /// from storage but still answered out of the derived-session-key cache is not gone.
    func testAfterUnpairTheUntoldPeersMessagesStopOpeningIncludingTheAlreadyReadOne() throws {
        let (aRing, aProc) = try peer()
        let (bRing, bProc) = try peer()
        _ = try aProc.startPairing(chatId: bob, peerId: bob)
        _ = bProc.handle(text: try p1(alice, aRing), chatId: alice, senderId: alice, ownUserId: bob)
        _ = try bProc.startPairing(chatId: alice, peerId: alice)
        _ = aProc.handle(text: try p1(bob, bRing), chatId: bob, senderId: bob, ownUserId: alice)
        XCTAssertEqual(aRing.chatMasterId(bob), bRing.chatMasterId(alice))

        let key = try XCTUnwrap(aRing.currentKey(chatId: bob))
        let first = try E1Codec.encrypt(text: "before the unpair", entities: nil, keyId: key.keyId, sessionKey: key.sessionKey)
        let opened = E1Codec.decrypt(wire: first, lookup: bRing.lookupSessionKey)
        XCTAssertTrue(opened.ok, String(describing: opened.reason))
        XCTAssertEqual(opened.text, "before the unpair")

        bProc.unpair(chatId: alice)

        // A was never told, so it keeps sending on the key it still has.
        let second = try E1Codec.encrypt(text: "after the unpair", entities: nil, keyId: key.keyId, sessionKey: key.sessionKey)
        XCTAssertNil(bRing.lookupSessionKey(key.keyId))
        XCTAssertEqual(E1Codec.decrypt(wire: second, lookup: bRing.lookupSessionKey).reason, .unknownKey)
        // and the message B had already opened is shut again — the session-key cache went with the master
        XCTAssertEqual(E1Codec.decrypt(wire: first, lookup: bRing.lookupSessionKey).reason, .unknownKey)
    }

    /// Forward secrecy is the worst case, not the best. The chat's ratchet holds a *map* of label → masterId, so
    /// `clearChatRatchet` drops the ratchet record while every master in the chain stays in the flat `masters`
    /// store, fully usable. After an unpair none of the chain may remain.
    func testUnpairDestroysEveryMasterInARatchetChainNotJustTheCurrentOne() throws {
        var now: Int64 = 1_789_041_600_000 // 2026-09-10T12:00Z
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { now }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        let proc = RekeyProcessor(ring: ring, clock: { now })
        let base = KeyDerivation.generateMasterKey()
        let baseId = try ring.addMaster(base)
        try ring.setChatMaster(chatId: bob, masterId: baseId, label: "20260910")
        try ring.setChatRatchet(chatId: bob, label: "20260910", masterId: baseId)

        now += 86_400_000
        let dayOne = try XCTUnwrap(ring.currentKey(chatId: bob))
        XCTAssertTrue(dayOne.keyId.hasSuffix(".20260911"))
        let chain = try XCTUnwrap(ring.chatRatchet(bob)).masters
        XCTAssertEqual(chain.count, 2, "the chain must hold more than one master for this test to mean anything")
        for id in chain.values { XCTAssertTrue(ring.listMasterIds().contains(id)) }

        proc.unpair(chatId: bob)

        XCTAssertNil(ring.chatRatchet(bob))
        for (label, id) in chain {
            XCTAssertFalse(ring.listMasterIds().contains(id), "the master for \(label) survived the unpair")
        }
        XCTAssertTrue(ring.listMasterIds().isEmpty)
        XCTAssertNil(ring.lookupSessionKey(dayOne.keyId))
    }
}
