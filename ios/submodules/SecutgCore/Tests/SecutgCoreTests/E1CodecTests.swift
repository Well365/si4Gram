import XCTest
@testable import SecutgCore

final class E1CodecTests: XCTestCase {
    let v = Vectors.load("e1")
    var keyId: String { v["key_id"] as! String }
    var sessionKey: [UInt8] { Vectors.hex(v["session_key_hex"] as! String) }

    func lookup(_ id: String) -> [UInt8]? { return id == keyId ? sessionKey : nil }

    func testDecryptsEveryWebVector() {
        for c in v["cases"] as! [[String: Any]] {
            let r = E1Codec.decrypt(wire: c["wire"] as! String, lookup: lookup)
            XCTAssertTrue(r.ok, "\(c["text"]!) → \(String(describing: r.reason))")
            XCTAssertEqual(r.text, c["text"] as? String)
            XCTAssertEqual(r.keyId, keyId)
            if let entities = c["entities"] as? [[String: Any]] {
                XCTAssertEqual(r.entities?.count, entities.count)
                XCTAssertEqual(r.entities?[0].type, "MessageEntityBold")
                XCTAssertEqual(r.entities?[1].extras["url"]?.stringValue, "https://secutg.test")
                XCTAssertEqual(r.entities?[1].offset, 5)
            } else {
                XCTAssertNil(r.entities)
            }
        }
    }

    func testRoundTripWithEntitiesAndUnicode() throws {
        let entities = [E1Entity(type: "MessageEntityBold", offset: 0, length: 4), E1Entity(type: "MessageEntityTextUrl", offset: 5, length: 4, extras: ["url": .string("https://x.y")])]
        let wire = try E1Codec.encrypt(text: "bold link 😀 中文", entities: entities, keyId: keyId, sessionKey: sessionKey)
        XCTAssertTrue(E1Format.isEncrypted(wire))
        XCTAssertTrue(wire.hasPrefix("E1:\(keyId):"))
        let r = E1Codec.decrypt(wire: wire, lookup: lookup)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.text, "bold link 😀 中文")
        XCTAssertEqual(r.entities, entities)
    }

    func testTamperedAndUnknownAndMalformed() {
        let t = v["tampered"] as! [String: String]
        XCTAssertTrue(E1Codec.decrypt(wire: t["wire"]!, lookup: lookup).ok)
        XCTAssertEqual(E1Codec.decrypt(wire: t["flipped"]!, lookup: lookup).reason, .authFailed)
        XCTAssertEqual(E1Codec.decrypt(wire: t["wire"]!, lookup: { _ in nil }).reason, .unknownKey)
        XCTAssertEqual(E1Codec.decrypt(wire: t["wire"]!, lookup: { _ in [1, 2, 3] }).reason, .invalidKey)
        XCTAssertEqual(E1Codec.decrypt(wire: "hello", lookup: lookup).reason, .notEncrypted)
        XCTAssertEqual(E1Codec.decrypt(wire: "E1:abc", lookup: lookup).reason, .malformed)
        XCTAssertEqual(E1Codec.decrypt(wire: "E1:\(keyId):AAAA:BBBB", lookup: lookup).reason, .malformed)
        XCTAssertFalse(E1Format.isEncrypted(String(repeating: "E1:a:b:", count: 700) + "c"))
    }

    func testRejectsBadKeysAndTooLongPlaintext() {
        XCTAssertThrowsError(try E1Codec.encrypt(text: "x", entities: nil, keyId: "bad key", sessionKey: sessionKey))
        XCTAssertThrowsError(try E1Codec.encrypt(text: "x", entities: nil, keyId: keyId, sessionKey: [0, 1]))
        XCTAssertThrowsError(try E1Codec.encrypt(text: String(repeating: "a", count: 3500), entities: nil, keyId: keyId, sessionKey: sessionKey)) { error in
            guard case SecutgCryptoError.plaintextTooLong = error else { return XCTFail("\(error)") }
        }
    }

    func testEntitiesAreSanitised() throws {
        // offset/length beyond the text → bad_plaintext; prototype keys dropped
        let bad = try E1Codec.encrypt(text: "ab", entities: [E1Entity(type: "MessageEntityBold", offset: 1, length: 5)], keyId: keyId, sessionKey: sessionKey)
        XCTAssertEqual(E1Codec.decrypt(wire: bad, lookup: lookup).reason, .badPlaintext)
        let dirty = try E1Codec.encrypt(text: "ab", entities: [E1Entity(type: "MessageEntityBold", offset: 0, length: 1, extras: ["__proto__": .string("x"), "language": .string("go")])], keyId: keyId, sessionKey: sessionKey)
        let r = E1Codec.decrypt(wire: dirty, lookup: lookup)
        XCTAssertEqual(r.entities?[0].extras, ["language": .string("go")])
    }

    func testBase64UrlIsCanonical() {
        XCTAssertEqual(Base64Url.encode([0xfb, 0xff]), "-_8")
        XCTAssertEqual(Base64Url.decode("-_8"), [0xfb, 0xff])
        XCTAssertNil(Base64Url.decode("-_9"))   // non-zero trailing bits
        XCTAssertNil(Base64Url.decode("A"))
        XCTAssertNil(Base64Url.decode("AB=="))
        XCTAssertEqual(Base64Url.decode(""), [])
    }
}
