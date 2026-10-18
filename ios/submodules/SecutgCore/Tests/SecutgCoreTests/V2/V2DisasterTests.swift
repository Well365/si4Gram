import XCTest
@testable import SecutgCore

/// Ported from Android's `DisasterTest.java` — v1.4 section 17's "full disaster backup".
final class V2DisasterTests: XCTestCase {

    func testTheCorrectCarrySecretDecryptsBackToTheExactIdentityKeys() {
        let secret = V2Suite.randomBytes(32)
        let identity = V2Suite.generateEd25519()
        let encapsulation = V2Suite.generateX25519()
        let payload = V2Disaster.buildDisasterPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", identitySk: identity.secretKey, encapsulationSk: encapsulation.secretKey, keyRecords: [])
        let file = V2Disaster.buildDisasterFile(secret: secret, payload: payload)!
        let outcome = V2Disaster.decryptDisasterFile(file, secret: secret)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.payload?.identitySk, payload.identitySk)
        XCTAssertEqual(outcome.payload?.encapsulationSk, payload.encapsulationSk)

        let imported = V2Disaster.importDisasterPayload(outcome.payload!)
        XCTAssertEqual(imported?.identitySk, identity.secretKey)
        XCTAssertEqual(imported?.encapsulationSk, encapsulation.secretKey)
    }

    func testScopeIsFixedToFullDisasterAndPermissionsNeverIncludeAdminVerifiedRestoration() {
        let identity = V2Suite.generateEd25519()
        let encapsulation = V2Suite.generateX25519()
        let payload = V2Disaster.buildDisasterPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", identitySk: identity.secretKey, encapsulationSk: encapsulation.secretKey, keyRecords: [])
        XCTAssertEqual(payload.scope, "full_disaster")
        XCTAssertEqual(payload.permissions, ["read_history", "restore_identity"])
        XCTAssertFalse(payload.permissions.contains("admin_write"))
        XCTAssertFalse(payload.permissions.contains("verified"))
    }

    func testWrongSecretCorruptedFileAndGarbageAllFailIdentically() {
        let secret = V2Suite.randomBytes(32)
        let wrongSecret = V2Suite.randomBytes(32)
        let identity = V2Suite.generateEd25519()
        let encapsulation = V2Suite.generateX25519()
        let payload = V2Disaster.buildDisasterPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", identitySk: identity.secretKey, encapsulationSk: encapsulation.secretKey, keyRecords: [])
        let file = V2Disaster.buildDisasterFile(secret: secret, payload: payload)!

        XCTAssertFalse(V2Disaster.decryptDisasterFile(file, secret: wrongSecret).ok)
        XCTAssertFalse(V2Disaster.decryptDisasterFile(String(file.dropLast(4)) + "xxxx", secret: secret).ok)
        XCTAssertFalse(V2Disaster.decryptDisasterFile("not even json", secret: secret).ok)
        XCTAssertEqual(V2Disaster.decryptDisasterFile(file, secret: wrongSecret).reason, "invalid")
    }

    func testAHistoryOnlyK2FileWrongScopeIsRefusedByTheDisasterDecryptor() {
        let secret = V2Suite.randomBytes(32)
        let k2Payload = V2K2.buildHistoryOnlyPayload(exportId: "exp-1", sourceDisplayName: "d", createdMs: "1000", keyRecords: [])
        let k2File = V2K2.buildK2File(secret: secret, payload: k2Payload)
        XCTAssertNotNil(k2File)
        XCTAssertFalse(V2Disaster.decryptDisasterFile(k2File!, secret: secret).ok)
    }
}
