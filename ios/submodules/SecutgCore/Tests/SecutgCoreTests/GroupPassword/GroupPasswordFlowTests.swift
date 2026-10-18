import XCTest
@testable import SecutgCore

/// LEGACY (PLAN.md 3.38.1, superseded by 3.38.2): the `pw=1` `G2` whose key is wrapped under the password. No
/// client sends it any more; a copy in a group's history, and a locked record already stored on a test device,
/// must still parse and still open with the old password. The wire is built here by hand exactly as the retired
/// 3.38.1 admin button built it. Argon2 runs at the cheapest accepted parameters.
final class GroupPasswordFlowTests: XCTestCase {
    let group = "-1001234567890"
    let adminId = "7001"
    let memberId = "7002"
    let ops = GroupPassword.opsMin
    let mem = GroupPassword.memMin
    var nowSeconds: Int64 = 1_789_300_000

    var adminRing: KeyRing!
    var memberStorage: MemoryKeyRingStorage!
    var memberRing: KeyRing!
    var memberProcessor: RekeyProcessor!
    var limiter: GroupPasswordAttemptLimiter!

    override func setUpWithError() throws {
        let clock = { self.nowSeconds * 1000 }
        adminRing = KeyRing(storage: MemoryKeyRingStorage(), clock: clock, epochDays: 1, epochTolerance: 1)
        memberStorage = MemoryKeyRingStorage()
        memberRing = KeyRing(storage: memberStorage, clock: clock, epochDays: 1, epochTolerance: 1)
        memberProcessor = RekeyProcessor(ring: memberRing, clock: clock)
        limiter = GroupPasswordAttemptLimiter(clock: { self.nowSeconds })
    }

    // MARK: helpers

    private func adminPlainKey(at: Int64) throws -> String {
        let master = KeyDerivation.generateMasterKey()
        let signing = try Rekey.generateSigningKeys()
        let id = try adminRing.addMaster(master)
        try adminRing.setChatMaster(chatId: group, masterId: id, label: nil)
        try adminRing.setChatAdminPk(chatId: group, signing.pk)
        try adminRing.setChatAdminSk(chatId: group, signing.sk)
        adminRing.setChatEncryption(chatId: group, enabled: true)
        adminRing.setChatKeyMode(chatId: group, .auto)
        adminRing.setChatNoticeAt(chatId: group, at)
        let payload = KeyPayload.build(masterKey: master, adminPk: signing.pk, mode: .auto)
        return try XCTUnwrap(G2.build(chatId: group, at: at, keyPayload: payload, publisherId: adminId))
    }

    /// What the retired 3.38.1 `GroupPasswordSession.lock` did: a fresh master plus every master known here,
    /// wrapped under the password, sent as `N1` + `pw=1` `G2`, the admin keeping only the locked record.
    private func legacyLock(_ password: String, at: Int64) throws -> (notice: String, broadcast: String) {
        let identity: KeyRing.Identity
        if let existing = adminRing.identity {
            identity = existing
        } else {
            identity = try Rekey.generateIdentity()
            try adminRing.setIdentity(identity)
        }
        let oldAdminPk = adminRing.chatAdminPk(group)
        let master = KeyDerivation.generateMasterKey()
        let signing = try Rekey.generateSigningKeys()
        let history = GroupPassword.normaliseHistory(current: master, history: adminRing.groupPasswordRewrapHistory(group))
        let fields = try GroupPassword.wrapGroupKeys(password: password, groupId: group, current: master, history: history,
                                                     ops: ops, mem: mem)
        let payload = KeyPayload.buildLocked(fields, adminPk: signing.pk, mode: .auto)
        let notice = try Rekey.buildN1(chatId: group, userId: adminId, at: at, mode: .auto, oldAdminPk: oldAdminPk,
                                       newAdminPk: signing.pk, ed25519Sk: identity.ed25519Sk)
        let broadcast = try XCTUnwrap(G2.build(chatId: group, at: at, keyPayload: payload, publisherId: adminId))
        try adminRing.setChatAdminPk(chatId: group, signing.pk)
        try adminRing.setChatAdminSk(chatId: group, signing.sk)
        try adminRing.adoptOwnLockedGroupKey(chatId: group, record: GroupPasswordRecord(fields: fields, at: at, active: true),
                                             current: master, history: history)
        adminRing.setChatEncryption(chatId: group, enabled: true)
        adminRing.setChatKeyMode(chatId: group, .auto)
        adminRing.setChatNoticeAt(chatId: group, at)
        return (notice, broadcast)
    }

