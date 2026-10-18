import XCTest
@testable import SecutgCore

/// PLAN.md 3.7: the derived master and safety code must match Web A byte for byte.
final class PairingTests: XCTestCase {
    let v = Vectors.load("pairing")

    func testDerivesTheWebAMasterFromEitherSide() throws {
        let aSk = Vectors.hex(v["a_x25519_sk_hex"] as! String), aPk = Vectors.hex(v["a_x25519_pk_hex"] as! String)
        let bSk = Vectors.hex(v["b_x25519_sk_hex"] as! String), bPk = Vectors.hex(v["b_x25519_pk_hex"] as! String)
        let expected = Vectors.hex(v["master_hex"] as! String)
        XCTAssertEqual(try Pairing.deriveMaster(ownX25519Sk: aSk, ownX25519Pk: aPk, peerX25519Pk: bPk), expected)
        XCTAssertEqual(try Pairing.deriveMaster(ownX25519Sk: bSk, ownX25519Pk: bPk, peerX25519Pk: aPk), expected)
        XCTAssertEqual(try KeyDerivation.computeMasterId(expected), v["master_id"] as! String)
    }

    func testSafetyCodeMatchesWebAAndIsSymmetric() throws {
        let aPk = Vectors.hex(v["a_x25519_pk_hex"] as! String), bPk = Vectors.hex(v["b_x25519_pk_hex"] as! String)
        XCTAssertEqual(try Pairing.safetyCode(aPk, bPk), v["safety_code"] as! String)
        XCTAssertEqual(try Pairing.safetyCode(bPk, aPk), v["safety_code"] as! String)
        XCTAssertNotNil(try Pairing.safetyCode(aPk, bPk).range(of: "^\\d{4} \\d{4} \\d{4}$", options: .regularExpression))
    }

    func testDifferentPeerDifferentMasterAndMalformedKeysThrow() throws {
        let a = try Rekey.generateIdentity(), b = try Rekey.generateIdentity(), c = try Rekey.generateIdentity()
        XCTAssertNotEqual(try Pairing.deriveMaster(ownX25519Sk: a.x25519Sk, ownX25519Pk: a.x25519Pk, peerX25519Pk: b.x25519Pk),
                          try Pairing.deriveMaster(ownX25519Sk: a.x25519Sk, ownX25519Pk: a.x25519Pk, peerX25519Pk: c.x25519Pk))
        XCTAssertThrowsError(try Pairing.deriveMaster(ownX25519Sk: a.x25519Sk, ownX25519Pk: a.x25519Pk, peerX25519Pk: [UInt8](repeating: 0, count: 31)))
        XCTAssertThrowsError(try Pairing.safetyCode(a.x25519Pk, []))
    }
}

extension PairingTests {
    func testRatchetStepMatchesWebA() throws {
        let base = Vectors.hex(v["ratchet_base_hex"] as! String)
        let next = try KeyDerivation.deriveRatchetNext(base)
        XCTAssertEqual(next, Vectors.hex(v["ratchet_next_hex"] as! String))
        XCTAssertEqual(try KeyDerivation.computeMasterId(next), v["ratchet_next_master_id"] as! String)
    }
}
