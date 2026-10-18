import XCTest
@testable import SecutgCore

/// PLAN.md 3.35.5.2 — what an auto-mode `N1` does after the `G2` rewrite: it unbinds the current master,
/// renders a line, and stops.
///
/// `testTheAnchorIsNotRecorded` is the one that matters. The admin's button sends `N1` and then `G2` bearing
/// the same `at`; a notice that recorded the anchor would make the broadcast behind it `stale`, and the key
/// would never arrive — the failure this whole rewrite exists to remove, reintroduced by one line (3.35.5.1).
final class N1AutoModeTests: XCTestCase {
    let group = "-1001234567890"
    let admin = "7001"
    let member = "7002"
    let outsider = "7003"
    let now: Int64 = 1_789_300_000

    var ring: KeyRing!
    var processor: RekeyProcessor!
    var adminIdentity: KeyRing.Identity!
    var oldAdminPk: [UInt8]!
    var newAdminPk: [UInt8]!

    override func setUpWithError() throws {
        ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { self.now * 1000 }, epochDays: 1, epochTolerance: 1)
        try ring.setIdentity(try Rekey.generateIdentity())
        processor = RekeyProcessor(ring: ring, clock: { self.now * 1000 })
        adminIdentity = try Rekey.generateIdentity()
        oldAdminPk = try Rekey.generateIdentity().ed25519Pk
        newAdminPk = try Rekey.generateIdentity().ed25519Pk
        try ring.setChatMaster(chatId: group, masterId: try ring.addMaster(KeyDerivation.generateMasterKey()), label: nil)
        try ring.setChatAdminPk(chatId: group, oldAdminPk)
        ring.setChatEncryption(chatId: group, enabled: true)
        _ = processor.handle(text: try Rekey.buildP1(userId: admin, x25519Pk: adminIdentity.x25519Pk,
                                                     ed25519Pk: adminIdentity.ed25519Pk,
                                                     ed25519Sk: adminIdentity.ed25519Sk),
                             chatId: group, senderId: admin, ownUserId: member, messageDate: now)
    }

    private func autoNotice(signer: [UInt8]? = nil, userId: String? = nil) throws -> String {
        return try Rekey.buildN1(chatId: group, userId: userId ?? admin, at: now, mode: .auto,
                                 oldAdminPk: oldAdminPk, newAdminPk: newAdminPk,
                                 ed25519Sk: signer ?? adminIdentity.ed25519Sk)
    }

    private func handle(_ wire: String, senderId: String? = nil,
                        isSenderGroupAdmin: Bool? = true) -> RekeyProcessor.Result? {
        return processor.handle(text: wire, chatId: group, senderId: senderId ?? admin, ownUserId: member,
                                messageDate: now, isSenderGroupAdmin: isSenderGroupAdmin)
    }

    /// PLAN.md 3.35.5.2, found on real devices 2026-09-20. The verdict first carried a reason
    /// (`retired_await_broadcast`) and that broke two downstream rules at once: **this client renders an
    /// `ok` retire through an ALLOWLIST of reasons**, so anything else fell through to
    /// 「换钥消息已忽略」; and `controlMovedKeys` is `ok && reason == nil` on all five, so the verdict did
    /// not count as having moved a key — and it had just UNBOUND the master.
    ///
    /// The contract is: **ok, and no reason at all.** `mode` already says which road this was.
    func testTheContractOkWithNoReason() throws {
        let result = handle(try autoNotice())
        XCTAssertEqual(result?.ok, true)
        XCTAssertNil(result?.reason)
    }

    func testItUnbindsTheCurrentKey() throws {
        // A member excluded by this rebuild still holds the old key, so nobody may keep sending under it.
        let result = handle(try autoNotice())
        XCTAssertEqual(result?.isRetire, true)
        XCTAssertEqual(result?.ok, true)
        XCTAssertEqual(result?.mode, .auto)
        XCTAssertNil(ring.chatMasterId(group))
    }

    /// PLAN.md 3.35.5.3 — the fault a per-rule test cannot see. A history page is read newest-first, so
    /// somebody who joins afterwards meets the `G2` BEFORE the `N1` that announced it. Unbinding
    /// unconditionally took the key away again one message later.
    func testANoticeReadAfterItsOwnBroadcastDoesNotTakeTheKeyAway() throws {
        // The broadcast has already been obeyed: that is what the anchor records.
        let masterId = try ring.addMaster(KeyDerivation.generateMasterKey())
        try ring.setChatMaster(chatId: group, masterId: masterId, label: nil)
        ring.setChatNoticeAt(chatId: group, now)

        let result = handle(try autoNotice())
        XCTAssertEqual(result?.ok, true)
        XCTAssertEqual(result?.reason, "already_applied")
        XCTAssertEqual(ring.chatMasterId(group), masterId)
    }

    func testTheAnchorIsNotRecorded() throws {
        // Record it and the `G2` behind this notice, bearing the same `at`, is stale on arrival.
        _ = handle(try autoNotice())
        XCTAssertNil(ring.chatNoticeAt(group))
    }

    func testItDoesNotChangeTheAdminKeyThisDeviceTrusts() throws {
        // That key rides in the `G2` payload now, where no signature this device could check protects it.
        _ = handle(try autoNotice())
        XCTAssertEqual(ring.chatAdminPk(group), oldAdminPk)
    }

    func testItDoesNotVerifyTheSignature() throws {
        // Signed by a stranger, but the Telegram sender IS this group's admin and names themselves.
        let stranger = try Rekey.generateIdentity()
        XCTAssertEqual(handle(try autoNotice(signer: stranger.ed25519Sk))?.ok, true)
    }

    func testRuleOneStillRefusesANonAdminAndStillParksAnUnknownOne() throws {
        let wire = try autoNotice(userId: outsider)
        XCTAssertEqual(handle(wire, senderId: outsider, isSenderGroupAdmin: false)?.reason, "not_admin")
        XCTAssertEqual(handle(wire, senderId: outsider, isSenderGroupAdmin: nil)?.reason, "pending")
    }
}
