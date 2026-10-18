import XCTest
@testable import SecutgCore

/// `chatNoticeAts` — the retire-notice anchor (PLAN.md 3.34.3 rule 3, as amended 2026-09-19).
///
/// The replay guard used to be "the notice must name the key this device trusts". That refused every member
/// who had missed a generation, every member who never had a key, and every admin who had started over — which
/// is why a real auto-mode rebuild paired nobody. What decides now is whether the notice is newer than the last
/// one this device obeyed, and that fact has to survive a relaunch and travel with the key: a transferred
/// keyring that forgot it would re-obey an old notice out of the history and unbind the key it just carried.
final class RetireAnchorTests: XCTestCase {
    let chat = "-1004242"

    func makeRing(_ storage: KeyRingStorage = MemoryKeyRingStorage()) -> KeyRing {
        return KeyRing(storage: storage, clock: { 1_789_300_000_000 }, epochDays: 1, epochTolerance: 1)
    }

    func testSetGetListNeverMoveBackwardsAndSurviveAReload() {
        let storage = MemoryKeyRingStorage()
        let ring = makeRing(storage)
        XCTAssertNil(ring.chatNoticeAt(chat))
        ring.setChatNoticeAt(chatId: chat, 1_789_300_000)
        // Older is ignored: a notice is only ever obeyed when it is newer than this, so lowering it would be a
        // caller with the order wrong — and an anchor that can go down is not a replay guard.
        ring.setChatNoticeAt(chatId: chat, 1_789_200_000)
        XCTAssertEqual(ring.chatNoticeAt(chat), 1_789_300_000)
        ring.setChatNoticeAt(chatId: chat, 1_789_400_000)
        XCTAssertEqual(ring.listChatNoticeAts(), [chat: 1_789_400_000])
        // Not a time, not stored.
        ring.setChatNoticeAt(chatId: "-9", -1)
        XCTAssertNil(ring.chatNoticeAt("-9"))

        let reloaded = makeRing(storage)
        XCTAssertEqual(reloaded.chatNoticeAt(chat), 1_789_400_000)
        // It travels with the key (K1), in both scopes.
        XCTAssertEqual(reloaded.exportSnapshot().chatNoticeAts, [chat: 1_789_400_000])
        XCTAssertEqual(reloaded.exportChatsSnapshot(chatIds: [chat], withIdentity: false).chatNoticeAts,
                       [chat: 1_789_400_000])
        XCTAssertEqual(reloaded.exportChatsSnapshot(chatIds: ["-1"], withIdentity: false).chatNoticeAts, [:])
    }

    /// The anchor is a property of what this device has already been told, not of the key — unbinding a master
    /// must not make an old notice obeyable again. (The mode is the opposite case: it does go with the key.)
    func testUnbindingTheChatsMasterKeepsTheAnchor() throws {
        let ring = makeRing()
        let masterId = try ring.addMaster(KeyDerivation.generateMasterKey())
        try ring.setChatMaster(chatId: chat, masterId: masterId, label: nil)
        ring.setChatNoticeAt(chatId: chat, 1_789_300_000)
        ring.clearChatMaster(chat)
        XCTAssertEqual(ring.chatNoticeAt(chat), 1_789_300_000)
    }

    /// Garbage in storage is dropped; a snapshot written before the amendment reads as "nothing obeyed yet",
    /// which is the state in which the first notice met applies.
    func testGarbageIsDroppedAndAnOlderSnapshotReadsAsNothingObeyed() throws {
        var raw = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: SnapshotCodec.encode(KeyRing.Snapshot())) as? [String: Any])
        raw["chat_notice_ats"] = [chat: -1, "good": 1_789_300_000]
        let ring = makeRing(MemoryKeyRingStorage(
            try XCTUnwrap(SnapshotCodec.decode(try JSONSerialization.data(withJSONObject: raw)))))
        XCTAssertNil(ring.chatNoticeAt(chat))
        XCTAssertEqual(ring.chatNoticeAt("good"), 1_789_300_000)

        XCTAssertEqual(SnapshotCodec.decode(SnapshotCodec.encode(KeyRing.Snapshot()))?.chatNoticeAts, [:])
    }

    /// Whichever device obeyed the more recent notice knows more, so a merge takes the later of the two. Taking
    /// the incoming value flat could hand this device an older anchor and make a replay obeyable again.
    func testAMergeKeepsTheLaterAnchorWhicheverSideItCameFrom() {
        let mine = makeRing()
        let theirs = makeRing()
        mine.setChatNoticeAt(chatId: chat, 1_789_300_000)
        mine.setChatNoticeAt(chatId: "-2", 1_789_999_999)
        theirs.setChatNoticeAt(chatId: chat, 1_789_400_000)
        theirs.setChatNoticeAt(chatId: "-2", 1_789_000_000)
        _ = mine.mergeSnapshot(theirs.exportSnapshot())
        XCTAssertEqual(mine.chatNoticeAt(chat), 1_789_400_000)
        XCTAssertEqual(mine.chatNoticeAt("-2"), 1_789_999_999)
    }

    /// The cross-client `K1` wire, under Web A's own field name — part of the comparison view the five clients
    /// publish, so it is added to the codec and to that view together.
    func testTheAnchorTravelsInTheCrossClientTransferWire() {
        var snapshot = KeyRing.Snapshot()
        snapshot.chatNoticeAts = [chat: 1_789_300_000]
        let wire = TransferSnapshotCodec.encode(snapshot)
        XCTAssertEqual((wire["chatNoticeAts"] as? [String: NSNumber])?[chat]?.int64Value, 1_789_300_000)
        XCTAssertEqual(TransferSnapshotCodec.decode(wire).chatNoticeAts, [chat: 1_789_300_000])
        // A bundle from a build older than the amendment carries none, which reads as nothing obeyed.
        XCTAssertEqual(TransferSnapshotCodec.decode(TransferSnapshotCodec.encode(KeyRing.Snapshot())).chatNoticeAts, [:])
    }

    /// PLAN.md 3.16: a wiped device is a brand-new device, and keeps no trace of which notices it once obeyed.
    func testTheEmergencyWipeClearsTheAnchors() {
        let ring = makeRing()
        ring.setChatNoticeAt(chatId: chat, 1_789_300_000)
        ring.destroyAllKeys()
        XCTAssertNil(ring.chatNoticeAt(chat))
    }
}
