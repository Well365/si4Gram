import XCTest
@testable import SecutgCore

final class RekeyProcessorTests: XCTestCase {
    let chat = "-1001"
    let v = Vectors.load("rekey")
    var adminPk: [UInt8] { Vectors.b64(v["admin_ed25519_pk_b64"] as! String) }
    var oldMaster: [UInt8] { Vectors.hex(v["old_master_hex"] as! String) }
    var newMasterId: String { try! KeyDerivation.computeMasterId(Vectors.hex(v["new_master_hex"] as! String)) }

    func ring(storage: KeyRingStorage = MemoryKeyRingStorage(), now: Int64 = vectorNowMs) throws -> KeyRing {
        let r = KeyRing(storage: storage, clock: { now }, epochDays: 1, epochTolerance: 1)
        try r.setChatAdminPk(chatId: chat, adminPk)
        return r
    }

    func identity(_ x: Rekey.SealingIdentity) -> KeyRing.Identity {
        return KeyRing.Identity(x25519Pk: x.x25519Pk, x25519Sk: x.x25519Sk, ed25519Pk: [UInt8](repeating: 0, count: 32), ed25519Sk: [UInt8](repeating: 0, count: 64))
    }

    func testRotateFromWebSwitchesTheChat() throws {
        let ring = try ring()
        try ring.setChatMaster(chatId: chat, masterId: try ring.addMaster(oldMaster), label: nil)
        let p = RekeyProcessor(ring: ring, clock: { vectorNowMs })
        let r = p.handle(text: v["rotate"] as! String, chatId: chat, senderId: "100", ownUserId: "200")!
        XCTAssertTrue(r.ok, r.reason ?? "")
        XCTAssertEqual(r.type, .rotate)
        XCTAssertEqual(ring.chatMasterId(chat), newMasterId)
        XCTAssertEqual(ring.chatKeyLabel(chat), "20260911")
        XCTAssertEqual(p.handle(text: v["rotate"] as! String, chatId: chat, senderId: "100", ownUserId: "200")?.reason, "already_known")
        XCTAssertNil(p.handle(text: "hello", chatId: chat, senderId: "100", ownUserId: "200"))
    }

