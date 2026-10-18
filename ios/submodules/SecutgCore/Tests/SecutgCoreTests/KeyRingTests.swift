import XCTest
@testable import SecutgCore

final class KeyRingTests: XCTestCase {
    let sep11_2359: Int64 = 1_789_171_170_000
    let sep12_0000: Int64 = 1_789_171_230_000

    func ring(now: @escaping () -> Int64, storage: KeyRingStorage = MemoryKeyRingStorage(), tolerance: Int = 1) -> KeyRing {
        return KeyRing(storage: storage, clock: now, epochDays: 1, epochTolerance: tolerance)
    }

    func testCrossMidnightAndYesterdayStaysReadable() throws {
        var now = sep11_2359
        let ring = ring(now: { now })
        let master = KeyDerivation.generateMasterKey()
        let id = try ring.addMaster(master)
        try ring.setChatMaster(chatId: "c", masterId: id, label: nil)
        let before = ring.currentKey(chatId: "c")!
        XCTAssertTrue(before.keyId.hasSuffix(".20260911"))
        now = sep12_0000
        let after = ring.currentKey(chatId: "c")!
        XCTAssertTrue(after.keyId.hasSuffix(".20260912"))
        XCTAssertNotEqual(before.sessionKey, after.sessionKey)
        XCTAssertEqual(ring.lookupSessionKey(before.keyId), before.sessionKey)   // history stays readable
        XCTAssertNil(ring.currentKey(chatId: "unknown"))
    }

    func testSlowClockWithinToleranceDecrypts() throws {
        let master = KeyDerivation.generateMasterKey()
        let fast = ring(now: { self.sep12_0000 })
        try fast.setChatMaster(chatId: "c", masterId: try fast.addMaster(master), label: nil)
        let wire = fast.currentKey(chatId: "c")!.keyId
        let slow = ring(now: { self.sep11_2359 })
        try slow.addMaster(master)
        XCTAssertNotNil(slow.lookupSessionKey(wire))
        let strict = ring(now: { self.sep11_2359 }, tolerance: 0)
        try strict.addMaster(master)
        XCTAssertNil(strict.lookupSessionKey(wire))
    }

    func testPersistsAndSanitises() throws {
        let storage = MemoryKeyRingStorage()
        let ring = ring(now: { self.sep11_2359 }, storage: storage)
        let id = try ring.addMaster(KeyDerivation.generateMasterKey())
        try ring.setChatMaster(chatId: "c", masterId: id, label: "20260911")
        ring.setChatEncryption(chatId: "c", enabled: true)
        try ring.setChatAdminPk(chatId: "c", [UInt8](repeating: 1, count: 32))
        try ring.setMemberPk(chatId: "c", userId: "9", [UInt8](repeating: 2, count: 32))
        let identity = try Rekey.generateIdentity()
        try ring.setIdentity(identity)

        var dirty = storage.saved!
        dirty.masters["zz"] = [1, 2, 3]
        dirty.chatMasters["orphan"] = "zz"
        dirty.chatKeyLabels["c"] = "not-a-label"
        dirty.chatAdminPks["bad"] = [1]
        dirty.memberPks["c"]?["short"] = [1]
        dirty.identityEd25519Sk = [0]
        let reloaded = KeyRing(storage: MemoryKeyRingStorage(dirty), clock: { self.sep11_2359 }, epochDays: 1, epochTolerance: 1)
        XCTAssertEqual(reloaded.listMasterIds(), [id])
        XCTAssertEqual(reloaded.chatMasterId("c"), id)
        XCTAssertNil(reloaded.chatMasterId("orphan"))
        XCTAssertNil(reloaded.chatKeyLabel("c"))
        XCTAssertTrue(reloaded.isChatEncrypted("c"))
        XCTAssertNil(reloaded.chatAdminPk("bad"))
        XCTAssertEqual(reloaded.listMemberIds(chatId: "c"), ["9"])
        XCTAssertNil(reloaded.identity)   // partial identity dropped as a set

        // JSON codec round trip preserves everything
        let decoded = SnapshotCodec.decode(SnapshotCodec.encode(storage.saved!))
        XCTAssertEqual(decoded, storage.saved!)
    }

