import XCTest
@testable import SecutgCore

final class RekeyTests: XCTestCase {
    let v = Vectors.load("rekey")
    var adminPk: [UInt8] { Vectors.b64(v["admin_ed25519_pk_b64"] as! String) }
    var oldMaster: [UInt8] { Vectors.hex(v["old_master_hex"] as! String) }
    var newMaster: [UInt8] { Vectors.hex(v["new_master_hex"] as! String) }
    var member: Rekey.SealingIdentity { Rekey.SealingIdentity(x25519Pk: Vectors.hex(v["member_x25519_pk_hex"] as! String), x25519Sk: Vectors.hex(v["member_x25519_sk_hex"] as! String)) }
    var newcomer: Rekey.SealingIdentity { Rekey.SealingIdentity(x25519Pk: Vectors.hex(v["newcomer_x25519_pk_hex"] as! String), x25519Sk: Vectors.hex(v["newcomer_x25519_sk_hex"] as! String)) }

    func testWebVectorsVerifyAndOpen() throws {
        let rotate = Rekey.parseR1(v["rotate"] as! String)!
        XCTAssertEqual(rotate.type, .rotate)
        XCTAssertTrue(Rekey.verify(signedText: rotate.signedText, signature: rotate.signature, ed25519Pk: adminPk))
        XCTAssertEqual(try Rekey.openR1(rotate, candidateMasters: [oldMaster], identity: nil, ownUserId: nil).get(), newMaster)
        XCTAssertEqual(Rekey.openR1(rotate, candidateMasters: [newMaster], identity: nil, ownUserId: nil), .failure(.noOldKey))

        let reset = Rekey.parseR1(v["reset"] as! String)!
        XCTAssertTrue(Rekey.verify(signedText: reset.signedText, signature: reset.signature, ed25519Pk: adminPk))
        XCTAssertEqual(try Rekey.openR1(reset, candidateMasters: [], identity: member, ownUserId: "200").get(), newMaster)
        XCTAssertEqual(Rekey.openR1(reset, candidateMasters: [], identity: newcomer, ownUserId: "300"), .failure(.notAddressed))
        XCTAssertEqual(Rekey.openR1(reset, candidateMasters: [], identity: nil, ownUserId: "200"), .failure(.noIdentity))

        let welcome = Rekey.parseR1(v["welcome"] as! String)!
        XCTAssertTrue(Rekey.verify(signedText: welcome.signedText, signature: welcome.signature, ed25519Pk: adminPk))
        XCTAssertEqual(try Rekey.openR1(welcome, candidateMasters: [], identity: newcomer, ownUserId: "300").get(), newMaster)
        XCTAssertEqual(Rekey.openR1(welcome, candidateMasters: [], identity: member, ownUserId: "200"), .failure(.notAddressed))

        let p1 = Rekey.parseP1(v["p1"] as! String)!
        XCTAssertEqual(p1.userId, "200")
        XCTAssertTrue(Rekey.verifyP1(p1, senderId: "200"))
        XCTAssertFalse(Rekey.verifyP1(p1, senderId: "201"))
        XCTAssertFalse(Rekey.verifyP1(p1, senderId: nil))
        XCTAssertTrue(Rekey.isControlMessage(v["p1"] as! String))
        XCTAssertFalse(Rekey.isControlMessage("R1:rotate:x"))
    }

