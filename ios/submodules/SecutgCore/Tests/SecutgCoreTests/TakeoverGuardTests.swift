import XCTest
@testable import SecutgCore

/// PLAN.md 3.25.6 rules 2b and 7: what `startPairing` refuses to do.
///
/// Rule 2 requires a takeover — starting a pairing here while another device of this account holds it — to go
/// through a confirmation that spells out three consequences. The guard sits in `startPairing` rather than at
/// each entry point because the entry points outlive the state: an invite dialog opened by a one-shot event is
/// still on screen after this device loses the race, and an old invite control line is drawn from the meta
/// computed when that message was first handled, so scrolling back brings it right back. Both still send.
///
/// Rule 7 is the second refusal: a takeover that lands within `pairingRaceWindowSeconds` of the winning `P1`
/// is discarded by the peer as a duplicate, and the sibling that holds the pairing does not step aside either,
/// so only the device that sent it believes it took over — and everything it encrypts afterwards is unreadable.
final class TakeoverGuardTests: XCTestCase {
    let alice = "501", bob = "502"
    /// Unix seconds of the frozen test clock
    let t0: Int64 = vectorNowMs / 1000

    /// A clock the test can move, so "now" can be placed inside or outside rule 7's window
    final class MovableClock {
        var ms: Int64
        init(_ ms: Int64) { self.ms = ms }
    }

    private func device(_ clock: MovableClock) throws -> (KeyRing, RekeyProcessor) {
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { clock.ms }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        return (ring, RekeyProcessor(ring: ring, clock: { clock.ms }))
    }

    private func p1(_ userId: String, _ ring: KeyRing) throws -> String {
        let id = ring.identity!
        return try Rekey.buildP1(userId: userId, x25519Pk: id.x25519Pk, ed25519Pk: id.ed25519Pk, ed25519Sk: id.ed25519Sk)
    }

    /// This device saw Alice's invite and then watched a sibling of this account win the pairing at `pairedAt`.
    /// That is the state both refusals are about, and `pairedAt` is what rule 7 measures: the server date of the
    /// winning `P1`, which is also the number the peer wrote down when that `P1` completed its pairing.
    private func outOfPlay(pairedAt: Int64, clock: MovableClock) throws -> (KeyRing, RekeyProcessor) {
        let (aliceRing, _) = try device(MovableClock(vectorNowMs))
        let (siblingRing, _) = try device(MovableClock(vectorNowMs))
        let here = try device(clock)
        _ = here.1.handle(text: try p1(alice, aliceRing), chatId: alice, senderId: alice, ownUserId: bob, messageDate: t0)
        _ = here.1.handle(text: try p1(bob, siblingRing), chatId: alice, senderId: bob, ownUserId: bob, messageDate: pairedAt)
        XCTAssertEqual(here.0.chatPairing(alice)?.state, .otherDevice)
        XCTAssertEqual(here.0.chatPairing(alice)?.pairedAt, pairedAt)
        return here
    }

    /// The gap rule 2b closes: a plain "accept" from a device that is out of the pairing used to send a real
    /// `P1` and take it away from the sibling, without a word about what that costs. It is refused instead, and
    /// the refusal is the caller's cue to go to the confirmation — not an error, because wanting this chat
    /// encrypted is a reasonable thing to have pressed a button for.
    func testAnAcceptOnAnOutOfPlayDeviceIsRefusedInsteadOfSilentlyTakingOver() throws {
        // A day later, so nothing here is rule 7's doing
        let clock = MovableClock(vectorNowMs + 86_400_000)
        let (ring, proc) = try outOfPlay(pairedAt: t0, clock: clock)
        let before = ring.chatPairing(alice)

        XCTAssertEqual(try proc.startPairing(chatId: alice, peerId: alice), .refused(.needsTakeover))

        // A refusal writes nothing: the chat is left exactly as it was, still out of play
        XCTAssertEqual(ring.chatPairing(alice), before)
        XCTAssertNil(ring.chatMasterId(alice))
        XCTAssertFalse(ring.isChatEncrypted(alice))
    }

    /// The other half of rule 2b: the confirmation dialog is the one caller that has told the user what a
    /// takeover costs, so it is the one caller that gets through.
    func testOnlyAConfirmedTakeoverGetsThrough() throws {
        let clock = MovableClock(vectorNowMs + 86_400_000)
        let (ring, proc) = try outOfPlay(pairedAt: t0, clock: clock)

        XCTAssertEqual(try proc.startPairing(chatId: alice, peerId: alice, confirmedTakeover: true), .paired)
        XCTAssertTrue(ring.isChatEncrypted(alice))
        XCTAssertEqual(ring.chatPairing(alice)?.state, .paired)
    }

    /// Rule 7's boundary. The peer discards a different key that arrives *within* the window of its own
    /// `pairedAt`, so `pairedAt + pairingRaceWindowSeconds` is the first moment a takeover survives.
    func testAConfirmedTakeoverIsRefusedUntilTheRaceWindowHasRunOut() throws {
        let clock = MovableClock(vectorNowMs)
        let (ring, proc) = try outOfPlay(pairedAt: t0, clock: clock)

        clock.ms = (t0 + RekeyProcessor.pairingRaceWindowSeconds - 1) * 1000
        XCTAssertEqual(try proc.startPairing(chatId: alice, peerId: alice, confirmedTakeover: true), .refused(.tooSoon))
        XCTAssertEqual(ring.chatPairing(alice)?.state, .otherDevice)
        XCTAssertNil(ring.chatMasterId(alice))
        XCTAssertFalse(ring.isChatEncrypted(alice))

        clock.ms = (t0 + RekeyProcessor.pairingRaceWindowSeconds) * 1000
        XCTAssertEqual(try proc.startPairing(chatId: alice, peerId: alice, confirmedTakeover: true), .paired)
    }

