import XCTest
@testable import SecutgCore

/// The pure rule, on its own (PLAN.md 3.7 rules 8 / 13, direction per 3.25.11), mirroring Web A
/// `src/secutg/rekey/ownP1Race.test.ts`.
final class OwnP1RaceTests: XCTestCase {
    let w = RekeyProcessor.pairingRaceWindowSeconds
    let t: Int64 = 1_789_000_000
    func claim(_ at: Int64, _ deviceId: String) -> OwnP1Race.Claim { return OwnP1Race.Claim(at: at, deviceId: deviceId) }

    func testInsideTheWindowTheLaterP1WinsWhicheverSideIsAsking() {
        XCTAssertEqual(OwnP1Race.judge(holder: claim(t + 10, "bb"), incoming: claim(t + 5, "aa"), windowSeconds: w), .won)
        XCTAssertEqual(OwnP1Race.judge(holder: claim(t + 5, "aa"), incoming: claim(t + 10, "bb"), windowSeconds: w), .lost)
    }

    func testAnExactTieIsBrokenByDeviceIdAndOnlyByDeviceId() {
        // The larger device_id wins now: `sortsFirst` still sorts "aa" before "bb", the verdict just reads the
        // order the other way round (3.25.11)
        XCTAssertEqual(OwnP1Race.judge(holder: claim(t, "bb"), incoming: claim(t, "aa"), windowSeconds: w), .won)
        XCTAssertEqual(OwnP1Race.judge(holder: claim(t, "aa"), incoming: claim(t, "bb"), windowSeconds: w), .lost)
        // The same P1 seen twice is nobody's competitor
        XCTAssertEqual(OwnP1Race.judge(holder: claim(t, "aa"), incoming: claim(t, "aa"), windowSeconds: w), .won)
    }

    /// Since 3.25.11 later wins on both sides of the window, so these two verdicts no longer change *what
    /// happens* — `olderRound` behaves like `won` and `newerRound` like `lost`. They are still distinguished
    /// because the five clients tell the user something different about each.
    func testOutsideTheWindowItIsNotARaceAtAll() {
        XCTAssertEqual(OwnP1Race.judge(holder: claim(t, "aa"), incoming: claim(t - w - 1, "bb"), windowSeconds: w), .olderRound)
        XCTAssertEqual(OwnP1Race.judge(holder: claim(t, "aa"), incoming: claim(t + w + 1, "bb"), windowSeconds: w), .newerRound)
        // The boundary itself still counts as the same round, on both sides
        XCTAssertEqual(OwnP1Race.judge(holder: claim(t, "aa"), incoming: claim(t - w, "bb"), windowSeconds: w), .won)
        XCTAssertEqual(OwnP1Race.judge(holder: claim(t, "aa"), incoming: claim(t + w, "bb"), windowSeconds: w), .lost)
    }

    func testADeviceThatNeverSentAP1HereHasNoClaimAndYieldsToAnySibling() {
        XCTAssertEqual(OwnP1Race.judge(holder: nil, incoming: claim(t, "aa"), windowSeconds: w), .lost)
        XCTAssertEqual(OwnP1Race.judge(holder: nil, incoming: claim(t - 99_999, "aa"), windowSeconds: w), .lost)
    }

    /// The property the whole design rests on: run the rule on two devices with the arguments swapped and they
    /// never both keep the pairing, and never both drop it. Anything else is the fork this rule exists to prevent.
    func testTwoDevicesGivenTheSamePairOfFactsAlwaysReachOppositeVerdicts() {
        let dates: [Int64] = [t - w - 1, t - w, t - 1, t, t + 1, t + w, t + w + 1]
        let ids = ["0a", "f2", "ff"]
        /// "keeps the pairing" = the sibling's P1 does not displace it: won, or a replay from another round
        func keepsIt(_ holder: OwnP1Race.Claim, _ incoming: OwnP1Race.Claim) -> Bool {
            let verdict = OwnP1Race.judge(holder: holder, incoming: incoming, windowSeconds: w)
            return verdict != .lost && verdict != .newerRound
        }
        var compared = 0
        for mineAt in dates { for mineId in ids { for otherAt in dates { for otherId in ids {
            if mineAt == otherAt && mineId == otherId { continue }
            let mine = claim(mineAt, mineId), other = claim(otherAt, otherId)
            compared += 1
            XCTAssertNotEqual(keepsIt(mine, other), keepsIt(other, mine), "\(mineAt)/\(mineId) vs \(otherAt)/\(otherId)")
        } } } }
        XCTAssertGreaterThan(compared, 300)
    }
}

