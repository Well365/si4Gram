import XCTest
@testable import SecutgCore

/// PLAN.md 3.38.2: the `GP1` policy message, its payload, the verifier and the stored policy.
final class GroupPasswordPolicyTests: XCTestCase {
    let group = "-1001234567890"
    let cheapOps = GroupPassword.opsMin
    let cheapMem = GroupPassword.memMin

    private func params(kdf: String = GroupPassword.kdfArgon2id13, ops: Int = 2, mem: Int = 67_108_864,
                        salt: [UInt8] = Array(0..<16), verifier: [UInt8] = Array(repeating: 7, count: 32)) -> GroupPasswordPolicyParams {
        return GroupPasswordPolicyParams(kdf: kdf, ops: ops, mem: mem, salt: salt, verifier: verifier)
    }

    // MARK: cross-client vector (PLAN.md 3.38.2 跨端向量)

    func testCrossClientVector() throws {
        let salt = Vectors.hex("000102030405060708090a0b0c0d0e0f")
        let kek = try GroupPassword.deriveKek(password: "correct horse", salt: salt, ops: 2, mem: 67_108_864)
        XCTAssertEqual(Hex.encode(kek[...]), "9aab5a81db651bf866ff7b6169794d2ad9bb00f3d95177925a5fca692a34dbd1")
        let verifier = try GroupPassword.computeVerifier(kek: kek, groupId: group)
        XCTAssertEqual(Hex.encode(verifier[...]), "514e5ba3bde3f3ce38806874db3e163601d68de3efa491578de1f3800c3916b4")

        let made = try GroupPassword.makePolicyParams(password: "correct horse", groupId: group, ops: 2, mem: 67_108_864, salt: salt)
        XCTAssertEqual(made, GroupPasswordPolicyParams(kdf: "argon2id13", ops: 2, mem: 67_108_864, salt: salt, verifier: verifier))
        XCTAssertEqual(GroupPassword.buildPolicyPayload(.on(made)),
                       "secutg://grouppw?v=1&on=1&kdf=argon2id13&ops=2&mem=67108864&salt=AAECAwQFBgcICQoLDA0ODw"
                       + "&verifier=" + Base64Url.encode(verifier))
        XCTAssertNil(GroupPassword.verifyPolicy(made, password: "correct horse", groupId: group))
        XCTAssertEqual(GroupPassword.verifyPolicy(made, password: "correct horsE", groupId: group), .wrongPassword)
    }

    func testVerifierIsKeyedAndBoundToTheGroup() throws {
        let made = try GroupPassword.makePolicyParams(password: "six chars", groupId: group, ops: cheapOps, mem: cheapMem)
        XCTAssertNil(GroupPassword.verifyPolicy(made, password: "six chars", groupId: group))
        XCTAssertEqual(GroupPassword.verifyPolicy(made, password: "six chars", groupId: "-1009999999999"), .wrongPassword)
        let otherSalt = GroupPasswordPolicyParams(kdf: made.kdf, ops: made.ops, mem: made.mem,
                                                  salt: Array(repeating: 1, count: 16), verifier: made.verifier)
        XCTAssertEqual(GroupPassword.verifyPolicy(otherSalt, password: "six chars", groupId: group), .wrongPassword)
        XCTAssertEqual(GroupPassword.verifyPolicy(params(kdf: "scrypt"), password: "six chars", groupId: group), .unsupportedKdf)
        XCTAssertEqual(GroupPassword.verifyPolicy(params(ops: 11), password: "six chars", groupId: group), .paramsOutOfRange)
        XCTAssertThrowsError(try GroupPassword.makePolicyParams(password: "short", groupId: group, ops: cheapOps, mem: cheapMem))
        XCTAssertThrowsError(try GroupPassword.computeVerifier(kek: [1, 2, 3], groupId: group))
    }

    func testNfcPasswordsVerifyTheSame() throws {
        let composed = "caf\u{e9} au lait"
        let decomposed = "cafe\u{301} au lait"
        let made = try GroupPassword.makePolicyParams(password: composed, groupId: group, ops: cheapOps, mem: cheapMem)
        XCTAssertNil(GroupPassword.verifyPolicy(made, password: decomposed, groupId: group))
    }

    // MARK: payload

    func testPayloadRoundTrip() {
        let on = GroupPasswordPolicyPayload.on(params())
        XCTAssertEqual(GroupPassword.parsePolicyPayload(GroupPassword.buildPolicyPayload(on)), on)
        XCTAssertEqual(GroupPassword.buildPolicyPayload(.off), "secutg://grouppw?v=1&on=0")
        XCTAssertEqual(GroupPassword.parsePolicyPayload("secutg://grouppw?v=1&on=0"), .off)
        // As Web: a policy no client could use (unknown kdf, params out of range) is not a policy at all.
        for unusable in [params(kdf: "argon2id99"), params(ops: 11), params(mem: 67_108_865)] {
            XCTAssertFalse(unusable.isUsable)
            XCTAssertNil(GroupPassword.parsePolicyPayload(GroupPassword.buildPolicyPayload(.on(unusable))))
            XCTAssertNil(GP1.build(chatId: group, at: 1, payload: .on(unusable), publisherId: "7001"))
        }
    }

