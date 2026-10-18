import XCTest
@testable import SecutgCore

/// PLAN.md 3.38.2 end to end: one admin and one member, talking only through the wire strings the real clients
/// post (`G2`, `E1`, `GP1`). The password is a gate; the messages always travel under the ordinary group key.
/// Argon2 runs at the cheapest parameters every client still accepts (ops 1, 8 MiB) so the suite stays fast;
/// the default parameters are covered by the cross-client vector.
final class GroupPasswordPolicyFlowTests: XCTestCase {
    let group = "-1001234567890"
    let adminId = "7001"
    let memberId = "7002"
    let ops = GroupPassword.opsMin
    let mem = GroupPassword.memMin
    var nowSeconds: Int64 = 1_789_300_000

    var adminStorage: MemoryKeyRingStorage!
    var adminRing: KeyRing!
    var memberStorage: MemoryKeyRingStorage!
    var memberRing: KeyRing!
    var memberProcessor: RekeyProcessor!
    var limiter: GroupPasswordAttemptLimiter!

    override func setUpWithError() throws {
        let clock = { self.nowSeconds * 1000 }
        adminStorage = MemoryKeyRingStorage()
        adminRing = KeyRing(storage: adminStorage, clock: clock, epochDays: 1, epochTolerance: 1)
        memberStorage = MemoryKeyRingStorage()
        memberRing = KeyRing(storage: memberStorage, clock: clock, epochDays: 1, epochTolerance: 1)
        memberProcessor = RekeyProcessor(ring: memberRing, clock: clock)
        limiter = GroupPasswordAttemptLimiter(clock: { self.nowSeconds })
    }

    // MARK: helpers

    /// The admin's ordinary auto-mode rebuild — the only road a master takes, password or not.
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

    @discardableResult
    private func memberReads(_ wire: String, admin: Bool? = true, sender: String? = nil) -> RekeyProcessor.Result? {
        return memberProcessor.handle(text: wire, chatId: group, senderId: sender ?? adminId, ownUserId: memberId,
                                      messageDate: nowSeconds, isSenderGroupAdmin: admin)
    }

    private func says(_ ring: KeyRing, _ text: String) throws -> String {
        let key = try XCTUnwrap(ring.currentKey(chatId: group))
        return try E1Codec.encrypt(text: text, entities: nil, keyId: key.keyId, sessionKey: key.sessionKey)
    }

    private func opens(_ ring: KeyRing, _ wire: String) -> String? {
        let result = E1Codec.decrypt(wire: wire) { ring.lookupSessionKey($0) }
        return result.ok ? result.text : nil
    }

    private func setPassword(_ password: String, at: Int64) throws -> GroupPasswordSession.PolicyBuilt {
        return try GroupPasswordSession.setPassword(ring: adminRing, chatId: group, ownUserId: adminId, password: password,
                                                    at: at, ops: ops, mem: mem)
    }

    private func unlock(_ ring: KeyRing, _ password: String) -> GroupPasswordSession.UnlockResult {
        return GroupPasswordSession.unlock(ring: ring, limiter: limiter, chatId: group, password: password)
    }

    // MARK: the whole story