/// PLAN.md 3.7 rules 8 / 13 through the processor, direction flipped by 3.25.11: the peer holds one invite open
/// and two of this account's devices answer it before either has seen the other. The peer adopts a changed key on
/// sight, so it ends on the LATEST P1 and calls the earlier one a duplicate; both of our devices have to reach
/// that same verdict on their own, from the message dates the chat gives all three of them. Mirrors Web A
/// `rekey.test.ts` "two devices of this account answer the same invite".
final class OwnP1RaceFlowTests: XCTestCase {
    let alice = "501", bob = "502"
    let inviteAt: Int64 = vectorNowMs / 1000
    var early: Int64 { inviteAt + 5 }
    var late: Int64 { inviteAt + 10 }

    /// A device of this account whose own wall clock reads `at`
    func device(at seconds: Int64) throws -> (KeyRing, RekeyProcessor) {
        let ms = seconds * 1000
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { ms }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        return (ring, RekeyProcessor(ring: ring, clock: { ms }))
    }

    func p1(_ userId: String, _ ring: KeyRing) throws -> String {
        let id = ring.identity!
        return try Rekey.buildP1(userId: userId, x25519Pk: id.x25519Pk, ed25519Pk: id.ed25519Pk, ed25519Sk: id.ed25519Sk)
    }

    func deviceId(_ ring: KeyRing) throws -> String {
        return try DeviceIdentity.derive(x25519Pk: ring.identity!.x25519Pk).deviceId
    }

    /// One device sees the invite, taps accept, and watches its own P1 come back from the server
    func accept(_ device: (KeyRing, RekeyProcessor), from inviter: KeyRing, sentAt: Int64) throws {
        _ = device.1.handle(text: try p1(alice, inviter), chatId: alice, senderId: alice, ownUserId: bob, messageDate: inviteAt)
        _ = try device.1.startPairing(chatId: alice, peerId: alice)
        _ = device.1.handle(text: try p1(bob, device.0), chatId: alice, senderId: bob, ownUserId: bob, messageDate: sentAt)
    }

    /// A sibling's P1 arriving in this chat, as this device sees it
    func sibling(_ device: (KeyRing, RekeyProcessor), _ other: KeyRing, at: Int64) throws -> RekeyProcessor.Result? {
        return device.1.handle(text: try p1(bob, other), chatId: alice, senderId: bob, ownUserId: bob, messageDate: at)
    }

    func testTheLatestP1KeepsThePairingAndTheWinnerIgnoresTheEarlierSibling() throws {
        let (aliceRing, _) = try device(at: inviteAt)
        let winner = try device(at: late)
        let loser = try device(at: early)
        try accept(winner, from: aliceRing, sentAt: late)
        let master = winner.0.chatMasterId(alice)

        XCTAssertEqual(try sibling(winner, loser.0, at: early)?.pairing, .duplicate)
        XCTAssertEqual(winner.0.chatPairing(alice)?.state, .paired)
        XCTAssertEqual(winner.0.chatPairing(alice)?.ownDeviceId, try deviceId(winner.0))
        XCTAssertTrue(winner.0.isChatEncrypted(alice))
        XCTAssertEqual(winner.0.chatMasterId(alice), master)
    }