    @discardableResult
    private func memberReads(_ wire: String, admin: Bool? = true) -> RekeyProcessor.Result? {
        return memberProcessor.handle(text: wire, chatId: group, senderId: adminId, ownUserId: memberId,
                                      messageDate: nowSeconds, isSenderGroupAdmin: admin)
    }

    private func adminSays(_ text: String) throws -> String {
        let key = try XCTUnwrap(adminRing.currentKey(chatId: group))
        return try E1Codec.encrypt(text: text, entities: nil, keyId: key.keyId, sessionKey: key.sessionKey)
    }

    private func memberOpens(_ wire: String) -> String? {
        let result = E1Codec.decrypt(wire: wire) { [memberRing] keyId in memberRing!.lookupSessionKey(keyId) }
        return result.ok ? result.text : nil
    }

    private func unlock(_ password: String) -> GroupPasswordSession.UnlockResult {
        return GroupPasswordSession.unlock(ring: memberRing, limiter: limiter, chatId: group, password: password)
    }

    // MARK: legacy story

    func testLegacyPw1StillParsesAdoptsAndOpensWithTheOldPassword() throws {
        memberReads(try adminPlainKey(at: 1000))
        let before = try adminSays("before the password")

        let set = try legacyLock("correct horse", at: 2000)
        XCTAssertEqual(memberReads(set.notice)?.ok, true)
        let adopted = try XCTUnwrap(memberReads(set.broadcast))
        XCTAssertEqual(adopted.verdict, .apply)
        XCTAssertTrue(adopted.lockedPayload)
        XCTAssertTrue(adopted.firstLockedAdoption)
        XCTAssertTrue(memberRing.needsLegacyGroupPassword(group))
        XCTAssertFalse(memberRing.needsGroupPassword(group), "3.38.2: a legacy record no longer gates the chat")
        XCTAssertTrue(memberRing.keepsCiphertextLocally(group))

        let during = try adminSays("inside the password")
        XCTAssertNil(memberOpens(during))
        XCTAssertEqual(unlock("wrong horse"), .wrong(.wrongPassword))
        XCTAssertEqual(unlock("correct horse"), .unlocked, "no policy on file: the unlock goes to the legacy record")
        XCTAssertFalse(memberRing.needsLegacyGroupPassword(group))
        XCTAssertEqual(memberOpens(during), "inside the password")
        XCTAssertEqual(memberOpens(before), "before the password", "history arrived wrapped in hist")

        // The admin rebuilds with a plain key (what 〔重建群密钥〕 and every client now send).
        let plain = try adminPlainKey(at: 3000)
        let disabled = try XCTUnwrap(memberReads(plain))
        XCTAssertEqual(disabled.verdict, .apply)
        XCTAssertTrue(disabled.groupPasswordDisabled)
        XCTAssertEqual(memberRing.groupPasswordRecord(group)?.active, false, "the record stays for the old history")
        let after = try adminSays("plain again")
        XCTAssertEqual(memberOpens(after), "plain again")

        // A new run: the plain key survives; the legacy history needs the old password.
        let restarted = KeyRing(storage: memberStorage, clock: { self.nowSeconds * 1000 }, epochDays: 1, epochTolerance: 1)
        XCTAssertEqual(E1Codec.decrypt(wire: after) { restarted.lookupSessionKey($0) }.text, "plain again")
        XCTAssertFalse(E1Codec.decrypt(wire: during) { restarted.lookupSessionKey($0) }.ok)
        XCTAssertTrue(restarted.needsLegacyGroupPassword(group))
        XCTAssertFalse(restarted.needsGroupPassword(group))
        XCTAssertEqual(GroupPasswordSession.unlock(ring: restarted, limiter: limiter, chatId: group, password: "correct horse"),
                       .unlocked)
        XCTAssertEqual(E1Codec.decrypt(wire: during) { restarted.lookupSessionKey($0) }.text, "inside the password")
    }