    func testSetAdoptLockedUnlockChangeOffEverythingReadableRekeyIndependent() throws {
        memberRing.setLocalCiphertext(false) // 3.19's own switch off: what is left is what the gate forces
        memberReads(try adminPlainKey(at: 1000))
        let masterId = try XCTUnwrap(memberRing.chatMasterId(group))
        let before = try says(adminRing, "before the password")
        XCTAssertEqual(opens(memberRing, before), "before the password")

        // set → one GP1, nothing else; no master moves anywhere.
        let set = try setPassword("correct horse", at: 2000)
        XCTAssertTrue(set.turnedOn)
        XCTAssertTrue(GP1.isGP1(set.broadcast))
        XCTAssertFalse(set.broadcast.contains("secutg://"))
        XCTAssertFalse(adminRing.needsGroupPassword(group), "the admin typed it, so this run is unlocked")
        XCTAssertEqual(adminRing.chatMasterId(group), masterId, "no rebuild")
        XCTAssertEqual(adminRing.chatNoticeAt(group), 1000, "the key anchor is not the policy's")

        // adopt → locked.
        let adopted = try XCTUnwrap(memberReads(set.broadcast))
        XCTAssertTrue(adopted.isGroupPasswordPolicy)
        XCTAssertFalse(adopted.isGroupKey)
        XCTAssertEqual(adopted.verdict, .apply)
        XCTAssertEqual(adopted.policyOn, true)
        XCTAssertTrue(adopted.policyTurnedOn, "first adoption of an on policy: the glue drops the local cache")
        XCTAssertTrue(memberRing.needsGroupPassword(group), "locked: page, masking, no send")
        XCTAssertTrue(memberRing.keepsCiphertextLocally(group), "3.19 forced while the policy is on")
        XCTAssertEqual(memberRing.chatMasterId(group), masterId, "masters stay plain")
        XCTAssertNotNil(memberRing.masterKey(for: masterId))

        // Messages of the locked period decrypt with the normal key — the lock is the UI's, never the crypto's.
        let during = try says(adminRing, "inside the password")
        XCTAssertEqual(opens(memberRing, during), "inside the password")
        XCTAssertEqual(opens(memberRing, before), "before the password")

        // wrong / right.
        XCTAssertEqual(unlock(memberRing, "wrong horse"), .wrong(.wrongPassword))
        XCTAssertTrue(memberRing.needsGroupPassword(group))
        XCTAssertEqual(unlock(memberRing, "correct horse"), .unlocked)
        XCTAssertFalse(memberRing.needsGroupPassword(group))
        XCTAssertTrue(memberRing.keepsCiphertextLocally(group), "3.19 stays forced after unlock: the disk outlives the run")
        let reply = try says(memberRing, "reply")
        XCTAssertEqual(opens(adminRing, reply), "reply")

        // rekey independent: a rebuild while the password is on changes the key and nothing about the gate.
        let rebuild = try adminPlainKey(at: 2500)
        XCTAssertEqual(memberReads(rebuild)?.verdict, .apply)
        XCTAssertNotEqual(memberRing.chatMasterId(group), masterId)
        XCTAssertFalse(memberRing.needsGroupPassword(group), "still unlocked: same policy")
        XCTAssertEqual(memberRing.groupPasswordPolicy(group), set.policy)
        XCTAssertEqual(adminRing.groupPasswordPolicy(group), set.policy)
        let afterRebuild = try says(adminRing, "after the rebuild")
        XCTAssertEqual(opens(memberRing, afterRebuild), "after the rebuild")

        // change → a new salt, locked again by itself; the old password no longer opens it.
        let change = try setPassword("battery staple", at: 3000)
        XCTAssertFalse(change.turnedOn)
        XCTAssertNotEqual(change.policy.payload.params?.salt, set.policy.payload.params?.salt)
        let changed = try XCTUnwrap(memberReads(change.broadcast))
        XCTAssertEqual(changed.verdict, .apply)
        XCTAssertFalse(changed.policyTurnedOn, "on → on keeps the cache")
        XCTAssertTrue(memberRing.needsGroupPassword(group))
        XCTAssertEqual(unlock(memberRing, "correct horse"), .wrong(.wrongPassword))
        XCTAssertEqual(unlock(memberRing, "battery staple"), .unlocked)

        // A new run starts locked; the stored policy survives, the unlock does not.
        let restarted = KeyRing(storage: memberStorage, clock: { self.nowSeconds * 1000 }, epochDays: 1, epochTolerance: 1)
        XCTAssertTrue(restarted.needsGroupPassword(group))
        XCTAssertEqual(opens(restarted, during), "inside the password", "still decryptable — only the UI is gated")

        // off → a GP1 off; nothing needs a password, every message ever sent is readable, no key changed.
        let keyBeforeOff = memberRing.chatMasterId(group)
        let off = try GroupPasswordSession.disablePassword(ring: adminRing, chatId: group, ownUserId: adminId, at: 4000)
        XCTAssertFalse(off.turnedOn)
        XCTAssertFalse(off.policy.isOn)
        let disabled = try XCTUnwrap(memberReads(off.broadcast))
        XCTAssertEqual(disabled.verdict, .apply)
        XCTAssertEqual(disabled.policyOn, false)
        XCTAssertFalse(memberRing.needsGroupPassword(group))
        XCTAssertEqual(memberRing.chatMasterId(group), keyBeforeOff)

        let fresh = KeyRing(storage: memberStorage, clock: { self.nowSeconds * 1000 }, epochDays: 1, epochTolerance: 1)
        XCTAssertFalse(fresh.needsGroupPassword(group), "no password needed in a new run either")
        for (wire, text) in [(before, "before the password"), (during, "inside the password"),
                             (afterRebuild, "after the rebuild"), (reply, "reply")] {
            XCTAssertEqual(opens(fresh, wire), text, "the bug 3.38.2 fixes: history stays readable after off")
        }
        XCTAssertNil(fresh.groupPasswordRecord(group), "no legacy record was ever made")
    }