    func testTheEarlierP1LosesAndThatDeviceStepsOutEvenThoughItAlreadyPaired() throws {
        let (aliceRing, _) = try device(at: inviteAt)
        let winner = try device(at: late)
        let loser = try device(at: early)
        try accept(loser, from: aliceRing, sentAt: early)

        XCTAssertEqual(try sibling(loser, winner.0, at: late)?.pairing, .pairingLost)
        XCTAssertEqual(loser.0.chatPairing(alice)?.state, .otherDevice)
        XCTAssertEqual(loser.0.chatPairing(alice)?.ownDeviceId, try deviceId(winner.0))
        XCTAssertFalse(loser.0.isChatEncrypted(alice))
        XCTAssertNil(loser.0.chatMasterId(alice))
    }

    /// The one that pins "no fork": one set of messages, three devices, one surviving pairing
    func testPeerAndBothDevicesAgreeOnTheHolderAndOnlyTheHolderStillEncrypts() throws {
        let (aliceRing, aliceProc) = try device(at: inviteAt)
        let winner = try device(at: late)
        let loser = try device(at: early)
        _ = try aliceProc.startPairing(chatId: bob, peerId: bob)
        _ = aliceProc.handle(text: try p1(bob, loser.0), chatId: bob, senderId: bob, ownUserId: alice, messageDate: early)
        // The peer adopts the later key on sight (3.25.11), which is exactly why the later P1 is the winner here
        _ = aliceProc.handle(text: try p1(bob, winner.0), chatId: bob, senderId: bob, ownUserId: alice, messageDate: late)

        try accept(loser, from: aliceRing, sentAt: early)
        try accept(winner, from: aliceRing, sentAt: late)
        _ = try sibling(winner, loser.0, at: early)
        _ = try sibling(loser, winner.0, at: late)

        let winnerId = try deviceId(winner.0)
        XCTAssertEqual(winner.0.chatPairing(alice)?.ownDeviceId, winnerId)
        XCTAssertEqual(loser.0.chatPairing(alice)?.ownDeviceId, winnerId)
        XCTAssertEqual([winner.0, loser.0].filter { $0.isChatEncrypted(alice) }.count, 1)
        // The surviving pairing is the one the peer actually adopted: same master on both ends
        XCTAssertEqual(winner.0.chatMasterId(alice), aliceRing.chatMasterId(bob))
    }

    func testTheVerdictDoesNotDependOnWhichP1ThisDeviceProcessesFirst() throws {
        let (aliceRing, _) = try device(at: inviteAt)
        let winner = try device(at: late)
        let loser = try device(at: early)

        // The winner meets the sibling's P1 before its own echo gets back
        _ = winner.1.handle(text: try p1(alice, aliceRing), chatId: alice, senderId: alice, ownUserId: bob, messageDate: inviteAt)
        _ = try winner.1.startPairing(chatId: alice, peerId: alice)
        XCTAssertEqual(try sibling(winner, loser.0, at: early)?.pairing, .duplicate)
        XCTAssertEqual(try sibling(winner, winner.0, at: late)?.pairing, .selfPaired)
        XCTAssertEqual(winner.0.chatPairing(alice)?.state, .paired)
        XCTAssertEqual(winner.0.chatPairing(alice)?.ownDeviceId, try deviceId(winner.0))
        XCTAssertTrue(winner.0.isChatEncrypted(alice))
    }

    func testTwoP1sInTheSameSecondAreSplitByDeviceIdAndBothDevicesSplitThemTheSameWay() throws {
        let (aliceRing, _) = try device(at: inviteAt)
        let tie = inviteAt + 7
        let one = try device(at: tie)
        let two = try device(at: tie)
        try accept(one, from: aliceRing, sentAt: tie)
        try accept(two, from: aliceRing, sentAt: tie)

        _ = try sibling(one, two.0, at: tie)
        _ = try sibling(two, one.0, at: tie)
        // The LARGER device_id takes it now: `sortsFirst` is unchanged, the verdict just reads it the other
        // way round since 3.25.11, and the peer breaks the same tie the same way
        let winnerId = [try deviceId(one.0), try deviceId(two.0)].sorted()[1]
        XCTAssertEqual(one.0.chatPairing(alice)?.ownDeviceId, winnerId)
        XCTAssertEqual(two.0.chatPairing(alice)?.ownDeviceId, winnerId)
        XCTAssertEqual([one.0, two.0].filter { $0.isChatEncrypted(alice) }.count, 1)
    }

