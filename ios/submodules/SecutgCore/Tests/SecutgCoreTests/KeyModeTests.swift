import XCTest
@testable import SecutgCore

/// PLAN.md 3.34.1 — the key's mode travels with the key.
///
/// Auto / manual is not a per-device switch: it is chosen once when the key is made and then rides in the QR
/// payload and in the `N1` that announces it, so every member reads the same answer.
final class KeyModePayloadTests: XCTestCase {
    let master = [UInt8](repeating: 0x42, count: 32)
    let adminPk = [UInt8](repeating: 0x11, count: 32)

    func testModeIsAppendedLastSoStrippingItLeavesExactlyWhatOlderBuildsSent() {
        let withMode = KeyPayload.build(masterKey: master, adminPk: adminPk, mode: .auto)
        let without = KeyPayload.build(masterKey: master, adminPk: adminPk)
        XCTAssertEqual(withMode, without + "&mode=auto")
        XCTAssertEqual(KeyPayload.parse(withMode)?.mode, .auto)
        XCTAssertEqual(KeyPayload.parse(withMode)?.adminPk, adminPk)
    }

    /// A payload from an older build carries none. `manual` is the reading that sends the user to a person
    /// rather than leaving them waiting for a key nobody is going to send.
    func testAPayloadWithoutAModeReadsAsManual() {
        XCTAssertEqual(KeyPayload.parse(KeyPayload.build(masterKey: master, adminPk: adminPk))?.mode, .manual)
        XCTAssertEqual(KeyPayload.parse(KeyPayload.build(masterKey: master, adminPk: nil))?.mode, .manual)
    }

    /// Not defaulted: an unrecognised mode is a payload from a build that knows something this one does not
    func testAnUnrecognisedModeIsRefusedOutright() {
        XCTAssertNil(KeyPayload.parse(KeyPayload.build(masterKey: master, adminPk: adminPk) + "&mode=sometimes"))
        XCTAssertNil(KeyPayload.parse(KeyPayload.build(masterKey: master, adminPk: adminPk) + "&mode="))
    }

    func testTheModeSurvivesAPayloadWithNoAdminKey() {
        let text = KeyPayload.build(masterKey: master, adminPk: nil, mode: .manual)
        let parsed = KeyPayload.parse(text)
        XCTAssertEqual(parsed?.mode, .manual)
        XCTAssertNil(parsed?.adminPk)
        XCTAssertEqual(parsed?.masterKey, master)
    }
}

final class KeyModeRingTests: XCTestCase {
    let group = "-3001"

    func makeRing() -> KeyRing {
        return KeyRing(storage: MemoryKeyRingStorage(), clock: { 1_789_300_000_000 }, epochDays: 1, epochTolerance: 1)
    }

    /// Unknown reads as `manual` everywhere. Guessing `auto` would leave a member waiting for a key nobody is
    /// going to send; guessing `manual` only tells them to go and ask, which is never wrong, only slower.
    func testAnUnknownChatReadsAsManual() {
        XCTAssertEqual(makeRing().chatKeyMode(group), .manual)
    }

    func testTheModeIsRememberedAndListed() {
        let ring = makeRing()
        ring.setChatKeyMode(chatId: group, .auto)
        XCTAssertEqual(ring.chatKeyMode(group), .auto)
        XCTAssertEqual(ring.listChatKeyModes(), [group: .auto])
    }

    /// The mode is a property of the key, so it goes when the key does — PLAN.md 3.34.1. A retire notice writes
    /// the new one back afterwards, which is why `handleN1` does that strictly after unbinding.
    func testUnbindingTheChatsMasterDropsTheMode() throws {
        let ring = makeRing()
        let masterId = try ring.addMaster(KeyDerivation.generateMasterKey())
        try ring.setChatMaster(chatId: group, masterId: masterId, label: nil)
        ring.setChatKeyMode(chatId: group, .auto)
        ring.clearChatMaster(group)
        XCTAssertEqual(ring.chatKeyMode(group), .manual)
    }

