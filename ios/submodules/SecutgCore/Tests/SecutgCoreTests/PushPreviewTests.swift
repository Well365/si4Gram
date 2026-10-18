import XCTest
@testable import SecutgCore

/// PLAN.md 3.42 rule 5: the placeholder choice — ordinary text / encrypted content / control line — over real wires
/// of every family the clients send, and the group body shape (`Sender: text`) the server delivers.
final class PushPreviewTests: XCTestCase {
    private let encrypted = "🔒 加密消息"
    private let control = "🔐 加密聊天的系统消息"

    private func mask(_ body: String) -> String {
        return PushPreview.mask(body: body, encrypted: encrypted, control: control)
    }

    private func makeRuntime(userId: String) -> V2Runtime {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        let stored = KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
        let identity = V2IdentityBridge.identity(userId: userId, from: stored)!
        return V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: V2MemoryStorage()))
    }

    private func e1Wire() throws -> String {
        let v = Vectors.load("e1")
        return try E1Codec.encrypt(text: "nine, the usual place", entities: nil, keyId: v["key_id"] as! String, sessionKey: Vectors.hex(v["session_key_hex"] as! String))
    }

    private func e2Wire() throws -> String {
        let sender = V2Suite.generateEd25519()
        let header = V2E2.Header(
            chatId: "4200", genesisOrBinding: Base64Url.encode(V2Suite.randomBytes(32)), epoch: "3",
            senderDevice: V2E2.deviceIdOf(sender.publicKey), permitHash: nil,
            msgId: Base64Url.encode(V2Suite.randomBytes(16)), seq: "1")
        return try XCTUnwrap(V2E2.build(V2E2.BuildParams(
            header: header, plaintext: V2Suite.utf8("nine, the usual place"), master: [UInt8](repeating: 7, count: 32),
            saltStateOrBindingHash: [UInt8](repeating: 9, count: 32), senderIdentitySk: sender.secretKey, nonce: nil)))
    }

    // MARK: the three kinds

    func testOrdinaryTextIsPlain() {
        XCTAssertEqual(PushPreview.classify("nine, the usual place"), .plain)
        XCTAssertEqual(PushPreview.classify(""), .plain)
        XCTAssertEqual(PushPreview.classify("Alice: see you at nine"), .plain)
        XCTAssertEqual(mask("see you at nine"), "see you at nine")
    }

    func testE1ContentIsEncrypted() throws {
        let wire = try e1Wire()
        XCTAssertEqual(PushPreview.classify(wire), .encryptedContent)
        XCTAssertEqual(mask(wire), encrypted)
    }

    func testE2ContentIsEncrypted() throws {
        let wire = try e2Wire()
        XCTAssertEqual(PushPreview.classify(wire), .encryptedContent)
        XCTAssertEqual(mask(wire), encrypted)
    }

    func testG2GroupKeyBroadcastIsEncrypted() throws {
        let signing = try Rekey.generateSigningKeys()
        let payload = KeyPayload.build(masterKey: KeyDerivation.generateMasterKey(), adminPk: signing.pk, mode: .auto)
        let wire = try XCTUnwrap(G2.build(chatId: "-1001234567890", at: 1_789_300_020, keyPayload: payload, publisherId: "7001"))
        XCTAssertEqual(PushPreview.classify(wire), .encryptedContent)
    }

    func testP2InviteIsAControlLine() {
        let runtime = makeRuntime(userId: "100")
        let invite = runtime.pairing.startPairing("200", "200")!
        XCTAssertEqual(PushPreview.classify(invite.wire), .controlLine)
        XCTAssertEqual(mask(invite.wire), control)
    }

    func testGP1AndP1AndG1AreControlLines() throws {
        let gp1 = try XCTUnwrap(GP1.build(chatId: "-1001234567890", at: 1_789_300_020, payload: .off, publisherId: "7001"))
        XCTAssertEqual(PushPreview.classify(gp1), .controlLine)
        let identity = try Rekey.generateIdentity()
        let p1 = try Rekey.buildP1(userId: "7001", x25519Pk: identity.x25519Pk, ed25519Pk: identity.ed25519Pk, ed25519Sk: identity.ed25519Sk)
        XCTAssertEqual(PushPreview.classify(p1), .controlLine)
        XCTAssertEqual(PushPreview.classify(GroupInvite.prefix + "whatever the card carries"), .controlLine)
    }

    // MARK: the truncation guard

    func testACutOffEnvelopeIsStillMasked() throws {
        let e1 = try e1Wire()
        XCTAssertEqual(PushPreview.classify(String(e1.prefix(40)) + "…"), .encryptedContent)
        let e2 = try e2Wire()
        XCTAssertEqual(PushPreview.classify(String(e2.prefix(60))), .encryptedContent)
        let runtime = makeRuntime(userId: "100")
        let invite = runtime.pairing.startPairing("200", "200")!
        XCTAssertEqual(PushPreview.classify(String(invite.wire.prefix(50))), .controlLine)
    }

    func testABarePrefixWithNothingBehindItIsNotAWire() {
        XCTAssertEqual(PushPreview.classify("E2:"), .plain)
        XCTAssertEqual(PushPreview.classify("P2:"), .plain)
    }

    // MARK: the group body shape

    func testASenderPrefixIsKeptAndOnlyTheWireIsReplaced() throws {
        let wire = try e2Wire()
        XCTAssertEqual(mask("Alice: " + wire), "Alice: " + encrypted)
        XCTAssertEqual(mask("Dr. Who: Time: Lord: " + wire), "Dr. Who: Time: Lord: " + encrypted)
        let runtime = makeRuntime(userId: "100")
        let invite = runtime.pairing.startPairing("200", "200")!
        XCTAssertEqual(mask("Bob: " + invite.wire), "Bob: " + control)
    }

    func testAPlainGroupBodyIsUntouched() {
        XCTAssertEqual(mask("Alice: see you at nine"), "Alice: see you at nine")
        XCTAssertEqual(mask("Alice: E2: is what I typed"), "Alice: " + encrypted,
                       "typed text that merely starts like a wire prefix is masked — the guard errs towards hiding")
    }
}