    func testCandidateMastersPutTheCurrentOneFirst() throws {
        let ring = ring(now: { self.sep11_2359 })
        let a = KeyDerivation.generateMasterKey(), b = KeyDerivation.generateMasterKey()
        try ring.addMaster(a)
        let idB = try ring.addMaster(b)
        try ring.setChatMaster(chatId: "c", masterId: idB, label: nil)
        XCTAssertEqual(ring.candidateMasters(chatId: "c"), [b, a])
        XCTAssertThrowsError(try ring.setChatMaster(chatId: "c", masterId: "0000000000000000", label: nil))
    }

    // MARK: PLAN.md 3.25 device labels

    func testDeviceLabelSetGetAndClear() throws {
        let ring = ring(now: { self.sep11_2359 })
        let deviceId = "3b824e8358cee308"
        XCTAssertNil(ring.deviceLabel(deviceId))
        try ring.setDeviceLabel(deviceId: deviceId, label: "  家里的电脑  ")
        XCTAssertEqual(ring.deviceLabel(deviceId)?.label, "家里的电脑")
        try ring.setDeviceLabel(deviceId: deviceId, label: "   ")   // blank clears it
        XCTAssertNil(ring.deviceLabel(deviceId))
        XCTAssertThrowsError(try ring.setDeviceLabel(deviceId: "not-a-device-id", label: "x"))
    }

    /// PLAN.md 3.25.7 rule 2: a snapshot written before `device_labels` (or the pairing device fields)
    /// existed decodes to exactly what it decoded to before this feature — empty tables, not an error.
    func testAnOlderSnapshotWithoutDeviceFieldsDecodesUnchanged() throws {
        let legacy = """
        {"v":1,"masters":{},"chat_pairings":{"7":{"peer_id":"7","state":"paired","verified":false}}, \
        "chat_encryption":{"7":true}}
        """
        let decoded = SnapshotCodec.decode(Data(legacy.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.deviceLabels, [:])
        let pairing = decoded?.chatPairings["7"]
        XCTAssertEqual(pairing?.state, .paired)
        XCTAssertNil(pairing?.ownDeviceId)
        XCTAssertNil(pairing?.peerDeviceId)
        XCTAssertNil(pairing?.peerSeenDeviceIds)
        // round-tripping it back through the ring behaves exactly as it did before this feature existed
        let reloaded = KeyRing(storage: MemoryKeyRingStorage(decoded), clock: { self.sep11_2359 }, epochDays: 1, epochTolerance: 1)
        XCTAssertEqual(reloaded.chatPairing("7")?.state, .paired)
        XCTAssertTrue(reloaded.isChatEncrypted("7"))
        XCTAssertEqual(reloaded.listDeviceLabels(), [:])
    }

    /// PLAN.md 3.25.4 rule 3: the easiest piece of the emergency wipe to forget, because it looks like just
    /// a caption — a wiped device must not still be able to say "that's Bob's laptop" about anything.
    func testEmergencyWipeClearsDeviceLabels() throws {
        let storage = MemoryKeyRingStorage()
        let ring = ring(now: { self.sep11_2359 }, storage: storage)
        try ring.setDeviceLabel(deviceId: "3b824e8358cee308", label: "老王的公司电脑")
        XCTAssertFalse(ring.listDeviceLabels().isEmpty)
        ring.destroyAllKeys()
        XCTAssertTrue(ring.listDeviceLabels().isEmpty)
        XCTAssertNil(ring.deviceLabel("3b824e8358cee308"))
        // the deletion reached storage too, not just the in-memory copy
        XCTAssertNil(storage.saved)
    }
}
