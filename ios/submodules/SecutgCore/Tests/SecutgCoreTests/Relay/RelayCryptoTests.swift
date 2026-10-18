import XCTest
@testable import SecutgCore

final class RelayCryptoTests: XCTestCase {
    func testSealOpenRoundTrip() throws {
        let key = RelayCrypto.generateKey()
        let plaintext = Data("hello relay".utf8)
        let blob = try RelayCrypto.seal(plaintext, key: key)
        XCTAssertEqual(blob.count, RelayCrypto.nonceBytes + plaintext.count + 16)
        XCTAssertEqual(RelayCrypto.open(blob, key: key), plaintext)
    }

    func testOpenFailsWithWrongKey() throws {
        let key = RelayCrypto.generateKey()
        let other = RelayCrypto.generateKey()
        let blob = try RelayCrypto.seal(Data("secret".utf8), key: key)
        XCTAssertNil(RelayCrypto.open(blob, key: other))
    }

    func testOpenFailsWhenTampered() throws {
        let key = RelayCrypto.generateKey()
        var blob = try RelayCrypto.seal(Data("secret".utf8), key: key)
        blob[blob.count - 1] ^= 0xFF
        XCTAssertNil(RelayCrypto.open(blob, key: key))
    }

    func testOpenFailsWhenTruncated() throws {
        let key = RelayCrypto.generateKey()
        let blob = try RelayCrypto.seal(Data("secret".utf8), key: key)
        XCTAssertNil(RelayCrypto.open(blob.prefix(5), key: key))
    }

    func testSealRejectsWrongKeyLength() {
        XCTAssertThrowsError(try RelayCrypto.seal(Data("x".utf8), key: [UInt8](repeating: 0, count: 10)))
    }

    /// Fixed key + nonce determinism check: same inputs always produce the same ciphertext, which is what makes
    /// a future byte-identical cross-platform vector (once Web publishes `vectors-l1.json`) checkable at all.
    func testDeterministicWithFixedNonce() throws {
        let key = [UInt8](repeating: 0x11, count: 32)
        let nonce = [UInt8](repeating: 0x22, count: 24)
        let plaintext = Data("fixed vector check".utf8)
        let blobA = try RelayCrypto.seal(plaintext, key: key, nonce: nonce)
        let blobB = try RelayCrypto.seal(plaintext, key: key, nonce: nonce)
        XCTAssertEqual(blobA, blobB)
        XCTAssertEqual(RelayCrypto.open(blobA, key: key), plaintext)
    }

    func testRandomNoncesDiffer() throws {
        let key = RelayCrypto.generateKey()
        let a = try RelayCrypto.seal(Data("same".utf8), key: key)
        let b = try RelayCrypto.seal(Data("same".utf8), key: key)
        XCTAssertNotEqual(a, b)
    }
}