    func testTheLosersOwnP1ArrivingAfterwardsDoesNotTakeThePairingBack() throws {
        let (aliceRing, _) = try device(at: inviteAt)
        let winner = try device(at: late)
        let loser = try device(at: early)
        _ = loser.1.handle(text: try p1(alice, aliceRing), chatId: alice, senderId: alice, ownUserId: bob, messageDate: inviteAt)
        _ = try loser.1.startPairing(chatId: alice, peerId: alice)
        _ = try sibling(loser, winner.0, at: late)

        // The sibling arrived before this device's own echo, so it was parked; the echo makes the two server
        // dates comparable and the loss is decided — and rendered — on this device's own P1 line.
        let echo = try sibling(loser, loser.0, at: early)
        XCTAssertEqual(echo?.pairing, .pairingLost)
        XCTAssertNil(echo?.takeoverDeviceId)
        XCTAssertEqual(loser.0.chatPairing(alice)?.state, .otherDevice)
        XCTAssertEqual(loser.0.chatPairing(alice)?.ownDeviceId, try deviceId(winner.0))
        XCTAssertFalse(loser.0.isChatEncrypted(alice))

        // The same P1 rebuilt from history a second time, now that this device is out, takes nothing back
        let again = try sibling(loser, loser.0, at: early)
        XCTAssertEqual(again?.pairing, .duplicate)
        XCTAssertNil(again?.takeoverDeviceId)
        XCTAssertEqual(loser.0.chatPairing(alice)?.ownDeviceId, try deviceId(winner.0))
    }

    func testASiblingP1FromBeforeThisRoundIsStillAHistoryReplayNotACompetitor() throws {
        let (aliceRing, _) = try device(at: inviteAt)
        let stale = try device(at: late - 86_400)
        let here = try device(at: late)
        try accept(here, from: aliceRing, sentAt: late)

        XCTAssertEqual(try sibling(here, stale.0, at: late - 86_400)?.pairing, .duplicate)
        XCTAssertEqual(here.0.chatPairing(alice)?.state, .paired)
        XCTAssertEqual(here.0.chatPairing(alice)?.ownDeviceId, try deviceId(here.0))
        XCTAssertTrue(here.0.isChatEncrypted(alice))
    }

    func testASiblingP1FromAfterTheWindowIsADeliberateRePairNotARace() throws {
        let (aliceRing, _) = try device(at: inviteAt)
        let here = try device(at: early)
        let other = try device(at: early + 3600)
        try accept(here, from: aliceRing, sentAt: early)

        XCTAssertEqual(try sibling(here, other.0, at: early + 3600)?.pairing, .pairingMoved)
        XCTAssertEqual(here.0.chatPairing(alice)?.state, .otherDevice)
        XCTAssertEqual(here.0.chatPairing(alice)?.ownDeviceId, try deviceId(other.0))
        XCTAssertFalse(here.0.isChatEncrypted(alice))
    }

    /// The echo is the only place a server date ever reaches `startedAt`. `startPairing` writes nothing there:
    /// the only clock it can reach is this machine's, which a sibling has never seen and cannot reproduce.
    func testTheOwnEchoIsTheOnlyWriterOfStartedAt() throws {
        let (aliceRing, _) = try device(at: inviteAt)
        let here = try device(at: inviteAt)
        _ = here.1.handle(text: try p1(alice, aliceRing), chatId: alice, senderId: alice, ownUserId: bob, messageDate: inviteAt)
        _ = try here.1.startPairing(chatId: alice, peerId: alice)
        XCTAssertNil(here.0.chatPairing(alice)?.startedAt)

        XCTAssertEqual(try sibling(here, here.0, at: late)?.pairing, .selfPaired)
        XCTAssertEqual(here.0.chatPairing(alice)?.startedAt, late)
        // An echo of one of our own P1s from an earlier round must not drag it back
        _ = try sibling(here, here.0, at: late - 86_400)
        XCTAssertEqual(here.0.chatPairing(alice)?.startedAt, late)
    }
}