    func testPayloadParseIsStrict() {
        let good = GroupPassword.buildPolicyPayload(.on(params()))
        XCTAssertNotNil(GroupPassword.parsePolicyPayload(good))
        let salt = Base64Url.encode(Array(0..<16))
        let ver = Base64Url.encode(Array(repeating: 7, count: 32))
        let bad = [
            "secutg://grouppw?on=0&v=1",                                   // order
            "secutg://grouppw?v=1&on=0&kdf=argon2id13",                    // off with extra fields
            "secutg://grouppw?v=2&on=0",                                   // version
            "secutg://grouppw?v=01&on=0",
            "secutg://grouppw?v=1&on=2",
            "secutg://grouppw?v=1",
            "secutg://grouppw?v=1&on=0&",
            "secutg://key?v=1&on=0",
            "secutg://grouppw?v=1&v=1&on=0",
            "secutg://grouppw?v=1&on=1",                                   // on without fields
            "secutg://grouppw?v=1&on=1&kdf=argon2id13&ops=02&mem=67108864&salt=\(salt)&verifier=\(ver)",
            "secutg://grouppw?v=1&on=1&kdf=argon2id13&ops=0&mem=67108864&salt=\(salt)&verifier=\(ver)",
            "secutg://grouppw?v=1&on=1&kdf=Argon2id13&ops=2&mem=67108864&salt=\(salt)&verifier=\(ver)",
            "secutg://grouppw?v=1&on=1&kdf=argon2id13&mem=67108864&ops=2&salt=\(salt)&verifier=\(ver)",
            "secutg://grouppw?v=1&on=1&kdf=argon2id13&ops=2&mem=67108864&salt=\(salt)==&verifier=\(ver)",
            "secutg://grouppw?v=1&on=1&kdf=argon2id13&ops=2&mem=67108864&salt=\(Base64Url.encode(Array(0..<15)))&verifier=\(ver)",
            "secutg://grouppw?v=1&on=1&kdf=argon2id13&ops=2&mem=67108864&salt=\(salt)&verifier=\(Base64Url.encode(Array(repeating: 7, count: 31)))",
            "secutg://grouppw?v=1&on=1&kdf=argon2id13&ops=2&mem=67108864&salt=\(salt)&verifier=\(ver)&x=1",
            "secutg://grouppw?v=1&on=1&kdf=argon2id13&ops=2&mem=67108864&salt=\(salt)&verifier=\(ver)&",
            "secutg://grouppw?v=1&on=1&kdf=argon2id13&ops=2&mem=67108864&salt=\(salt)",
        ]
        for text in bad { XCTAssertNil(GroupPassword.parsePolicyPayload(text), text) }
    }

    // MARK: GP1

    func testGP1RoundTripAndObfuscation() throws {
        for payload in [GroupPasswordPolicyPayload.on(params()), .off] {
            let wire = try XCTUnwrap(GP1.build(chatId: group, at: 1_789_300_000, payload: payload, publisherId: "7001"))
            XCTAssertTrue(wire.hasPrefix("GP1:\(group):1789300000:"))
            XCTAssertTrue(wire.hasSuffix(":7001"))
            XCTAssertFalse(wire.contains("secutg://"), "behind the 3.35.8 obfuscation layer, like G2")
            XCTAssertTrue(GP1.isGP1(wire))
            XCTAssertTrue(Rekey.isControlMessage(wire), "never re-encrypted as text, never shown as text")
            XCTAssertFalse(G2.isG2(wire))
            XCTAssertEqual(GP1.parse(wire), GP1.Parsed(chatId: group, at: 1_789_300_000, payload: payload, publisherId: "7001"))
        }
    }

    func testGP1ParseIsStrict() throws {
        let wire = try XCTUnwrap(GP1.build(chatId: group, at: 5, payload: .off, publisherId: "7001"))
        let parts = wire.components(separatedBy: ":")
        let wrappedG2Payload = try XCTUnwrap(G2Obfuscation.obfuscate("secutg://key?k=abc"))
        let bad = [
            "GP1:1001234567890:5:\(parts[3]):7001",                        // not a group
            "GP1:\(group):5:\(parts[3])",                                  // no publisher
            "GP1:\(group):-5:\(parts[3]):7001",
            "GP1:\(group):5:\(parts[3])=:7001",                            // padded
            "GP1:\(group):5:\(parts[3].dropLast(2)):7001",                 // truncated → tag fails
            "GP1:\(group):5:\(Base64Url.encode(wrappedG2Payload)):7001",   // a G2 key payload in GP1 clothing
            "GP1:\(group):5:\(Base64Url.encode(Array("secutg://grouppw?v=1&on=0".utf8))):7001", // not obfuscated
            "GP1:\(group):9007199254740992:\(parts[3]):7001",              // past MAX_SAFE_INTEGER
            " " + wire,
        ]
        for text in bad { XCTAssertNil(GP1.parse(text), text) }
        XCTAssertNil(GP1.build(chatId: "7002", at: 5, payload: .off, publisherId: "7001"), "groups only")
    }

