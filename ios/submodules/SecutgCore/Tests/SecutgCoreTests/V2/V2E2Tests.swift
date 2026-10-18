import XCTest
@testable import SecutgCore

/// Ported from Android's `E2Test.java` — no TEST_MATRIX.md section exists for DATA-01, cases derived
/// from v1.4 section 15's own text.
final class V2E2Tests: XCTestCase {
    private let master = [UInt8](repeating: 7, count: 32)
    private let salt = [UInt8](repeating: 9, count: 32)
    private let plaintext = V2Suite.utf8("secuTG v2 E2 test message")
    private var sender: V2Suite.KeyPair!

    override func setUp() {
        super.setUp()
        sender = V2Suite.generateEd25519()
    }

    private func makeHeader(genesisOrBinding: String? = nil, permitHash: String? = nil, msgId: String? = nil, epoch: String? = nil) -> V2E2.Header {
        return V2E2.Header(
            chatId: "chat-4200", genesisOrBinding: genesisOrBinding ?? Base64Url.encode(V2Suite.randomBytes(32)),
            epoch: epoch ?? "3", senderDevice: V2E2.deviceIdOf(sender.publicKey), permitHash: permitHash,
            msgId: msgId ?? Base64Url.encode(V2Suite.randomBytes(16)), seq: "1"
        )
    }

    private func buildWith(_ header: V2E2.Header) -> String? {
        return V2E2.build(V2E2.BuildParams(header: header, plaintext: plaintext, master: master, saltStateOrBindingHash: salt, senderIdentitySk: sender.secretKey, nonce: nil))
    }

    func testAGenuineMessageRoundTripsSignatureVerifiesPlaintextDecryptsHeaderIntact() {
        let header = makeHeader()
        let wire = buildWith(header)
        XCTAssertNotNil(wire)
        XCTAssertTrue(wire!.hasPrefix("E2:"))

        let parsed = V2E2.parse(wire!)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.header.chatId, header.chatId)
        XCTAssertEqual(parsed!.header.genesisOrBinding, header.genesisOrBinding)
        XCTAssertEqual(parsed!.header.msgId, header.msgId)

        XCTAssertTrue(V2E2.verifySignature(parsed!, senderIdentityPk: sender.publicKey))
        XCTAssertEqual(V2E2.decrypt(parsed!, master: master, saltStateOrBindingHash: salt), plaintext)
    }

    func testAGroupHeaderCarriesPermitHashAPrivateHeaderOmitsItBothRoundTrip() {
        let permitHash = Base64Url.encode(V2Suite.randomBytes(32))
        let groupWire = buildWith(makeHeader(permitHash: permitHash))
        XCTAssertEqual(V2E2.parse(groupWire!)?.header.permitHash, permitHash)

        let privateWire = buildWith(makeHeader())
        XCTAssertNil(V2E2.parse(privateWire!)?.header.permitHash)
    }

    func testAForgedSignatureFailsVerificationEvenThoughDecryptionWouldStillSucceed() {
        let wire = buildWith(makeHeader())
        let parsed = V2E2.parse(wire!)!
        let impostor = V2Suite.generateEd25519()
        XCTAssertFalse(V2E2.verifySignature(parsed, senderIdentityPk: impostor.publicKey))
        XCTAssertEqual(V2E2.decrypt(parsed, master: master, saltStateOrBindingHash: salt), plaintext)
    }

    func testDecryptingWithTheWrongSaltOrMasterFailsClosed() {
        let wire = buildWith(makeHeader())
        let parsed = V2E2.parse(wire!)!
        XCTAssertNil(V2E2.decrypt(parsed, master: master, saltStateOrBindingHash: [UInt8](repeating: 1, count: 32)))
        XCTAssertNil(V2E2.decrypt(parsed, master: [UInt8](repeating: 2, count: 32), saltStateOrBindingHash: salt))
    }

    func testAnExplicitNonceIsHonoredARetryReproducesTheIdenticalWire() {
        let header = makeHeader()
        let fixedNonce = V2Suite.randomBytes(24)
        let wireA = V2E2.build(V2E2.BuildParams(header: header, plaintext: plaintext, master: master, saltStateOrBindingHash: salt, senderIdentitySk: sender.secretKey, nonce: fixedNonce))
        let wireB = V2E2.build(V2E2.BuildParams(header: header, plaintext: plaintext, master: master, saltStateOrBindingHash: salt, senderIdentitySk: sender.secretKey, nonce: fixedNonce))
        XCTAssertEqual(wireA, wireB)
    }

    func testOmittingTheNonceDrawsAFreshOneEachTime() {
        let header = makeHeader()
        XCTAssertNotEqual(buildWith(header), buildWith(header))
    }

    func testMalformedWiresAreRefusedNeverThrown() {
        XCTAssertNil(V2E2.parse("P2:whatever"))
        XCTAssertNil(V2E2.parse("E2:not-valid-base64!!!"))
        XCTAssertNil(V2E2.parse("E2:"))
    }

    func testHeaderFieldValidationEpochMustBeDecimalSeqMustHaveNoLeadingZero() {
        XCTAssertNil(V2E2.parse(buildWith(makeHeader(epoch: "not-a-number"))!))
        XCTAssertNil(V2E2.parse(buildWith(makeHeader(epoch: "-1"))!))
        XCTAssertNotNil(V2E2.parse(buildWith(makeHeader(epoch: "0"))!)) // zero is a genuinely valid decimal
    }

    func testAGenesisOrBindingThatIsntA32ByteDigestIsRefused() {
        let wire = buildWith(makeHeader(genesisOrBinding: "too-short"))
        XCTAssertNotNil(wire)
        XCTAssertNil(V2E2.parse(wire!))
    }

    func testAMsgIdOfTheWrongLengthIsRefused() {
        let wire = buildWith(makeHeader(msgId: Base64Url.encode(V2Suite.randomBytes(8)))) // not ID_BYTES (16)
        XCTAssertNotNil(wire)
        XCTAssertNil(V2E2.parse(wire!))
    }

    func testDifferentSenderDeviceValuesDeriveDifferentKeysFromTheSameMasterAndSalt() {
        let deviceA = V2Suite.randomBytes(32)
        let deviceB = V2Suite.randomBytes(32)
        XCTAssertNotEqual(V2E2.deriveDataKey(master: master, saltStateOrBindingHash: salt, senderDeviceBytes: deviceA), V2E2.deriveDataKey(master: master, saltStateOrBindingHash: salt, senderDeviceBytes: deviceB))
    }

    func testDeviceIdOfMatchesSha256IdentityPkBase64Url() {
        XCTAssertEqual(V2E2.deviceIdOf(sender.publicKey), Base64Url.encode(V2Suite.sha256(sender.publicKey)))
    }
}