    /// The seconds the confirmation dialog has to quote, counted down as the window runs out.
    func testTheRemainingWaitCountsDownWithinTheWindow() throws {
        let window = RekeyProcessor.pairingRaceWindowSeconds
        let record = KeyRing.Pairing(peerId: alice, state: .otherDevice, verified: false, pairedAt: t0)
        XCTAssertEqual(RekeyProcessor.takeoverSwallowedSeconds(record, nowSeconds: t0), window)
        XCTAssertEqual(RekeyProcessor.takeoverSwallowedSeconds(record, nowSeconds: t0 + 1), window - 1)
        XCTAssertEqual(RekeyProcessor.takeoverSwallowedSeconds(record, nowSeconds: t0 + window - 1), 1)
        XCTAssertEqual(RekeyProcessor.takeoverSwallowedSeconds(record, nowSeconds: t0 + window), 0)
        XCTAssertEqual(RekeyProcessor.takeoverSwallowedSeconds(record, nowSeconds: t0 + window + 1), 0)
    }

    /// A clock that has been set back, or a record that has been edited, must not become "try again in three
    /// days". The answer is clamped to the window, which is the longest any genuine wait can be.
    func testTheRemainingWaitIsClampedToTheWindowWhenTheRecordLiesAhead() throws {
        let ahead = KeyRing.Pairing(peerId: alice, state: .otherDevice, verified: false, pairedAt: t0 + 3 * 86_400)
        XCTAssertEqual(RekeyProcessor.takeoverSwallowedSeconds(ahead, nowSeconds: t0),
                       RekeyProcessor.pairingRaceWindowSeconds)
    }

    /// Nothing is swallowed where there is no sibling pairing to be swallowed by, and a record from a build
    /// that never wrote the date cannot be measured — neither is a reason to refuse.
    func testNothingIsSwallowedWithoutAnOtherDeviceRecordCarryingADate() throws {
        XCTAssertEqual(RekeyProcessor.takeoverSwallowedSeconds(nil, nowSeconds: t0), 0)
        let paired = KeyRing.Pairing(peerId: alice, state: .paired, verified: false, pairedAt: t0)
        XCTAssertEqual(RekeyProcessor.takeoverSwallowedSeconds(paired, nowSeconds: t0), 0)
        let dateless = KeyRing.Pairing(peerId: alice, state: .otherDevice, verified: false)
        XCTAssertEqual(RekeyProcessor.takeoverSwallowedSeconds(dateless, nowSeconds: t0), 0)
    }

    /// Every state but `otherDevice` is this device's own business — `invited`, `paired`, `key_changed` and no
    /// pairing at all all mean the pairing is here or nowhere, and re-pairing costs no other device its own.
    func testAChatThisDeviceStillHoldsIsNeverRefused() throws {
        let clock = MovableClock(vectorNowMs)
        let (_, proc) = try device(clock)

        XCTAssertNil(proc.takeoverRefusal(chatId: bob, confirmedTakeover: false))
        XCTAssertEqual(try proc.startPairing(chatId: bob, peerId: bob), .invited)
        XCTAssertNil(proc.takeoverRefusal(chatId: bob, confirmedTakeover: false))
    }

    /// Why the refusal is also reachable on its own: `regenerateAndRepair` throws this device's identity key
    /// pair away before it pairs, so it has to be able to learn the refusal *before* taking that step.
    /// Regenerating first and being refused afterwards would leave a device with a new identity, no pairing in
    /// this chat, and every other auto-paired chat bound to a key that no longer exists — worse than the
    /// takeover it declined, and with no way back. So this answers without writing, however often it is asked.
    func testTheRefusalCanBeAskedBeforeAnythingIrreversibleHappens() throws {
        let clock = MovableClock(vectorNowMs + 86_400_000)
        let (ring, proc) = try outOfPlay(pairedAt: t0, clock: clock)
        let identity = ring.identity?.x25519Pk
        let before = ring.chatPairing(alice)

        XCTAssertEqual(proc.takeoverRefusal(chatId: alice, confirmedTakeover: false), .needsTakeover)
        XCTAssertEqual(proc.takeoverRefusal(chatId: alice, confirmedTakeover: false), .needsTakeover)

        XCTAssertEqual(ring.identity?.x25519Pk, identity)
        XCTAssertEqual(ring.chatPairing(alice), before)
        XCTAssertNil(ring.chatMasterId(alice))
        XCTAssertFalse(ring.isChatEncrypted(alice))
    }

    /// `regenerateAndRepair` deliberately does not offer `confirmedTakeover`: the dialog in front of it warns
    /// about a new identity, which is not what a takeover costs the other device.
    func testAnUnconfirmedRefusalStandsEvenOnceTheWindowHasPassed() throws {
        let clock = MovableClock(vectorNowMs)
        let (_, proc) = try outOfPlay(pairedAt: t0, clock: clock)

        clock.ms = (t0 + 7200) * 1000
        XCTAssertEqual(proc.takeoverRefusal(chatId: alice, confirmedTakeover: false), .needsTakeover)
        XCTAssertNil(proc.takeoverRefusal(chatId: alice, confirmedTakeover: true))
    }
}
