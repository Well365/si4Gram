import XCTest
@testable import SecutgCore

/// PLAN.md 3.35 end to end through the processor: a member with NOTHING — no key, no registered public keys,
/// no `N1` ever seen, no handshake — reads one broadcast and holds the group's key.
///
/// That sentence is the entire point of the rewrite. 3.35.1 lists the seven gates the `R1 welcome` road put
/// between those two states, five of which could not answer yet and failed silently.
final class G2ProcessorTests: XCTestCase {
    let group = "-1001234567890"
    let admin = "7001"
    let member = "7002"
    /// Somebody who is neither this device nor an admin — the forger in the refusal tests.
    let outsider = "7003"
    let now: Int64 = 1_789_300_000

    var ring: KeyRing!
    var processor: RekeyProcessor!
    var adminPk: [UInt8]!

    override func setUpWithError() throws {
        ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { self.now * 1000 }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        processor = RekeyProcessor(ring: ring, clock: { self.now * 1000 })
        adminPk = try Rekey.generateIdentity().ed25519Pk
    }

    private func payload(_ fill: UInt8, mode: Rekey.KeyMode = .auto) -> String {
        return KeyPayload.build(masterKey: [UInt8](repeating: fill, count: 32), adminPk: adminPk, mode: mode)
    }

    private func deliver(_ wire: String, senderId: String? = nil, isSenderGroupAdmin: Bool? = true,
                         ownUserId: String? = nil) -> RekeyProcessor.Result? {
        return processor.handle(text: wire, chatId: group, senderId: senderId ?? admin,
                                ownUserId: ownUserId ?? member, messageDate: now,
                                isSenderGroupAdmin: isSenderGroupAdmin)
    }

    func testTheWholePointAMemberHoldingNothingGetsTheKeyFromOneMessage() throws {
        // Nothing on file: no master, no member keys, no admin pk, no notice ever obeyed.
        XCTAssertNil(ring.chatMasterId(group))
        let wire = try XCTUnwrap(G2.build(chatId: group, at: 1000, keyPayload: payload(1), publisherId: admin))

        let result = deliver(wire)
        XCTAssertEqual(result?.isGroupKey, true)
        XCTAssertEqual(result?.ok, true)
        XCTAssertEqual(result?.verdict, .apply)
        XCTAssertNotNil(ring.chatMasterId(group))
        XCTAssertTrue(ring.isChatEncrypted(group))
        XCTAssertEqual(ring.chatKeyMode(group), .auto)
        // The anchor is what stops the next scroll through history from undoing this (3.35.5.1)
        XCTAssertEqual(ring.chatNoticeAt(group), 1000)
    }

    func testANewerBroadcastReplacesTheKeyAnOlderOneDoesNot() throws {
        _ = deliver(try XCTUnwrap(G2.build(chatId: group, at: 1000, keyPayload: payload(1), publisherId: admin)))
        let first = ring.chatMasterId(group)
        _ = deliver(try XCTUnwrap(G2.build(chatId: group, at: 2000, keyPayload: payload(2), publisherId: admin)))
        let second = ring.chatMasterId(group)
        XCTAssertNotEqual(first, second)

        // Scrolling back over the old one must not unbind the key the member holds now.
        let stale = deliver(try XCTUnwrap(G2.build(chatId: group, at: 1000, keyPayload: payload(1), publisherId: admin)))
        XCTAssertEqual(stale?.verdict, .stale)
        XCTAssertEqual(ring.chatMasterId(group), second)
    }

    func testTheOldMasterIsUnboundNeverDestroyed() throws {
        _ = deliver(try XCTUnwrap(G2.build(chatId: group, at: 1000, keyPayload: payload(1), publisherId: admin)))
        let oldId = try XCTUnwrap(ring.chatMasterId(group))
        _ = deliver(try XCTUnwrap(G2.build(chatId: group, at: 2000, keyPayload: payload(2), publisherId: admin)))
        // 3.34.5's red line, which 3.35 does not repeal.
        XCTAssertNotNil(ring.masterKey(for: oldId))
    }