/// PLAN.md 3.7 rule 13, the half that makes the comparison honest (Web A commit `ca9e0e93`): the verdict is
/// always taken between **two server dates**.
///
/// A sibling's `P1` carries one. This device's own carries one too — but only once it has echoed back, because
/// `startPairing` runs before the message exists and the only clock it can reach is this machine's, which the
/// sibling has never seen and cannot reproduce. Comparing the two puts a server date against a wall clock: a
/// device whose clock is a little fast reads the genuinely earlier sibling as later and keeps a pairing the peer
/// never adopted — and the sibling, reading the same facts equally wrongly, keeps its own.
///
/// So `startedAt` stays empty until the echo writes it, and a sibling arriving while it is empty is parked
/// rather than judged. Stepping out instead would be worse in the same situation: both devices would step out,
/// nobody would encrypt, and the peer would go on encrypting to a pairing no device of ours holds.
final class OwnEchoParkingTests: XCTestCase {
    let alice = "501", bob = "502"
    let t: Int64 = vectorNowMs / 1000

    /// A device of this account whose own wall clock reads `wallClock`
    func device(wallClock: Int64) throws -> (KeyRing, RekeyProcessor) {
        let ms = wallClock * 1000
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { ms }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        return (ring, RekeyProcessor(ring: ring, clock: { ms }))
    }

    func p1(_ ring: KeyRing) throws -> String {
        let id = ring.identity!
        return try Rekey.buildP1(userId: bob, x25519Pk: id.x25519Pk, ed25519Pk: id.ed25519Pk, ed25519Sk: id.ed25519Sk)
    }

    func deviceId(_ ring: KeyRing) throws -> String {
        return try DeviceIdentity.derive(x25519Pk: ring.identity!.x25519Pk).deviceId
    }

    /// One `P1` of this account reaching the chat, as `device` sees it. `from` is the device that sent it, so
    /// `from` being `device` itself is that device's own echo.
    @discardableResult
    func deliver(_ device: (KeyRing, RekeyProcessor), from sender: KeyRing, at: Int64) throws -> RekeyProcessor.Result? {
        return device.1.handle(text: try p1(sender), chatId: alice, senderId: bob, ownUserId: bob, messageDate: at)
    }

    func testStartPairingLeavesStartedAtEmptyBecauseOnlyTheEchoEverCarriesAServerDate() throws {
        let here = try device(wallClock: t)
        XCTAssertEqual(try here.1.startPairing(chatId: alice, peerId: alice), .invited)
        XCTAssertEqual(here.0.chatPairing(alice)?.state, .invited)
        XCTAssertNil(here.0.chatPairing(alice)?.startedAt)

        try deliver(here, from: here.0, at: t + 7)
        XCTAssertEqual(here.0.chatPairing(alice)?.startedAt, t + 7)
    }

    /// The fork the whole rule exists to prevent, reproduced with the one input a wall clock can get wrong:
    /// two devices whose clocks agree with each other but not with the server. Judged locally, **both** of them
    /// read their own `P1` as the earlier one and both keep the pairing.
    func testTwoDevicesWithSkewedClocksMustNotBothKeepThePairing() throws {
        let sooner = try device(wallClock: t)
        let later = try device(wallClock: t)
        _ = try sooner.1.startPairing(chatId: alice, peerId: alice)
        _ = try later.1.startPairing(chatId: alice, peerId: alice)

        // Each device meets its sibling's P1 before its own echo gets back, which is the situation the rule is
        // about: the server dated them t+5 and t+10, and neither device's clock knows that yet.
        try deliver(sooner, from: later.0, at: t + 10)
        try deliver(later, from: sooner.0, at: t + 5)
        try deliver(sooner, from: sooner.0, at: t + 5)
        try deliver(later, from: later.0, at: t + 10)

        let holding = [sooner.0, later.0].filter { $0.chatPairing(alice)?.state != .otherDevice }
        XCTAssertEqual(holding.count, 1, "exactly one device may keep the pairing")
        // The later of the two server dates is the one the peer settles on (3.25.11), so both devices name it
        XCTAssertEqual(sooner.0.chatPairing(alice)?.ownDeviceId, try deviceId(later.0))
        XCTAssertEqual(later.0.chatPairing(alice)?.ownDeviceId, try deviceId(later.0))
    }