    // MARK: stored policy

    func testSnapshotRoundTripAndBackwardCompatibility() throws {
        var snapshot = KeyRing.Snapshot()
        let policy = GroupPasswordPolicy(payload: .on(params()), at: 42)
        snapshot.chatGroupPasswordPolicies[group] = policy
        snapshot.chatGroupPasswordPolicies["-1002"] = GroupPasswordPolicy(payload: .off, at: 7)
        let decoded = try XCTUnwrap(SnapshotCodec.decode(SnapshotCodec.encode(snapshot)))
        XCTAssertEqual(decoded.chatGroupPasswordPolicies, snapshot.chatGroupPasswordPolicies)

        let older = #"{"v":2,"masters":{},"chat_masters":{}}"#.data(using: .utf8)!
        XCTAssertTrue(try XCTUnwrap(SnapshotCodec.decode(older)).chatGroupPasswordPolicies.isEmpty)
    }

    func testAnUnusablePolicyIsNotRestored() throws {
        var snapshot = KeyRing.Snapshot()
        snapshot.chatGroupPasswordPolicies[group] = GroupPasswordPolicy(payload: .on(params(kdf: "scrypt")), at: 1)
        let storage = MemoryKeyRingStorage(snapshot)
        let ring = KeyRing(storage: storage, clock: { 0 }, epochDays: 1, epochTolerance: 1)
        XCTAssertNil(ring.groupPasswordPolicy(group))
        XCTAssertFalse(ring.needsGroupPassword(group))
    }

    func testTheUnlockTableIsKeyedByThePolicy() {
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { 0 }, epochDays: 1, epochTolerance: 1)
        let first = params(salt: Array(repeating: 1, count: 16))
        let second = params(salt: Array(repeating: 2, count: 16))
        XCTAssertTrue(ring.adoptGroupPasswordPolicy(chatId: group, policy: GroupPasswordPolicy(payload: .on(first), at: 1)))
        XCTAssertTrue(ring.needsGroupPassword(group))
        XCTAssertFalse(ring.unlockGroupPasswordPolicy(chatId: group, params: second), "not the policy on file")
        XCTAssertTrue(ring.needsGroupPassword(group))
        XCTAssertTrue(ring.unlockGroupPasswordPolicy(chatId: group, params: first))
        XCTAssertFalse(ring.needsGroupPassword(group))
        XCTAssertFalse(ring.adoptGroupPasswordPolicy(chatId: group, policy: GroupPasswordPolicy(payload: .on(second), at: 2)),
                       "on → on is a change, not a first adoption")
        XCTAssertTrue(ring.needsGroupPassword(group), "a changed password locks again by itself")
        XCTAssertFalse(ring.adoptGroupPasswordPolicy(chatId: group, policy: GroupPasswordPolicy(payload: .off, at: 3)))
        XCTAssertFalse(ring.needsGroupPassword(group))
        XCTAssertTrue(ring.adoptGroupPasswordPolicy(chatId: group, policy: GroupPasswordPolicy(payload: .on(second), at: 4)),
                      "off → on turns it on again")
        XCTAssertTrue(ring.needsGroupPassword(group), "turning it off forgot the unlock")
    }

    func testPolicyOnForcesLocalCiphertextLockedOrNot() {
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { 0 }, epochDays: 1, epochTolerance: 1)
        ring.setChatEncryption(chatId: group, enabled: true)
        ring.setLocalCiphertext(false) // the user's 3.19 switch (on by default) off, so only the gate forces it
        XCTAssertFalse(ring.keepsCiphertextLocally(group))
        ring.adoptGroupPasswordPolicy(chatId: group, policy: GroupPasswordPolicy(payload: .on(params()), at: 1))
        XCTAssertTrue(ring.keepsCiphertextLocally(group))
        ring.unlockGroupPasswordPolicy(chatId: group, params: params())
        XCTAssertTrue(ring.keepsCiphertextLocally(group), "3.38.2: forced while the policy is on, unlocked or not")
        ring.adoptGroupPasswordPolicy(chatId: group, policy: GroupPasswordPolicy(payload: .off, at: 2))
        XCTAssertFalse(ring.keepsCiphertextLocally(group), "policy off: back to the user's own 3.19 switch")
        ring.setLocalCiphertext(true)
        XCTAssertTrue(ring.keepsCiphertextLocally(group), "the user's own 3.19 switch still applies")
    }
}