    func testTheModeSurvivesASnapshotRoundTrip() {
        let ring = makeRing()
        ring.setChatKeyMode(chatId: group, .auto)
        let decoded = SnapshotCodec.decode(SnapshotCodec.encode(ring.snapshot()))
        XCTAssertEqual(decoded?.chatKeyModes, [group: .auto])
    }

    /// A snapshot written before 3.34, or one carrying a mode this build does not recognise, decodes without it
    /// and every reader falls back to `manual`.
    func testAnUnrecognisedStoredModeIsDroppedRatherThanGuessedAt() throws {
        var raw = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: SnapshotCodec.encode(KeyRing.Snapshot())) as? [String: Any])
        raw["chat_key_modes"] = [group: "sometimes"]
        let data = try JSONSerialization.data(withJSONObject: raw)
        XCTAssertEqual(SnapshotCodec.decode(data)?.chatKeyModes, [:])
    }

    /// The mode travels in a `K1` transfer too, under Web A's own field name — part of the cross-client
    /// contract since the comparison view gained it (PLAN.md 3.34.1).
    func testTheModeTravelsInTheCrossClientTransferWire() {
        var snapshot = KeyRing.Snapshot()
        snapshot.chatKeyModes = [group: .auto]
        let wire = TransferSnapshotCodec.encode(snapshot)
        XCTAssertEqual(wire["chatKeyModes"] as? [String: String], [group: "auto"])
        XCTAssertEqual(TransferSnapshotCodec.decode(wire).chatKeyModes, [group: .auto])
        // An absent table is no error at all: a bundle from a build older than 3.34 reads as `manual`.
        XCTAssertEqual(TransferSnapshotCodec.decode(TransferSnapshotCodec.encode(KeyRing.Snapshot())).chatKeyModes, [:])
    }
}

/// PLAN.md 3.34.6 guardrail: a group announcement that REPLACES a registered key is never adopted by machine.
final class GroupKeyChangedGuardTests: XCTestCase {
    let group = "-3002"
    let member = "9001"
    let own = "9002"
    let now: Int64 = 1_789_300_000

    var ring: KeyRing!
    var processor: RekeyProcessor!

    override func setUpWithError() throws {
        ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { self.now * 1000 }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        processor = RekeyProcessor(ring: ring, clock: { self.now * 1000 })
    }

    func announce(_ identity: KeyRing.Identity, userId: String? = nil) throws -> RekeyProcessor.Result? {
        let wire = try Rekey.buildP1(userId: userId ?? member, x25519Pk: identity.x25519Pk,
                                     ed25519Pk: identity.ed25519Pk, ed25519Sk: identity.ed25519Sk)
        return processor.handle(text: wire, chatId: group, senderId: userId ?? member, ownUserId: own, messageDate: now)
    }

    /// `P1` proves the message is self-consistent and that the server said who sent it. Enough for a member
    /// arriving; not enough for a member's key being swapped, because adopting swaps automatically would make
    /// control of a user id enough to take over that person's seat in the group.
    func testADifferentKeyFromTheSamePersonIsNotAdoptedAndNotRefused() throws {
        let first = try Rekey.generateIdentity()
        XCTAssertEqual(try announce(first)?.keyChanged, false)

        let second = try Rekey.generateIdentity()
        let result = try announce(second)
        XCTAssertEqual(result?.ok, true)
        XCTAssertEqual(result?.keyChanged, true)
        XCTAssertEqual(result?.userId, member)
        // Not adopted is the half that matters: storing it while merely declining to welcome would only move the
        // hole one step back, and every later reset / welcome / member list would read it.
        XCTAssertEqual(ring.memberPk(chatId: group, userId: member), first.x25519Pk)
        XCTAssertEqual(ring.memberEdPk(chatId: group, userId: member), first.ed25519Pk)
        // And nothing is owed to a claim nobody has agreed to yet
        XCTAssertNil(result?.owesWelcome)
    }

    /// The same key announced again is not a change — and it still owes a welcome, which is the self-healing
    /// half of the auto flow
    func testTheSameKeyAgainIsNotAChange() throws {
        let identity = try Rekey.generateIdentity()
        _ = try announce(identity)
        let again = try announce(identity)
        XCTAssertEqual(again?.keyChanged, false)
        XCTAssertEqual(ring.memberPk(chatId: group, userId: member), identity.x25519Pk)
    }