    /// The other half of parking: the delayed verdict has to be rendered somewhere, and the only line left to
    /// render it on is this device's own `P1` — the sibling's line has already been drawn as a duplicate.
    func testTheDelayedLossIsReportedOnThisDevicesOwnEchoNotOnTheSibling() throws {
        let winner = try device(wallClock: t)
        let loser = try device(wallClock: t)
        _ = try loser.1.startPairing(chatId: alice, peerId: alice)

        // Parked: nothing decided, nothing written, and this device still holds its own pairing
        XCTAssertEqual(try deliver(loser, from: winner.0, at: t + 10)?.pairing, .duplicate)
        XCTAssertEqual(loser.0.chatPairing(alice)?.state, .invited)
        XCTAssertNil(loser.0.chatPairing(alice)?.startedAt)

        // The echo makes the two dates comparable, so the verdict lands on that line — this device's own P1 is
        // the earlier of the two, which is what loses since 3.25.11
        XCTAssertEqual(try deliver(loser, from: loser.0, at: t + 5)?.pairing, .pairingLost)
        XCTAssertEqual(loser.0.chatPairing(alice)?.state, .otherDevice)
        XCTAssertEqual(loser.0.chatPairing(alice)?.ownDeviceId, try deviceId(winner.0))
        XCTAssertFalse(loser.0.isChatEncrypted(alice))
    }

    /// Parking waits for a comparison that is coming. A device that never sent a `P1` here has nothing to wait
    /// for, so it must still yield at once rather than sit on a claim no echo will ever release.
    func testADeviceThatNeverSentAP1HereYieldsAtOnceBecauseNoEchoIsComing() throws {
        let here = try device(wallClock: t)
        let other = try device(wallClock: t)
        XCTAssertEqual(try deliver(here, from: other.0, at: t)?.pairing, .otherDevice)
        XCTAssertEqual(here.0.chatPairing(alice)?.state, .otherDevice)
        XCTAssertEqual(here.0.chatPairing(alice)?.ownDeviceId, try deviceId(other.0))
    }

    /// A device that has already stepped out holds no claim to defend: the record it keeps is a server date, so
    /// every later sibling can be judged on the spot and nothing may be parked.
    func testNothingIsParkedOnceThisDeviceHasAlreadySteppedOut() throws {
        let here = try device(wallClock: t)
        let other = try device(wallClock: t)
        try deliver(here, from: other.0, at: t + 5)
        XCTAssertEqual(here.0.chatPairing(alice)?.state, .otherDevice)

        // Its own losing P1 echoing back afterwards must not reopen anything (PLAN.md 3.25.3 rule 1)
        XCTAssertEqual(try deliver(here, from: here.0, at: t + 9)?.pairing, .duplicate)
        XCTAssertEqual(here.0.chatPairing(alice)?.ownDeviceId, try deviceId(other.0))
    }

    /// `startPairing` opens a new round (PLAN.md 3.7 rule 9), so a sibling parked during the previous one is no
    /// longer a competitor and must not be judged against the new round's echo.
    func testANewRoundForgetsTheClaimsParkedDuringThePreviousOne() throws {
        let here = try device(wallClock: t)
        let other = try device(wallClock: t)
        _ = try here.1.startPairing(chatId: alice, peerId: alice)
        XCTAssertEqual(try deliver(here, from: other.0, at: t + 5)?.pairing, .duplicate)

        _ = try here.1.startPairing(chatId: alice, peerId: alice)
        XCTAssertEqual(try deliver(here, from: here.0, at: t + 100)?.pairing, .selfInvited)
        XCTAssertEqual(here.0.chatPairing(alice)?.state, .invited)
        XCTAssertEqual(here.0.chatPairing(alice)?.ownDeviceId, try deviceId(here.0))
    }
}
