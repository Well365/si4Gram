import XCTest
@testable import SecutgCore

/// Ported from Android's `SuiteTest.java` / the Web reference's `suite.test.ts` — round-trips and
/// cross-checks for every primitive `V2Suite` wraps.
final class V2SuiteTests: XCTestCase {

    func testX25519RoundTripsBothSidesDeriveTheSameSharedSecret() {
        let a = V2Suite.generateX25519()
        let b = V2Suite.generateX25519()
        let sharedA = V2Suite.x25519(secretKey: a.secretKey, peerPublicKey: b.publicKey)
        let sharedB = V2Suite.x25519(secretKey: b.secretKey, peerPublicKey: a.publicKey)
        XCTAssertNotNil(sharedA)
        XCTAssertEqual(sharedA, sharedB)
    }

    func testX25519RefusesWrongLengthKeys() {
        XCTAssertNil(V2Suite.x25519(secretKey: [1, 2, 3], peerPublicKey: [UInt8](repeating: 0, count: 32)))
    }

    func testSha256IsDeterministicAndSizedCorrectly() {
        let digest = V2Suite.sha256(V2Suite.utf8("hello"))
        XCTAssertEqual(digest.count, V2Suite.digestBytes)
        XCTAssertEqual(digest, V2Suite.sha256(V2Suite.utf8("hello")))
        XCTAssertNotEqual(digest, V2Suite.sha256(V2Suite.utf8("world")))
    }

    func testSignVerifyRoundTripsAndRejectsATamperedMessage() {
        let identity = V2Suite.generateEd25519()
        let message = V2Suite.utf8("sign me")
        let sig = V2Suite.sign(secretKey: identity.secretKey, message: message)
        XCTAssertTrue(V2Suite.verify(publicKey: identity.publicKey, message: message, signature: sig))
        XCTAssertFalse(V2Suite.verify(publicKey: identity.publicKey, message: V2Suite.utf8("tampered"), signature: sig))
    }

    func testVerifyRefusesWrongLengthKeyOrSignatureRatherThanCrashing() {
        let message = V2Suite.utf8("x")
        XCTAssertFalse(V2Suite.verify(publicKey: [1, 2, 3], message: message, signature: [UInt8](repeating: 0, count: 64)))
        XCTAssertFalse(V2Suite.verify(publicKey: [UInt8](repeating: 0, count: 32), message: message, signature: [1, 2, 3]))
    }

    func testHkdfExtractThenExpandIsDeterministicGivenTheSameInputs() {
        let salt = [UInt8](repeating: 9, count: 32)
        let ikm = [UInt8](repeating: 7, count: 32)
        let prk1 = V2Suite.hkdfExtract(salt32: salt, ikm: ikm)
        let prk2 = V2Suite.hkdfExtract(salt32: salt, ikm: ikm)
        XCTAssertEqual(prk1, prk2)
        let info = V2Suite.utf8("secuTG/v2/master")
        let okm1 = V2Suite.hkdfExpand(prk: prk1, info: info, length: 32)
        let okm2 = V2Suite.hkdfExpand(prk: prk2, info: info, length: 32)
        XCTAssertEqual(okm1, okm2)
        XCTAssertEqual(okm1.count, 32)
    }

    func testHkdfExpandWithDifferentInfoProducesDifferentOutput() {
        let prk = V2Suite.hkdfExtract(salt32: [UInt8](repeating: 1, count: 32), ikm: [UInt8](repeating: 2, count: 32))
        let a = V2Suite.hkdfExpand(prk: prk, info: V2Suite.utf8("A"), length: 32)
        let b = V2Suite.hkdfExpand(prk: prk, info: V2Suite.utf8("B"), length: 32)
        XCTAssertNotEqual(a, b)
    }

    func testHmacIsDeterministicForAFixed32ByteKey() {
        let key = [UInt8](repeating: 5, count: 32)
        let a = V2Suite.hmac(key32: key, data: V2Suite.utf8("data"))
        let b = V2Suite.hmac(key32: key, data: V2Suite.utf8("data"))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, V2Suite.hmacBytes)
    }

    func testConstantTimeEqualMatchesOrdinaryEqualityAndRejectsDifferentLengths() {
        XCTAssertTrue(V2Suite.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(V2Suite.constantTimeEqual([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(V2Suite.constantTimeEqual([1, 2, 3], [1, 2]))
    }

    func testAeadRoundTripsAndFailsClosedOnATamperedCiphertextOrWrongKey() {
        let key = V2Suite.randomBytes(V2Suite.xchacha20KeyBytes)
        let nonce = V2Suite.randomBytes(V2Suite.xchacha20NonceBytes)
        let plaintext = V2Suite.utf8("secret message")
        let aad = V2Suite.utf8("associated data")
        let ciphertext = V2Suite.aeadEncrypt(key: key, nonce: nonce, plaintext: plaintext, aad: aad)
        XCTAssertEqual(V2Suite.aeadDecrypt(key: key, nonce: nonce, ciphertext: ciphertext, aad: aad), plaintext)

        var tampered = ciphertext
        tampered[0] ^= 0xff
        XCTAssertNil(V2Suite.aeadDecrypt(key: key, nonce: nonce, ciphertext: tampered, aad: aad))

        let wrongKey = V2Suite.randomBytes(V2Suite.xchacha20KeyBytes)
        XCTAssertNil(V2Suite.aeadDecrypt(key: wrongKey, nonce: nonce, ciphertext: ciphertext, aad: aad))
    }

    func testAeadWithNoAadRoundTrips() {
        let key = V2Suite.randomBytes(V2Suite.xchacha20KeyBytes)
        let nonce = V2Suite.randomBytes(V2Suite.xchacha20NonceBytes)
        let plaintext = V2Suite.utf8("no aad here")
        let ciphertext = V2Suite.aeadEncrypt(key: key, nonce: nonce, plaintext: plaintext, aad: nil)
        XCTAssertEqual(V2Suite.aeadDecrypt(key: key, nonce: nonce, ciphertext: ciphertext, aad: nil), plaintext)
    }

    func testSealForOpenSealedRoundTripsAndFailsForTheWrongRecipient() {
        let recipient = V2Suite.generateX25519()
        let stranger = V2Suite.generateX25519()
        let message = V2Suite.utf8("sealed payload")
        let sealed = V2Suite.sealFor(recipientX25519Pk: recipient.publicKey, bytes: message)
        XCTAssertEqual(V2Suite.openSealed(recipientPk: recipient.publicKey, recipientSk: recipient.secretKey, sealed: sealed), message)
        XCTAssertNil(V2Suite.openSealed(recipientPk: stranger.publicKey, recipientSk: stranger.secretKey, sealed: sealed))
    }

    func testUtf8RoundTripsAndFromUtf8RejectsInvalidBytes() {
        let text = "hello 世界"
        XCTAssertEqual(V2Suite.fromUtf8(V2Suite.utf8(text)), text)
        XCTAssertNil(V2Suite.fromUtf8([0xff, 0xfe]))
    }

    func testConcatBytesPreservesOrderAndLength() {
        let result = V2Suite.concatBytes([1, 2], [3], [4, 5])
        XCTAssertEqual(result, [1, 2, 3, 4, 5])
    }

    func testRandomBytesProducesTheRequestedLengthAndIsNotTriviallyConstant() {
        let a = V2Suite.randomBytes(32)
        let b = V2Suite.randomBytes(32)
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
    }
}
