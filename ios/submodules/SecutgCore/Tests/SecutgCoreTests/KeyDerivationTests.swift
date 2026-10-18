import XCTest
@testable import SecutgCore

final class KeyDerivationTests: XCTestCase {
    let v = Vectors.load("keyring")

    func testMasterIdAndSessionKeyMatchWeb() throws {
        let master = Vectors.hex(v["master_hex"] as! String)
        XCTAssertEqual(try KeyDerivation.computeMasterId(master), v["master_id"] as? String)
        XCTAssertEqual(KeyDerivation.toEpochLabel(nowMs: v["now_ms"] as! Int64, epochDays: v["epoch_days"] as! Int), v["label"] as? String)
        XCTAssertEqual(Hex.encode(try KeyDerivation.deriveSessionKey(masterKey: master, label: v["label"] as! String)[...]), v["session_key_hex"] as? String)
        for other in v["other_labels"] as! [[String: String]] {
            XCTAssertEqual(Hex.encode(try KeyDerivation.deriveSessionKey(masterKey: master, label: other["label"]!)[...]), other["session_key_hex"])
        }
        XCTAssertEqual(KeyDerivation.buildKeyId(masterId: v["master_id"] as! String, label: "20260911"), v["key_id"] as? String)
        XCTAssertEqual(KeyDerivation.parseKeyId(v["key_id"] as! String), KeyDerivation.KeyId(masterId: v["master_id"] as! String, label: "20260911"))
        XCTAssertNil(KeyDerivation.parseKeyId("nope"))
    }

    func testEpochLabelsAreUtcAndAligned() {
        XCTAssertEqual(KeyDerivation.toEpochLabel(nowMs: 1_789_171_170_000, epochDays: 1), "20260911") // 23:59:30Z
        XCTAssertEqual(KeyDerivation.toEpochLabel(nowMs: 1_789_171_230_000, epochDays: 1), "20260912") // 00:00:30Z next day
        XCTAssertEqual(KeyDerivation.toEpochLabel(nowMs: 0, epochDays: 1), "19700101")
        XCTAssertEqual(KeyDerivation.toEpochLabel(nowMs: -1, epochDays: 1), "19691231")
        // 7-day epochs align on the Unix day count, not on calendar weeks
        XCTAssertEqual(KeyDerivation.toEpochLabel(nowMs: 1_789_128_000_000, epochDays: 7), "20260910")
        XCTAssertEqual(KeyDerivation.parseEpochLabel("20260911"), 20_707)
        XCTAssertNil(KeyDerivation.parseEpochLabel("20260931"))
        XCTAssertNil(KeyDerivation.parseEpochLabel("2026091"))
        XCTAssertEqual(KeyDerivation.parseEpochLabel("20240229"), KeyDerivation.daysFromCivil(year: 2024, month: 2, day: 29))
        XCTAssertNil(KeyDerivation.parseEpochLabel("20230229"))
    }

    func testLabelTolerance() {
        let now = vectorNowMs
        XCTAssertTrue(KeyDerivation.isLabelAcceptable("20250101", nowMs: now, epochTolerance: 0))
        XCTAssertTrue(KeyDerivation.isLabelAcceptable("20260912", nowMs: now, epochTolerance: 1))
        XCTAssertFalse(KeyDerivation.isLabelAcceptable("20260913", nowMs: now, epochTolerance: 1))
        XCTAssertFalse(KeyDerivation.isLabelAcceptable("garbage!", nowMs: now, epochTolerance: 5))
    }

    func testKeyPayloadRoundTrip() {
        let master = Vectors.hex(v["master_hex"] as! String)
        let admin = [UInt8](repeating: 7, count: 32)
        let text = KeyPayload.build(masterKey: master, adminPk: admin)
        XCTAssertTrue(text.hasPrefix("secutg://key?"))
        XCTAssertEqual(KeyPayload.parse(" \(text)\n"), KeyPayload(masterKey: master, adminPk: admin, mode: .manual))
        XCTAssertEqual(KeyPayload.parse(KeyPayload.build(masterKey: master, adminPk: nil))?.adminPk, nil)
        XCTAssertNil(KeyPayload.parse("secutg://key?AAAA"))
        XCTAssertNil(KeyPayload.parse("https://x"))
    }
}