    /// Regression: `isControlMessage` is `prepareOutgoing`'s passthrough gate as well as `localCopy` /
    /// `applySentControlDate`'s. A `P2:` wire missing from it meant an outgoing v2 pairing message in a
    /// chat with a live v1 `E1` session got needlessly re-encrypted, and the sender's own local echo of
    /// any v2 control message rendered as raw wire text. Also asserts P2 is exempt from the v1 family's
    /// `maxChars` cap, since v1's fixed-shape wire formats and v2's envelope have no reason to share one.
    func testControlMessageRecognisesEveryV2PairingType() {
        let ed = V2Suite.generateEd25519()
        let enc = V2Suite.generateX25519()
        let identity = V2Identity(userId: "100", publicKey: ed.publicKey, secretKey: ed.secretKey, encapsulationPk: enc.publicKey, encapsulationSk: enc.secretKey)
        let processor = V2Processor.PairingProcessor(identity: identity, now: { 1_000_000 })
        let invite = processor.startPairing("200", "200")!
        XCTAssertTrue(Rekey.isControlMessage(invite.wire))
        XCTAssertTrue(Rekey.isControlMessage(processor.cancelPairing(txnId: invite.txnId, reason: "x")!))
        // Structural, not a prefix (review finding, 2026-09-27): typed text that only starts like a P2 wire
        // is text and must still be encrypted.
        XCTAssertFalse(Rekey.isControlMessage("P2:INVITE:whatever-the-envelope-actually-contains"))
        XCTAssertFalse(Rekey.isControlMessage("P2: see you"))
        XCTAssertFalse(Rekey.isControlMessage("not a control message at all"))
    }

    func testBuiltMessagesOpenOnTheMemberSide() throws {
        let admin = try Rekey.generateSigningKeys()
        let identity = try Rekey.generateIdentity()
        let sealing = Rekey.SealingIdentity(x25519Pk: identity.x25519Pk, x25519Sk: identity.x25519Sk)
        let fresh = KeyDerivation.generateMasterKey()

        let rotate = try Rekey.buildRotate(newMaster: fresh, oldMaster: oldMaster, adminSk: admin.sk, nowMs: vectorNowMs, epochDays: 1)
        XCTAssertEqual(rotate.newKeyId, KeyDerivation.buildKeyId(masterId: try KeyDerivation.computeMasterId(fresh), label: "20260911"))
        let parsedRotate = Rekey.parseR1(rotate.wire)!
        XCTAssertTrue(Rekey.verify(signedText: parsedRotate.signedText, signature: parsedRotate.signature, ed25519Pk: admin.pk))
        XCTAssertFalse(Rekey.verify(signedText: parsedRotate.signedText, signature: parsedRotate.signature, ed25519Pk: adminPk))
        XCTAssertEqual(try Rekey.openR1(parsedRotate, candidateMasters: [newMaster, oldMaster], identity: nil, ownUserId: nil).get(), fresh)

        let reset = try Rekey.buildReset(newMaster: fresh, recipients: ["42": identity.x25519Pk, "7": newcomer.x25519Pk], adminSk: admin.sk, nowMs: vectorNowMs, epochDays: 1)
        XCTAssertEqual(try Rekey.openR1(Rekey.parseR1(reset.wire)!, candidateMasters: [], identity: sealing, ownUserId: "42").get(), fresh)
        XCTAssertEqual(try Rekey.openR1(Rekey.parseR1(reset.wire)!, candidateMasters: [], identity: newcomer, ownUserId: "7").get(), fresh)
        XCTAssertThrowsError(try Rekey.buildReset(newMaster: fresh, recipients: [:], adminSk: admin.sk, nowMs: vectorNowMs, epochDays: 1))

        let welcome = try Rekey.buildWelcome(currentMaster: fresh, newcomerX25519Pk: identity.x25519Pk, adminSk: admin.sk, nowMs: vectorNowMs, epochDays: 1)
        XCTAssertEqual(try Rekey.openR1(Rekey.parseR1(welcome.wire)!, candidateMasters: [], identity: sealing, ownUserId: nil).get(), fresh)

        let p1 = try Rekey.buildP1(userId: "42", x25519Pk: identity.x25519Pk, ed25519Pk: identity.ed25519Pk, ed25519Sk: identity.ed25519Sk)
        XCTAssertTrue(Rekey.verifyP1(Rekey.parseP1(p1)!, senderId: "42"))
        XCTAssertTrue(rotate.wire.utf16.count < 4096 && reset.wire.utf16.count < 4096)
    }
}