    /// PLAN.md 3.34.7 item 4 (receiving side): in a GROUP, "no admin key" means "nothing to check against yet"
    /// — the notice that would make one trusted may be parked or still on its way, so the message waits with it
    /// rather than being refused for good. A private chat has no notices, so there it is still a refusal.
    func testRotateWithoutOldMasterIsParkedAndWithoutAnAdminKeyWaitsInAGroupRefusesInPrivate() throws {
        let ring = try ring()
        let p = RekeyProcessor(ring: ring, clock: { vectorNowMs })
        let r = p.handle(text: v["rotate"] as! String, chatId: chat, senderId: "100", ownUserId: "200")!
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.reason, "no_old_key")
        XCTAssertEqual(p.pendingCount(chatId: chat), 1)
        // The parked rotate is applied once the old master arrives via another success
        let noAdmin = KeyRing(storage: MemoryKeyRingStorage(), clock: { vectorNowMs }, epochDays: 1, epochTolerance: 1)
        let waiting = RekeyProcessor(ring: noAdmin, clock: { vectorNowMs })
        XCTAssertEqual(waiting.handle(text: v["rotate"] as! String, chatId: chat, senderId: "100", ownUserId: "200")?.reason, "pending")
        XCTAssertEqual(waiting.parkedRekeyCount(chatId: chat), 1)
        XCTAssertEqual(waiting.handle(text: v["rotate"] as! String, chatId: "200", senderId: "100", ownUserId: "200")?.reason, "no_admin_key")
        XCTAssertEqual(waiting.parkedRekeyCount(chatId: "200"), 0)
    }

    /// The other half of the narrow rule: a signature that fails against a key this device DOES trust, with no
    /// notice waiting in the chat, is a forgery or a stale key. It is refused out loud and NOT parked — parking
    /// it would turn every forged rekey into a blank row that waits forever.
    func testAForgedRekeyWithNoNoticeWaitingIsRefusedOutLoudAndNotParked() throws {
        let p = RekeyProcessor(ring: try ring(), clock: { vectorNowMs })
        let rotate = v["rotate"] as! String
        let forged = rotate[..<rotate.lastIndex(of: ":")!] + ":" + Base64Url.encode([UInt8](repeating: 0, count: 64))
        XCTAssertEqual(p.parkedNoticeCount(chatId: chat), 0)
        XCTAssertEqual(p.handle(text: String(forged), chatId: chat, senderId: "100", ownUserId: "1")?.reason, "bad_signature")
        XCTAssertEqual(p.parkedRekeyCount(chatId: chat), 0)
    }

    func testParkedRotateCatchesUpInOrder() throws {
        let admin = try Rekey.generateSigningKeys()
        let m0 = KeyDerivation.generateMasterKey(), m1 = KeyDerivation.generateMasterKey(), m2 = KeyDerivation.generateMasterKey()
        let day: Int64 = 86_400_000
        let r1 = try Rekey.buildRotate(newMaster: m1, oldMaster: m0, adminSk: admin.sk, nowMs: vectorNowMs - 2 * day, epochDays: 1)
        let r2 = try Rekey.buildRotate(newMaster: m2, oldMaster: m1, adminSk: admin.sk, nowMs: vectorNowMs - day, epochDays: 1)
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { vectorNowMs }, epochDays: 1, epochTolerance: 1)
        try ring.setChatAdminPk(chatId: chat, admin.pk)
        try ring.setChatMaster(chatId: chat, masterId: try ring.addMaster(m0), label: nil)
        let p = RekeyProcessor(ring: ring, clock: { vectorNowMs })
        XCTAssertEqual(p.handle(text: r2.wire, chatId: chat, senderId: "1", ownUserId: "2")?.reason, "no_old_key")   // out of order
        XCTAssertTrue(p.handle(text: r1.wire, chatId: chat, senderId: "1", ownUserId: "2")!.ok)
        XCTAssertEqual(p.pendingCount(chatId: chat), 0)
        XCTAssertEqual(ring.chatMasterId(chat), try KeyDerivation.computeMasterId(m2))
    }

    func testResetAndWelcomeUseTheIdentity() throws {
        let member = Rekey.SealingIdentity(x25519Pk: Vectors.hex(v["member_x25519_pk_hex"] as! String), x25519Sk: Vectors.hex(v["member_x25519_sk_hex"] as! String))
        let newcomer = Rekey.SealingIdentity(x25519Pk: Vectors.hex(v["newcomer_x25519_pk_hex"] as! String), x25519Sk: Vectors.hex(v["newcomer_x25519_sk_hex"] as! String))
        let ring = try ring()
        try ring.setIdentity(identity(member))
        XCTAssertTrue(RekeyProcessor(ring: ring, clock: { vectorNowMs }).handle(text: v["reset"] as! String, chatId: chat, senderId: "100", ownUserId: "200")!.ok)
        XCTAssertEqual(ring.chatMasterId(chat), newMasterId)

        let kicked = try self.ring()
        try kicked.setIdentity(identity(newcomer))
        XCTAssertEqual(RekeyProcessor(ring: kicked, clock: { vectorNowMs }).handle(text: v["reset"] as! String, chatId: chat, senderId: "100", ownUserId: "300")?.reason, "not_addressed")
        XCTAssertTrue(RekeyProcessor(ring: kicked, clock: { vectorNowMs }).handle(text: v["welcome"] as! String, chatId: chat, senderId: "100", ownUserId: "300")!.ok)
    }

    func testP1RequiresMatchingSenderAndForgedR1IsDropped() throws {
        let ring = try ring()
        let p = RekeyProcessor(ring: ring, clock: { vectorNowMs })
        XCTAssertTrue(p.handle(text: v["p1"] as! String, chatId: chat, senderId: "200", ownUserId: "1")!.ok)
        XCTAssertNotNil(ring.memberPk(chatId: chat, userId: "200"))
        XCTAssertEqual(p.handle(text: v["p1"] as! String, chatId: chat, senderId: "201", ownUserId: "1")?.reason, "sender_mismatch")
        XCTAssertEqual(p.handle(text: v["p1"] as! String, chatId: chat, senderId: nil, ownUserId: "1")?.reason, "no_sender")

        let rotate = v["rotate"] as! String
        let forged = rotate[..<rotate.lastIndex(of: ":")!] + ":" + Base64Url.encode([UInt8](repeating: 0, count: 64))
        XCTAssertEqual(p.handle(text: String(forged), chatId: chat, senderId: "100", ownUserId: "1")?.reason, "bad_signature")
        XCTAssertEqual(p.handle(text: "R1:rotate:0123456789abcdef.20260911:AAAA:BBBB", chatId: chat, senderId: "100", ownUserId: "1")?.reason, "malformed")
        XCTAssertEqual(p.handle(text: "P1:x", chatId: chat, senderId: "100", ownUserId: "1")?.reason, "malformed")
    }

    func testStaleRotateCannotRollBackAfterReload() throws {
        let storage = MemoryKeyRingStorage()
        let ring = try ring(storage: storage)
        try ring.setChatMaster(chatId: chat, masterId: try ring.addMaster(oldMaster), label: nil)
        _ = RekeyProcessor(ring: ring, clock: { vectorNowMs }).handle(text: v["rotate"] as! String, chatId: chat, senderId: "100", ownUserId: "200")
        try ring.setChatMaster(chatId: chat, masterId: ring.chatMasterId(chat)!, label: "20260920")
        let later = vectorNowMs + 10 * 86_400_000
        let reloaded = KeyRing(storage: storage, clock: { later }, epochDays: 1, epochTolerance: 1)
        let p = RekeyProcessor(ring: reloaded, clock: { later })
        XCTAssertEqual(p.handle(text: v["rotate"] as! String, chatId: chat, senderId: "100", ownUserId: "200")?.reason, "already_known")
        XCTAssertEqual(reloaded.chatKeyLabel(chat), "20260920")
    }
}