    // MARK: admin gate (the same three states and `at` ordering as G2)

    func testParkThenApplyWhenTheAdminListArrives() throws {
        let set = try setPassword("gate check", at: 2000)
        let parked = try XCTUnwrap(memberReads(set.broadcast, admin: nil))
        XCTAssertEqual(parked.verdict, .park)
        XCTAssertEqual(parked.reason, "pending")
        XCTAssertFalse(parked.ok)
        XCTAssertNil(memberRing.groupPasswordPolicy(group), "nothing stored while parked")
        XCTAssertEqual(memberProcessor.parkedNoticeCount(chatId: group), 0, "a policy is not a notice")
        let retried = try XCTUnwrap(memberReads(set.broadcast, admin: true))
        XCTAssertEqual(retried.verdict, .apply)
        XCTAssertTrue(memberRing.needsGroupPassword(group))
    }

    func testNotAnAdminIsRefusedAndRecordsNothing() throws {
        let set = try setPassword("gate check", at: 2000)
        let refused = try XCTUnwrap(memberReads(set.broadcast, admin: false))
        XCTAssertEqual(refused.verdict, .refuseNotAdmin)
        XCTAssertFalse(refused.ok)
        XCTAssertNil(memberRing.groupPasswordPolicy(group))
        XCTAssertEqual(memberReads(set.broadcast)?.verdict, .apply, "a later, right answer still applies")
    }

    func testOnlyTheNewestAtCounts() throws {
        let set = try setPassword("first pass", at: 2000)
        let off = try GroupPasswordSession.disablePassword(ring: adminRing, chatId: group, ownUserId: adminId, at: 3000)
        // History is read newest first: the off lands, then the older on is stale.
        XCTAssertEqual(memberReads(off.broadcast)?.verdict, .apply)
        let stale = try XCTUnwrap(memberReads(set.broadcast))
        XCTAssertEqual(stale.verdict, .stale)
        XCTAssertFalse(stale.policyTurnedOn)
        XCTAssertFalse(memberRing.needsGroupPassword(group))
        XCTAssertEqual(memberReads(off.broadcast)?.verdict, .stale, "a replay of the same one changes nothing")
        // Same `at`, different content: still stale — the first one to land at that time is the one kept.
        let sameAt = try XCTUnwrap(GP1.build(chatId: group, at: 3000, payload: set.policy.payload, publisherId: adminId))
        XCTAssertEqual(memberReads(sameAt)?.verdict, .stale)
    }

    func testThePolicyAnchorIsNotTheKeyAnchor() throws {
        memberReads(try adminPlainKey(at: 5000))
        let set = try setPassword("anchor test", at: 2000)
        XCTAssertEqual(memberReads(set.broadcast)?.verdict, .apply, "an older key anchor does not make a policy stale")
        XCTAssertEqual(memberRing.chatNoticeAt(group), 5000, "and the policy never moves the key anchor")
    }

