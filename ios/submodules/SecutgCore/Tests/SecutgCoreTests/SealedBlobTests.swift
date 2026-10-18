import XCTest
@testable import SecutgCore

final class SealedBlobTests: XCTestCase {
    func testRoundTripAndTamper() throws {
        let key = SealedBlob.generateKey()
        let data = Data("{\"v\":1}".utf8)
        let blob = try SealedBlob.seal(data, key: key)
        XCTAssertEqual(SealedBlob.open(blob, key: key), data)
        var flipped = blob
        flipped[flipped.count - 1] ^= 0x01
        XCTAssertNil(SealedBlob.open(flipped, key: key))
        XCTAssertNil(SealedBlob.open(blob, key: SealedBlob.generateKey()))
        XCTAssertNil(SealedBlob.open(Data([1, 2, 3]), key: key))
        XCTAssertThrowsError(try SealedBlob.seal(data, key: [1]))
    }

    func testEnvironmentOverridesMapToConfigKeys() {
        let o = SecutgConfigFiles.overrides(from: ["TG_TELEGRAM_API_ID": "5", "TG_SECUTG_EPOCH_DAYS": "3", "OTHER": "x", "TG_APP_NAME": ""])
        XCTAssertEqual(o, ["api_id": "5", "crypto.epoch_days": "3"])
    }
}