    func testAnUnknownPublisherParksAndTheSameBroadcastAppliesWhenTheListArrives() throws {
        let wire = try XCTUnwrap(G2.build(chatId: group, at: 1000, keyPayload: payload(1), publisherId: admin))
        let parked = deliver(wire, isSenderGroupAdmin: nil)
        XCTAssertEqual(parked?.verdict, .park)
        XCTAssertEqual(parked?.reason, "pending")
        XCTAssertNil(ring.chatMasterId(group))

        let applied = deliver(wire, isSenderGroupAdmin: true)
        XCTAssertEqual(applied?.verdict, .apply)
        XCTAssertNotNil(ring.chatMasterId(group))
    }

    func testANonAdminPublisherIsRefusedAndNothingIsWritten() throws {
        let wire = try XCTUnwrap(G2.build(chatId: group, at: 1000, keyPayload: payload(9), publisherId: outsider))
        let result = deliver(wire, senderId: outsider, isSenderGroupAdmin: false)
        XCTAssertEqual(result?.verdict, .refuseNotAdmin)
        XCTAssertNil(ring.chatMasterId(group))
        // "Not an admin" must never be recorded: the answer could be stale, and the anchor is monotonic.
        XCTAssertNil(ring.chatNoticeAt(group))
    }

    func testThePublisherInTheWireMustBeTheTelegramSender() throws {
        // Wire says the admin published it; Telegram says somebody else sent it. A forwarded broadcast.
        let wire = try XCTUnwrap(G2.build(chatId: group, at: 1000, keyPayload: payload(1), publisherId: admin))
        let result = deliver(wire, senderId: outsider)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "sender_mismatch")
        XCTAssertNil(ring.chatMasterId(group))
    }

    func testABroadcastForAnotherGroupIsRefusedWhereItLands() throws {
        let wire = try XCTUnwrap(G2.build(chatId: "-2002", at: 1000, keyPayload: payload(1), publisherId: admin))
        let result = deliver(wire)
        XCTAssertEqual(result?.reason, "wrong_chat")
        XCTAssertNil(ring.chatMasterId(group))
    }

    func testAManualModePayloadIsRefused() throws {
        let wire = try XCTUnwrap(G2.build(chatId: group, at: 1000,
                                          keyPayload: payload(3, mode: .manual), publisherId: admin))
        XCTAssertEqual(deliver(wire)?.verdict, .refuseNotAuto)
        XCTAssertNil(ring.chatMasterId(group))
    }

    /// PLAN.md 3.35.9: what makes a device THE PUBLISHER is that it already holds the master — it bound
    /// it before sending. Merely sharing the publisher's account id does not.
    func testThePublishersOwnBroadcastComingBackChangesNothing() throws {
        let p = payload(1)
        let wire = try XCTUnwrap(G2.build(chatId: group, at: 1000, keyPayload: p, publisherId: admin))
        // Stand this device up as the publisher: it holds the very master the broadcast carries.
        let parsed = try XCTUnwrap(KeyPayload.parse(p))
        try ring.setChatMaster(chatId: group, masterId: try ring.addMaster(parsed.masterKey), label: nil)
        XCTAssertEqual(deliver(wire, ownUserId: admin)?.verdict, .own)
    }

    /// THE SECOND DEVICE — same account, different device, nothing on file. Keyrings are per-device and
    /// never sync by themselves. It used to read the broadcast as its own and end up with no key at all,
    /// while the screen said the key had been published.
    func testASecondDeviceOfThePublishingAccountStillGetsTheKey() throws {
        let wire = try XCTUnwrap(G2.build(chatId: group, at: 1000, keyPayload: payload(1), publisherId: admin))
        XCTAssertEqual(deliver(wire, ownUserId: admin)?.verdict, .apply)
        XCTAssertNotNil(ring.chatMasterId(group))
    }
}
