import XCTest
@testable import SecutgCore

/// PLAN.md 3.13: the `G1` invite card, key provenance per chat and the admin's online-invite ledger.
/// Mirrors the "group invite over an encrypted private chat" block of Web A `hooks/hooks.test.ts`.
final class GroupInviteTests: XCTestCase {
    let now: Int64 = 1_789_171_170_000
    let group = "-4100"
    let admin = "700"
    let member = "701"

    func payload() -> String {
        return KeyPayload.build(masterKey: KeyDerivation.generateMasterKey(), adminPk: [UInt8](repeating: 3, count: 32))
    }

    func ring(_ storage: KeyRingStorage = MemoryKeyRingStorage()) -> KeyRing {
        return KeyRing(storage: storage, clock: { self.now }, epochDays: 1, epochTolerance: 1)
    }

    func testBuildsAndParsesTheCardIncludingUnicodeTitles() throws {
        let key = payload()
        let text = try GroupInvite.build(GroupInvite(groupChatId: group, keyPayload: key, title: "运维 Ops “2026”"))
        XCTAssertTrue(text.hasPrefix("G1:-4100:"))
        XCTAssertTrue(GroupInvite.isG1(text))
        XCTAssertEqual(text.components(separatedBy: ":").count, 4)   // the payload's own ':' and '?' never leak into the wire
        XCTAssertEqual(GroupInvite.parse(text), GroupInvite(groupChatId: group, keyPayload: key, title: "运维 Ops “2026”"))
        // an empty title is legal
        let untitled = try GroupInvite.build(GroupInvite(groupChatId: group, keyPayload: key, title: ""))
        XCTAssertEqual(GroupInvite.parse(untitled)?.title, "")
        XCTAssertEqual(GroupInvite.parse(untitled)?.keyPayload, key)
    }

    func testBuildRefusesNonGroupsAndNonPayloads() {
        XCTAssertThrowsError(try GroupInvite.build(GroupInvite(groupChatId: member, keyPayload: payload(), title: "x"))) {
            XCTAssertEqual($0 as? GroupInvite.BuildError, .notAGroupChat)
        }
        XCTAssertThrowsError(try GroupInvite.build(GroupInvite(groupChatId: group, keyPayload: "not a key", title: "x"))) {
            XCTAssertEqual($0 as? GroupInvite.BuildError, .notAKeyPayload)
        }
    }