    /// Private chats have their own road for this (3.25.3, the `keyChanged` pairing outcome) and never come
    /// through here — the two must not be made to look alike.
    func testAPrivateChatNeverTakesThisRoad() throws {
        let peer = "9003"
        let first = try Rekey.generateIdentity()
        _ = processor.handle(text: try Rekey.buildP1(userId: peer, x25519Pk: first.x25519Pk,
                                                     ed25519Pk: first.ed25519Pk, ed25519Sk: first.ed25519Sk),
                             chatId: peer, senderId: peer, ownUserId: own, messageDate: now)
        let second = try Rekey.generateIdentity()
        let result = processor.handle(text: try Rekey.buildP1(userId: peer, x25519Pk: second.x25519Pk,
                                                              ed25519Pk: second.ed25519Pk, ed25519Sk: second.ed25519Sk),
                                      chatId: peer, senderId: peer, ownUserId: own, messageDate: now + 1)
        XCTAssertEqual(result?.keyChanged, false)
        XCTAssertEqual(ring.memberPk(chatId: peer, userId: peer), second.x25519Pk)
    }
}

/// PLAN.md 3.34.6: whether an announcement in a group obliges this device to send that member an `R1 welcome`.
final class OwesWelcomeTests: XCTestCase {
    let group = "-3003"
    let member = "9101"
    let own = "9102"
    let now: Int64 = 1_789_300_000

    var ring: KeyRing!
    var processor: RekeyProcessor!

    override func setUpWithError() throws {
        ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { self.now * 1000 }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        processor = RekeyProcessor(ring: ring, clock: { self.now * 1000 })
        let masterId = try ring.addMaster(KeyDerivation.generateMasterKey())
        try ring.setChatMaster(chatId: group, masterId: masterId, label: nil)
        try ring.setChatAdminSk(chatId: group, try Rekey.generateSigningKeys().sk)
        ring.setChatKeyMode(chatId: group, .auto)
    }

    func announce(userId: String? = nil) throws -> RekeyProcessor.Result? {
        let identity = try Rekey.generateIdentity()
        let wire = try Rekey.buildP1(userId: userId ?? member, x25519Pk: identity.x25519Pk,
                                     ed25519Pk: identity.ed25519Pk, ed25519Sk: identity.ed25519Sk)
        return processor.handle(text: wire, chatId: group, senderId: userId ?? member, ownUserId: own, messageDate: now)
    }

    func testAKeyHolderInAnAutoGroupOwesTheAnnouncerAWelcome() throws {
        XCTAssertEqual(try announce()?.owesWelcome, member)
    }

    /// Manual mode distributes face to face; nothing may send a key for it
    func testManualModeOwesNothing() throws {
        ring.setChatKeyMode(chatId: group, .manual)
        XCTAssertNil(try announce()?.owesWelcome)
    }

    /// A device without the chat's signing key cannot produce an `R1` at all, and one without a master has
    /// nothing to hand out
    func testADeviceThatCannotIssueOrHasNothingToGiveOwesNothing() throws {
        let bare = KeyRing(storage: MemoryKeyRingStorage(), clock: { self.now * 1000 }, epochDays: 1, epochTolerance: 1)
        try bare.setIdentity(try Rekey.generateIdentity())
        bare.setChatKeyMode(chatId: group, .auto)
        let bareProcessor = RekeyProcessor(ring: bare, clock: { self.now * 1000 })
        let identity = try Rekey.generateIdentity()
        let wire = try Rekey.buildP1(userId: member, x25519Pk: identity.x25519Pk, ed25519Pk: identity.ed25519Pk,
                                     ed25519Sk: identity.ed25519Sk)
        XCTAssertNil(bareProcessor.handle(text: wire, chatId: group, senderId: member, ownUserId: own,
                                          messageDate: now)?.owesWelcome)
    }

    /// Our own announcement coming back is not somebody asking for a key
    func testOurOwnAnnouncementOwesNothing() throws {
        XCTAssertNil(try announce(userId: own)?.owesWelcome)
    }
}
