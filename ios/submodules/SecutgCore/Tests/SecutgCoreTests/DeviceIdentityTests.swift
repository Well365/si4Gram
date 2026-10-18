import XCTest
@testable import SecutgCore

/// PLAN.md 3.25.2 / 3.25.7 rule 4: device_id / device_code derivation, cross-checked against the same three
/// vectors as Web A `src/secutg/keyring/device.test.ts` — all zero, all 0xFF, and 0x01..0x20.
final class DeviceIdentityTests: XCTestCase {
    func testDeviceIdentityVectors() throws {
        let allZero = try DeviceIdentity.derive(x25519Pk: [UInt8](repeating: 0x00, count: 32))
        XCTAssertEqual(allZero.deviceId, "3b824e8358cee308")
        XCTAssertEqual(allZero.deviceCode, "XR4-KM3")

        let allFF = try DeviceIdentity.derive(x25519Pk: [UInt8](repeating: 0xFF, count: 32))
        XCTAssertEqual(allFF.deviceId, "ef3c7c05acaadd86")
        XCTAssertEqual(allFF.deviceCode, "QKR-Z05")

        let sequential = try DeviceIdentity.derive(x25519Pk: Array(1...32).map { UInt8($0) })
        XCTAssertEqual(sequential.deviceId, "fdc674d049598e02")
        XCTAssertEqual(sequential.deviceCode, "YWC-X6G")
    }

    func testDeviceCodeIsRecoverableFromTheIdAlone() throws {
        let identity = try DeviceIdentity.derive(x25519Pk: [UInt8](repeating: 0x00, count: 32))
        XCTAssertEqual(DeviceIdentity.deviceCode(forId: identity.deviceId), identity.deviceCode)
        XCTAssertNil(DeviceIdentity.deviceCode(forId: "not-a-device-id"))
        XCTAssertNil(DeviceIdentity.deviceCode(forId: String(identity.deviceId.dropLast())))
    }

    func testDerivationRejectsAMalformedPublicKey() {
        XCTAssertThrowsError(try DeviceIdentity.derive(x25519Pk: [UInt8](repeating: 0, count: 31)))
    }

    func testIsValidDeviceIdMatchesExactlySixteenLowercaseHexChars() {
        XCTAssertTrue(DeviceIdentity.isValidDeviceId("3b824e8358cee308"))
        XCTAssertFalse(DeviceIdentity.isValidDeviceId("3B824E8358CEE308"))   // uppercase
        XCTAssertFalse(DeviceIdentity.isValidDeviceId("3b824e8358cee30"))   // too short
        XCTAssertFalse(DeviceIdentity.isValidDeviceId("3b824e8358cee3089")) // too long
        XCTAssertFalse(DeviceIdentity.isValidDeviceId(""))
    }

    // MARK: peerSeenDeviceIds (PLAN.md 3.25.3)

    func testPushSeenDeviceIdAppendsInFirstSeenOrderWithoutDuplicates() {
        var seen: [String]? = nil
        seen = DeviceIdentity.pushSeenDeviceId(seen, "a")
        seen = DeviceIdentity.pushSeenDeviceId(seen, "b")
        seen = DeviceIdentity.pushSeenDeviceId(seen, "a")   // already present: no change
        XCTAssertEqual(seen, ["a", "b"])
    }

    func testPushSeenDeviceIdDropsTheOldestOnceOverEight() {
        var seen: [String]? = nil
        for i in 0..<10 { seen = DeviceIdentity.pushSeenDeviceId(seen, "d\(i)") }
        XCTAssertEqual(seen?.count, DeviceIdentity.maxSeenDeviceIds)
        XCTAssertEqual(seen, (2..<10).map { "d\($0)" })
    }

    // MARK: device labels (PLAN.md 3.25.3)

    func testNormalizeLabelTrimsAndCapsAtFortyChars() {
        XCTAssertEqual(DeviceIdentity.normalizeLabel("  家里的电脑  "), "家里的电脑")
        XCTAssertEqual(DeviceIdentity.normalizeLabel("   \n\t  "), "")
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(DeviceIdentity.normalizeLabel(long).count, DeviceIdentity.labelMaxChars)
    }
}