    func testParseRejectsMalformedCards() throws {
        let good = try GroupInvite.build(GroupInvite(groupChatId: group, keyPayload: payload(), title: "Ops"))
        let parts = good.components(separatedBy: ":")
        XCTAssertNil(GroupInvite.parse("hello"))
        XCTAssertNil(GroupInvite.parse("G1:"))
        XCTAssertNil(GroupInvite.parse("G1:\(member):\(parts[2]):\(parts[3])"))          // positive (user) chat id
        XCTAssertNil(GroupInvite.parse("G1:\(group):\(parts[2])"))                        // three parts
        XCTAssertNil(GroupInvite.parse(good + ":extra"))                                  // five parts
        XCTAssertNil(GroupInvite.parse("G1:\(group):!!!:\(parts[3])"))                    // not base64url
        XCTAssertNil(GroupInvite.parse("G1:\(group):\(Base64Url.encode([UInt8]("secutg://other".utf8))):\(parts[3])"))
        XCTAssertFalse(GroupInvite.isG1("E1:abc"))
    }

    /// Mirrors the Web `hooks.test.ts` invite block: the card's payload resolves to the very master the admin
    /// created, without importing anything, and once the member accepts, their ring holds that id — which is what
    /// tells the card to drop the button and the key and say the registration is done.
    func testTheCardsPayloadResolvesToTheAdminsMasterAndTheRingHoldsItAfterJoining() throws {
        let adminRing = ring()
        let master = KeyDerivation.generateMasterKey()
        let created = try adminRing.addMaster(master)
        try adminRing.setChatMaster(chatId: group, masterId: created, label: nil)
        let text = try GroupInvite.build(GroupInvite(groupChatId: group, keyPayload: KeyPayload.build(masterKey: master, adminPk: nil), title: "Ops"))

        // the member side reads the id off the card alone — a pure function of the key, no import needed
        let card = try XCTUnwrap(GroupInvite.parse(text))
        let payload = try XCTUnwrap(KeyPayload.parse(card.keyPayload))
        XCTAssertEqual(try KeyDerivation.computeMasterId(payload.masterKey), created)

        let memberRing = ring()
        XCTAssertFalse(memberRing.listMasterIds().contains(created))   // before joining the card is still actionable
        let imported = try memberRing.addMaster(payload.masterKey)
        try memberRing.setChatMaster(chatId: card.groupChatId, masterId: imported, label: nil)
        try memberRing.setChatKeySource(chatId: card.groupChatId, .online(via: admin, viaLevel: .unverified))
        XCTAssertEqual(imported, created)
        XCTAssertTrue(memberRing.listMasterIds().contains(created))

        // a later invite carrying a rotated key resolves to a different id, so it stays actionable
        let rotated = KeyDerivation.generateMasterKey()
        let rotatedCard = try XCTUnwrap(GroupInvite.parse(try GroupInvite.build(GroupInvite(groupChatId: group, keyPayload: KeyPayload.build(masterKey: rotated, adminPk: nil), title: "Ops"))))
        let rotatedId = try KeyDerivation.computeMasterId(try XCTUnwrap(KeyPayload.parse(rotatedCard.keyPayload)).masterKey)
        XCTAssertNotEqual(rotatedId, created)
        XCTAssertFalse(memberRing.listMasterIds().contains(rotatedId))
    }

    func testKeyRingRecordsProvenanceAndOnlineInvitesAndClearsThemWithTheMaster() throws {
        let ring = ring()
        let id = try ring.addMaster(KeyDerivation.generateMasterKey())
        try ring.setChatMaster(chatId: group, masterId: id, label: nil)
        XCTAssertNil(ring.chatKeySource(group))
        try ring.setChatKeySource(chatId: group, .offline)
        XCTAssertEqual(ring.chatKeySource(group), .offline)
        try ring.setChatKeySource(chatId: group, .online(via: admin, viaLevel: .unverified))
        XCTAssertEqual(ring.chatKeySource(group), .online(via: admin, viaLevel: .unverified))
        XCTAssertThrowsError(try ring.setChatKeySource(chatId: group, .online(via: "", viaLevel: .verified)))

        ring.recordOnlineInvite(chatId: group, userId: member, level: .verified)
        ring.recordOnlineInvite(chatId: group, userId: "702", level: .manual)
        ring.recordOnlineInvite(chatId: group, userId: member, level: .unverified)   // the latest send wins
        XCTAssertEqual(ring.onlineInvites(chatId: group), [member: .unverified, "702": .manual])
        XCTAssertEqual(ring.listOnlineInvites(), [group: [member: .unverified, "702": .manual]])
        XCTAssertEqual(ring.onlineInvites(chatId: "-1"), [:])

        // a rekey keeps the provenance (the key's origin does not change), unbinding the master clears it
        let rotated = try ring.addMaster(KeyDerivation.generateMasterKey())
        try ring.setChatMaster(chatId: group, masterId: rotated, label: "20260911")
        XCTAssertNotNil(ring.chatKeySource(group))
        ring.clearChatMaster(group)
        XCTAssertNil(ring.chatKeySource(group))
        XCTAssertEqual(ring.listChatKeySources(), [:])
        XCTAssertEqual(ring.listOnlineInvites(), [:])
    }

    func testProvenanceSurvivesTheSnapshotCodecAndOldSnapshotsStillDecode() throws {
        let storage = MemoryKeyRingStorage()
        let ring = ring(storage)
        try ring.setChatKeySource(chatId: group, .online(via: admin, viaLevel: .verified))
        try ring.setChatKeySource(chatId: "-5", .offline)
        ring.recordOnlineInvite(chatId: group, userId: member, level: .unverified)
        let decoded = SnapshotCodec.decode(SnapshotCodec.encode(storage.saved!))
        XCTAssertEqual(decoded, storage.saved!)
        XCTAssertEqual(decoded?.chatKeySources[group], .online(via: admin, viaLevel: .verified))
        XCTAssertEqual(decoded?.groupOnlineInvites[group], [member: .unverified])

        // written before 3.13 existed: nothing recorded, nothing lost
        let legacy = #"{"v":1,"chat_encryption":{"-5":true}}"#
        let old = SnapshotCodec.decode(Data(legacy.utf8))
        XCTAssertEqual(old?.chatEncryption["-5"], true)
        XCTAssertEqual(old?.chatKeySources, [:])
        XCTAssertEqual(old?.groupOnlineInvites, [:])

        // hostile storage: malformed entries are dropped, valid ones kept
        let dirty = #"{"v":1,"chat_key_sources":{"-5":{"source":"offline"},"-6":{"source":"online"},"-7":{"source":"online","via":"9","via_level":"bogus"},"-8":{"source":"online","via":"","via_level":"manual"}},"group_online_invites":{"-5":{"1":"verified","2":"nope","":"manual"}}}"#
        let cleaned = KeyRing(storage: MemoryKeyRingStorage(SnapshotCodec.decode(Data(dirty.utf8))), clock: { self.now }, epochDays: 1, epochTolerance: 1)
        XCTAssertEqual(cleaned.listChatKeySources(), ["-5": .offline])
        XCTAssertEqual(cleaned.listOnlineInvites(), ["-5": ["1": .verified]])
    }
}