    func testLegacyRecordAndPolicyCoexist() throws {
        memberReads(try adminPlainKey(at: 1000))
        memberReads(try legacyLock("old legacy pw", at: 2000).broadcast)
        memberReads(try adminPlainKey(at: 3000))
        let policy = try GroupPasswordSession.setPassword(ring: adminRing, chatId: group, ownUserId: adminId,
                                                          password: "new policy pw", at: 4000, ops: ops, mem: mem)
        memberReads(policy.broadcast)
        XCTAssertTrue(memberRing.needsGroupPassword(group))
        XCTAssertEqual(unlock("old legacy pw"), .wrong(.wrongPassword), "while locked, the policy is what is asked")
        XCTAssertEqual(unlock("new policy pw"), .unlocked)
        XCTAssertFalse(memberRing.needsGroupPassword(group))
        XCTAssertTrue(memberRing.needsLegacyGroupPassword(group), "the policy unlock opens no legacy record")
        XCTAssertEqual(unlock("old legacy pw"), .unlocked, "then the legacy record")
        XCTAssertFalse(memberRing.needsLegacyGroupPassword(group))
    }

    // MARK: legacy pieces

    func testTheUnlockTableIsMemoryOnlyAndTheRecordPersists() throws {
        memberReads(try adminPlainKey(at: 1000))
        memberReads(try legacyLock("persisted pw", at: 2000).broadcast)
        XCTAssertEqual(unlock("persisted pw"), .unlocked)
        let data = SnapshotCodec.encode(try XCTUnwrap(memberStorage.saved))
        let decoded = try XCTUnwrap(SnapshotCodec.decode(data))
        XCTAssertEqual(decoded.chatGroupPasswords[group], memberRing.groupPasswordRecord(group))
        XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "unlocked"))
        let restarted = KeyRing(storage: MemoryKeyRingStorage(decoded), clock: { self.nowSeconds * 1000 }, epochDays: 1, epochTolerance: 1)
        XCTAssertTrue(restarted.needsLegacyGroupPassword(group))
    }

    func testAnOlderSnapshotWithoutTheFieldsDecodes() throws {
        let legacy = #"{"v":2,"masters":{},"chat_masters":{}}"#.data(using: .utf8)!
        let decoded = try XCTUnwrap(SnapshotCodec.decode(legacy))
        XCTAssertTrue(decoded.chatGroupPasswords.isEmpty)
        XCTAssertTrue(decoded.chatMasterHistory.isEmpty)
    }

    func testEmergencyWipeAndClearEmptyTheLegacyUnlockTable() throws {
        memberReads(try adminPlainKey(at: 1000))
        memberReads(try legacyLock("wipe me now", at: 2000).broadcast)
        XCTAssertEqual(unlock("wipe me now"), .unlocked)
        let during = try adminSays("secret")
        XCTAssertEqual(memberOpens(during), "secret")
        memberRing.clearGroupUnlocks()
        XCTAssertNil(memberOpens(during), "the session-key cache went with the unlock")
        XCTAssertEqual(unlock("wipe me now"), .unlocked)
        memberRing.destroyAllKeys()
        XCTAssertFalse(memberRing.isGroupPasswordUnlocked(group))
        XCTAssertNil(memberOpens(during))
    }

    func testOwnEchoAndHistoryReplay() throws {
        memberReads(try adminPlainKey(at: 1000))
        let set = try legacyLock("echo echo", at: 2000)
        let own = RekeyProcessor(ring: adminRing, clock: { self.nowSeconds * 1000 })
            .handle(text: set.broadcast, chatId: group, senderId: adminId, ownUserId: adminId, messageDate: nowSeconds,
                    isSenderGroupAdmin: true)
        XCTAssertEqual(own?.verdict, .own)
        XCTAssertEqual(own?.lockedPayload, true)
        memberReads(set.broadcast)
        let replay = memberReads(set.broadcast)
        XCTAssertEqual(replay?.verdict, .stale)
        XCTAssertEqual(replay?.firstLockedAdoption, false)
    }

    func testTheAdminGateAndParking() throws {
        memberReads(try adminPlainKey(at: 1000))
        let set = try legacyLock("gate check", at: 2000)
        XCTAssertEqual(memberReads(set.broadcast, admin: nil)?.verdict, .park)
        XCTAssertNil(memberRing.groupPasswordRecord(group), "nothing stored while parked")
        XCTAssertEqual(memberReads(set.broadcast, admin: false)?.verdict, .refuseNotAdmin)
        XCTAssertNotNil(memberRing.chatMasterId(group), "a refused broadcast deletes nothing")
    }

    func testARecordNoClientCouldOpenIsRefusedAndDeletesNothing() throws {
        memberReads(try adminPlainKey(at: 1000))
        let good = try GroupPassword.wrapGroupKeys(password: "whatever pw", groupId: group,
                                                   current: KeyDerivation.generateMasterKey(), ops: ops, mem: mem)
        let payload = KeyPayload.buildLocked(good.with(kdf: "scrypt"), adminPk: nil, mode: .auto)
        let wire = try XCTUnwrap(G2.build(chatId: group, at: 2000, keyPayload: payload, publisherId: adminId))
        let result = memberReads(wire)
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.reason, "unsupported_kdf")
        XCTAssertNotNil(memberRing.chatMasterId(group))
        XCTAssertNil(memberRing.groupPasswordRecord(group))
    }

    func testAnAutoRetireNoticeStopsSendingUnderTheLockedKey() throws {
        memberReads(try adminPlainKey(at: 1000))
        memberReads(try legacyLock("retire test", at: 2000).broadcast)
        XCTAssertEqual(unlock("retire test"), .unlocked)
        XCTAssertNotNil(memberRing.currentKey(chatId: group))
        memberReads(try legacyLock("next generation", at: 3000).notice)
        XCTAssertNil(memberRing.currentKey(chatId: group), "3.34.4: no sending until the new key lands")
        XCTAssertEqual(memberRing.groupPasswordRecord(group)?.active, false)
    }

    func testMastersOfOtherChatsAreNeverDeleted() throws {
        let other = "-1009999999999"
        let id = try memberRing.addMaster(KeyDerivation.generateMasterKey())
        try memberRing.setChatMaster(chatId: other, masterId: id, label: nil)
        try memberRing.setChatMaster(chatId: group, masterId: id, label: nil)
        memberReads(try adminPlainKey(at: 1000))
        memberReads(try legacyLock("keep others", at: 2000).broadcast)
        XCTAssertNotNil(memberRing.masterKey(for: id), "still bound to another chat")
        XCTAssertEqual(memberRing.chatMasterId(other), id)
    }

    func testLimiterCountsPerGroupAndResets() {
        let l = GroupPasswordAttemptLimiter(clock: { self.nowSeconds })
        for _ in 0..<4 { XCTAssertNil(l.recordFailure(chatId: "-1")) }
        XCTAssertNil(l.recordFailure(chatId: "-2"), "another group has its own count")
        l.recordSuccess(chatId: "-1")
        for _ in 0..<4 { XCTAssertNil(l.recordFailure(chatId: "-1")) }
        XCTAssertEqual(l.recordFailure(chatId: "-1"), 60)
        XCTAssertEqual(l.remainingLockout(chatId: "-1"), 60)
        l.reset()
        XCTAssertNil(l.remainingLockout(chatId: "-1"))
    }
}