    func testTheAdminsOwnEchoAndAnotherDeviceOfTheSameAccount() throws {
        let set = try setPassword("echo echo", at: 2000)
        let own = RekeyProcessor(ring: adminRing, clock: { self.nowSeconds * 1000 })
            .handle(text: set.broadcast, chatId: group, senderId: adminId, ownUserId: adminId, messageDate: nowSeconds,
                    isSenderGroupAdmin: true)
        XCTAssertEqual(own?.verdict, .own)
        XCTAssertEqual(own?.ok, true)
        XCTAssertFalse(adminRing.needsGroupPassword(group), "the echo does not relock the admin")

        let secondRing = KeyRing(storage: MemoryKeyRingStorage(), clock: { self.nowSeconds * 1000 }, epochDays: 1, epochTolerance: 1)
        let second = RekeyProcessor(ring: secondRing, clock: { self.nowSeconds * 1000 })
            .handle(text: set.broadcast, chatId: group, senderId: adminId, ownUserId: adminId, messageDate: nowSeconds,
                    isSenderGroupAdmin: true)
        XCTAssertEqual(second?.verdict, .apply, "3.35.9: the admin's other device holds nothing yet")
        XCTAssertTrue(secondRing.needsGroupPassword(group), "and has to type the password like anybody else")
    }

    func testStructuralRefusals() throws {
        let set = try setPassword("refusals", at: 2000)
        XCTAssertEqual(memberReads(set.broadcast, sender: "7009")?.reason, "sender_mismatch")
        let otherGroup = memberProcessor.handle(text: set.broadcast, chatId: "-1009999999999", senderId: adminId,
                                                ownUserId: memberId, messageDate: nowSeconds, isSenderGroupAdmin: true)
        XCTAssertEqual(otherGroup?.reason, "wrong_chat")
        let noSender = memberProcessor.handle(text: set.broadcast, chatId: group, senderId: nil, ownUserId: memberId,
                                              messageDate: nowSeconds, isSenderGroupAdmin: true)
        XCTAssertEqual(noSender?.reason, "no_sender")
        let garbage = memberReads("GP1:not a policy")
        XCTAssertEqual(garbage?.isGroupPasswordPolicy, true)
        XCTAssertEqual(garbage?.reason, "malformed")
        XCTAssertNil(memberRing.groupPasswordPolicy(group))
    }

