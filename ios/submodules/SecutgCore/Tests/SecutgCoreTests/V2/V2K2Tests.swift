import XCTest
@testable import SecutgCore

/// Ported from Android's `K2Test.java` — no TEST_MATRIX.md section exists for BACKUP-01, cases
/// derived directly from v1.4 section 17/18's own text.
final class V2K2Tests: XCTestCase {

    private func master(_ fill: UInt8) -> String {
        return Base64Url.encode([UInt8](repeating: fill, count: 32))
    }

    private func sampleRecords() -> [V2K2.KeyRecord] {
        return [
            V2K2.KeyRecord(scopeKind: "private", chatId: "chat-1", bindingOrGenesisId: "b1", epoch: 1, stateHash: nil, master: master(1)),
            V2K2.KeyRecord(scopeKind: "group", chatId: "group-1", bindingOrGenesisId: "g1", epoch: 2, stateHash: "sh-g1-2", master: master(2)),
        ]
    }

    func testTheCorrectCarrySecretDecryptsBackToTheExactPayload() {
        let secret = V2Suite.randomBytes(32)
        let payload = V2K2.buildHistoryOnlyPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", keyRecords: sampleRecords())
        let file = V2K2.buildK2File(secret: secret, payload: payload)
        XCTAssertNotNil(file)

        let outcome = V2K2.decryptK2File(file!, secret: secret)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.payload?.exportId, payload.exportId)
        XCTAssertEqual(outcome.payload?.keyRecords.count, payload.keyRecords.count)
        XCTAssertEqual(outcome.payload?.keyRecords[0].master, payload.keyRecords[0].master)
        XCTAssertEqual(outcome.payload?.keyRecords[1].stateHash, payload.keyRecords[1].stateHash)
    }

    func testPermissionsAndScopeAreFixedForHistoryOnlyExports() {
        let payload = V2K2.buildHistoryOnlyPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", keyRecords: [])
        XCTAssertEqual(payload.scope, "history_only")
        XCTAssertEqual(payload.permissions, ["read_history"])
    }

    func testAWrongCarrySecretAndACorruptedFileBothFailWithTheSameReason() {
        let secret = V2Suite.randomBytes(32)
        let wrongSecret = V2Suite.randomBytes(32)
        let payload = V2K2.buildHistoryOnlyPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", keyRecords: sampleRecords())
        let file = V2K2.buildK2File(secret: secret, payload: payload)!

        XCTAssertFalse(V2K2.decryptK2File(file, secret: wrongSecret).ok)
        XCTAssertFalse(V2K2.decryptK2File(String(file.dropLast(4)) + "xxxx", secret: secret).ok)
        XCTAssertFalse(V2K2.decryptK2File("not even json", secret: secret).ok)
        XCTAssertEqual(V2K2.decryptK2File(file, secret: wrongSecret).reason, "invalid")
    }

    func testATamperedCiphertextFailsNotSilentlyReturnsGarbage() {
        let secret = V2Suite.randomBytes(32)
        let payload = V2K2.buildHistoryOnlyPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", keyRecords: sampleRecords())
        let file = V2K2.buildK2File(secret: secret, payload: payload)!
        let data = file.data(using: .utf8)!
        var envelope = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let ciphertext = envelope["ciphertext"] as! String
        let lastButOne = ciphertext[ciphertext.index(ciphertext.endIndex, offsetBy: -2)]
        let flipped: Character = lastButOne == "A" ? "B" : "A"
        let tampered = String(ciphertext.dropLast(2)) + String(flipped) + ciphertext.suffix(1)
        envelope["ciphertext"] = tampered
        let tamperedData = try! JSONSerialization.data(withJSONObject: envelope)
        let tamperedFile = String(data: tamperedData, encoding: .utf8)!
        XCTAssertFalse(V2K2.decryptK2File(tamperedFile, secret: secret).ok)
    }

    func testTheTokenIssuedAtPreviewTimeValidatesAgainstTheSameRevisionNotADifferentOne() {
        let payload = V2K2.buildHistoryOnlyPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", keyRecords: sampleRecords())
        let token = V2K2.computePreviewToken(payload, revision: "rev-1")

        let validResult = V2K2.validateForImport(payload, previewToken: token, revision: "rev-1")
        XCTAssertTrue(validResult.ok)
        XCTAssertEqual(validResult.records?.count, payload.keyRecords.count)

        let staleResult = V2K2.validateForImport(payload, previewToken: token, revision: "rev-2")
        XCTAssertFalse(staleResult.ok)
        XCTAssertEqual(staleResult.reason, "stale_preview")
    }

    func testATokenComputedForADifferentPayloadNeverValidatesEvenAgainstTheRightRevision() {
        let payloadA = V2K2.buildHistoryOnlyPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", keyRecords: sampleRecords())
        let payloadB = V2K2.buildHistoryOnlyPayload(exportId: "exp-2", sourceDisplayName: "my-device", createdMs: "1000", keyRecords: sampleRecords())
        let tokenForA = V2K2.computePreviewToken(payloadA, revision: "rev-1")
        let result = V2K2.validateForImport(payloadB, previewToken: tokenForA, revision: "rev-1")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "stale_preview")
    }

    func testTheSameTripleAppearingTwiceWithDifferentMaterialIsRefused() {
        var records = sampleRecords()
        let conflicting = V2K2.KeyRecord(scopeKind: records[0].scopeKind, chatId: records[0].chatId, bindingOrGenesisId: records[0].bindingOrGenesisId, epoch: records[0].epoch, stateHash: records[0].stateHash, master: master(9))
        records.append(conflicting)
        let payload = V2K2.buildHistoryOnlyPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", keyRecords: records)
        let token = V2K2.computePreviewToken(payload, revision: "rev-1")
        let result = V2K2.validateForImport(payload, previewToken: token, revision: "rev-1")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "conflicting_key_material")
    }

    func testTheSameRecordRepeatedVerbatimIsNotTreatedAsAConflict() {
        var records = sampleRecords()
        records.append(records[0])
        let payload = V2K2.buildHistoryOnlyPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", keyRecords: records)
        let token = V2K2.computePreviewToken(payload, revision: "rev-1")
        XCTAssertTrue(V2K2.validateForImport(payload, previewToken: token, revision: "rev-1").ok)
    }

    func testAnEnvelopeWithTheWrongVersionOrKdfLabelIsRefused() {
        let secret = V2Suite.randomBytes(32)
        let wrongVersion = "{\"v\":1,\"kdf\":\"HKDF-SHA256\",\"salt\":\"x\",\"nonce\":\"y\",\"ciphertext\":\"z\"}"
        let wrongKdf = "{\"v\":2,\"kdf\":\"something-else\",\"salt\":\"x\",\"nonce\":\"y\",\"ciphertext\":\"z\"}"
        XCTAssertFalse(V2K2.decryptK2File(wrongVersion, secret: secret).ok)
        XCTAssertFalse(V2K2.decryptK2File(wrongKdf, secret: secret).ok)
    }

    func testASaltOrNonceOfTheWrongLengthIsRefused() {
        let secret = V2Suite.randomBytes(32)
        let payload = V2K2.buildHistoryOnlyPayload(exportId: "exp-1", sourceDisplayName: "my-device", createdMs: "1000", keyRecords: [])
        let file = V2K2.buildK2File(secret: secret, payload: payload)!
        let data = file.data(using: .utf8)!
        var envelope = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        envelope["salt"] = "short"
        let tamperedData = try! JSONSerialization.data(withJSONObject: envelope)
        let tamperedFile = String(data: tamperedData, encoding: .utf8)!
        XCTAssertFalse(V2K2.decryptK2File(tamperedFile, secret: secret).ok)
    }
}