    func testAPolicyNoPasswordCouldOpenIsRefused() throws {
        let unusable = [
            (GroupPasswordPolicyParams(kdf: "scrypt", ops: ops, mem: mem, salt: Array(0..<16), verifier: Array(repeating: 1, count: 32)), "unsupported_kdf"),
            (GroupPasswordPolicyParams(kdf: "argon2id13", ops: 11, mem: mem, salt: Array(0..<16), verifier: Array(repeating: 1, count: 32)), "params_out_of_range"),
            (GroupPasswordPolicyParams(kdf: "argon2id13", ops: ops, mem: 8 * 1024 * 1024 + 1, salt: Array(0..<16), verifier: Array(repeating: 1, count: 32)), "params_out_of_range"),
        ]
        for (params, _) in unusable {
            // Built by hand: `GP1.build` refuses to produce it.
            let obfuscated = try XCTUnwrap(G2Obfuscation.obfuscate(GroupPassword.buildPolicyPayload(.on(params))))
            let wire = "GP1:\(group):2000:\(Base64Url.encode(obfuscated)):\(adminId)"
            let reason = "malformed"
            let result = try XCTUnwrap(memberReads(wire))
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.reason, reason)
            XCTAssertNil(memberRing.groupPasswordPolicy(group))
        }
    }

    // MARK: admin rules

    func testChangeAndOffNeedThisRunToHaveUnlocked() throws {
        _ = try setPassword("admin password", at: 2000)
        adminRing = KeyRing(storage: adminStorage, clock: { self.nowSeconds * 1000 }, epochDays: 1, epochTolerance: 1)
        XCTAssertTrue(adminRing.needsGroupPassword(group), "the admin types it too after a restart")
        XCTAssertThrowsError(try setPassword("another pass", at: 3000)) { error in
            XCTAssertEqual(error as? GroupPasswordSession.Failure, .notUnlocked)
        }
        XCTAssertThrowsError(try GroupPasswordSession.disablePassword(ring: adminRing, chatId: group, ownUserId: adminId, at: 3000)) {
            XCTAssertEqual($0 as? GroupPasswordSession.Failure, .notUnlocked)
        }
        XCTAssertEqual(unlock(adminRing, "admin password"), .unlocked)
        XCTAssertNoThrow(try setPassword("another pass", at: 3000))
    }

    func testPasswordRulesAndGroupsOnly() throws {
        XCTAssertThrowsError(try setPassword("12345", at: 2000)) {
            XCTAssertEqual($0 as? GroupPasswordSession.Failure, .passwordRejected(.tooShort))
        }
        XCTAssertNil(adminRing.groupPasswordPolicy(group))
        XCTAssertThrowsError(try GroupPasswordSession.setPassword(ring: adminRing, chatId: "7002", ownUserId: adminId,
                                                                  password: "long enough", at: 2000, ops: ops, mem: mem)) {
            XCTAssertEqual($0 as? GroupPasswordSession.Failure, .notGroup)
        }
    }

    func testTwoActionsInTheSameSecondStillOrder() throws {
        let set = try setPassword("same second", at: 2000)
        let off = try GroupPasswordSession.disablePassword(ring: adminRing, chatId: group, ownUserId: adminId, at: 2000)
        XCTAssertGreaterThan(off.policy.at, set.policy.at)
        memberReads(set.broadcast)
        XCTAssertEqual(memberReads(off.broadcast)?.verdict, .apply)
        XCTAssertFalse(memberRing.needsGroupPassword(group))
    }

    // MARK: session rules

    func testFiveWrongPasswordsLockForAMinute() throws {
        memberReads(try setPassword("limiter pw", at: 2000).broadcast)
        for _ in 0..<4 { XCTAssertEqual(unlock(memberRing, "nope nope"), .wrong(.wrongPassword)) }
        XCTAssertEqual(unlock(memberRing, "nope nope"), .tooMany(seconds: 60))
        nowSeconds += 30
        XCTAssertEqual(unlock(memberRing, "limiter pw"), .tooMany(seconds: 30), "even the right one waits")
        nowSeconds += 30
        XCTAssertEqual(unlock(memberRing, "limiter pw"), .unlocked)
    }

    func testEmergencyWipeAndClearRelock() throws {
        memberReads(try setPassword("wipe me now", at: 2000).broadcast)
        XCTAssertEqual(unlock(memberRing, "wipe me now"), .unlocked)
        memberRing.clearGroupUnlocks()
        XCTAssertTrue(memberRing.needsGroupPassword(group))
        XCTAssertEqual(unlock(memberRing, "wipe me now"), .unlocked)
        memberRing.destroyAllKeys()
        XCTAssertFalse(memberRing.isGroupPasswordPolicyUnlocked(group))
        XCTAssertNil(memberRing.groupPasswordPolicy(group))
    }

    func testUnlockWithNothingOnFile() {
        XCTAssertEqual(unlock(memberRing, "anything"), .noRecord)
    }

    func testAdminSendsNoPw1G2AnyMore() throws {
        memberReads(try adminPlainKey(at: 1000))
        let set = try setPassword("no rebuild", at: 2000)
        XCTAssertNil(G2.parse(set.broadcast))
        XCTAssertNil(Rekey.parseN1(set.broadcast))
        XCTAssertNil(adminRing.groupPasswordRecord(group), "no locked record is ever made")
    }
}
