import XCTest
@testable import SecutgCore

/// Executes `Vectors/v2-qa-vectors.json`'s K01/W01/K02/K03 cases (a byte-for-byte copy of the Web
/// reference's `src/secutg/v2/qa/vectors.json`, and identical to Android's
/// `vectors/v2-qa-vectors.json`) against the real V2K2/V2Disaster/V2Merge/V2W2 implementations.
/// Ported from `src/secutg/v2/qa/vectors.test.ts` and Android's `VectorsTest.java`.
///
/// Only these four families are ported to literal JSON vectors so far — the other 16 v1.4 section 22
/// rows are inherently multi-actor/multi-step and stay covered by the existing imperative TDD suites
/// (V2ProcessorTests, V2GroupProcessorTests, etc.); porting them needs a general scripted multi-step
/// vector runner, which is not built in this slice either, matching the same deferral the Web
/// reference's own module doc states and Android's own port left as its one concretely scoped
/// remaining QA-01 gap.
final class V2VectorsTests: XCTestCase {

    private func findVector(_ id: String) -> [String: Any] {
        let root = Vectors.load("v2-qa-vectors")
        guard let vectors = root["vectors"] as? [[String: Any]] else {
            XCTFail("v2-qa-vectors.json missing 'vectors'")
            return [:]
        }
        guard let found = vectors.first(where: { $0["id"] as? String == id }) else {
            XCTFail("qa vector \(id) not found in v2-qa-vectors.json")
            return [:]
        }
        guard let initialState = found["initial_state"] as? [String: Any] else {
            XCTFail("qa vector \(id) missing initial_state")
            return [:]
        }
        return initialState
    }

    // MARK: K01

    private func k01FreshFile(_ initial: [String: Any], secret: [UInt8]) -> String {
        let payload = initial["payload"] as! [String: Any]
        let built = V2K2.buildHistoryOnlyPayload(
            exportId: payload["exportId"] as! String, sourceDisplayName: payload["sourceDisplayName"] as! String,
            createdMs: payload["createdMs"] as! String, keyRecords: []
        )
        return V2K2.buildK2File(secret: secret, payload: built)!
    }

    func testK01CorrectSecretDecryptsSuccessfully() {
        let initial = findVector("K01")
        let secret = Base64Url.decode(initial["carry_secret_b64url"] as! String)!
        XCTAssertTrue(V2K2.decryptK2File(k01FreshFile(initial, secret: secret), secret: secret).ok)
    }

    func testK01WrongSecretFailsWithReasonInvalid() {
        let initial = findVector("K01")
        let secret = Base64Url.decode(initial["carry_secret_b64url"] as! String)!
        let wrongSecret = secret.map { $0 ^ 0xff }
        let outcome = V2K2.decryptK2File(k01FreshFile(initial, secret: secret), secret: wrongSecret)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "invalid")
    }

    func testK01CorruptedCiphertextFailsWithReasonInvalid() {
        let initial = findVector("K01")
        let secret = Base64Url.decode(initial["carry_secret_b64url"] as! String)!
        let file = k01FreshFile(initial, secret: secret)
        var envelope = try! JSONSerialization.jsonObject(with: file.data(using: .utf8)!) as! [String: Any]
        let ciphertext = envelope["ciphertext"] as! String
        let flipped: Character = ciphertext[ciphertext.index(ciphertext.endIndex, offsetBy: -2)] == "A" ? "B" : "A"
        envelope["ciphertext"] = String(ciphertext.dropLast(2)) + String(flipped) + ciphertext.suffix(1)
        let mangled = String(data: try! JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!
        let outcome = V2K2.decryptK2File(mangled, secret: secret)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "invalid")
    }

    func testK01GarbageJsonFailsWithReasonInvalid() {
        let initial = findVector("K01")
        let secret = Base64Url.decode(initial["carry_secret_b64url"] as! String)!
        let outcome = V2K2.decryptK2File("not even json", secret: secret)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "invalid")
    }

    // MARK: W01

    private func w01FreshStore(_ initial: [String: Any]) -> V2W2.W2AuthorizationStore {
        let store = V2W2.W2AuthorizationStore()
        let allowedScope = initial["allowed_scope"] as! [String]
        store.authorize(V2W2.Authorization(account: initial["account"] as! String, controlPublicKey: initial["issuer_pk_b64url"] as! String, allowedScope: allowedScope))
        return store
    }

    private func w01Event(_ initial: [String: Any]) -> String {
        let issuerPk = Base64Url.decode(initial["issuer_pk_b64url"] as! String)!
        let issuerSk = Base64Url.decode(initial["issuer_sk_b64url"] as! String)!
        let allowedScope = initial["allowed_scope"] as! [String]
        let issuedAtMs = Int64(initial["issued_at_ms"] as! Int)
        let expiresAtMs = Int64(initial["expires_at_ms"] as! Int)
        return V2W2.buildW2Event(V2W2.BuildParams(
            account: initial["account"] as! String, issuerIdentityPk: issuerPk, issuerIdentitySk: issuerSk,
            targetDevices: [initial["target_device"] as! String], scope: allowedScope, issuedAtMs: issuedAtMs, expiresAtMs: expiresAtMs
        ))!
    }

    func testW01FirstDeliveryAutoExecutesFullyPreAuthorized() {
        let initial = findVector("W01")
        let targetDevice = initial["target_device"] as! String
        let issuedAtMs = Int64(initial["issued_at_ms"] as! Int)
        let outcome = V2W2.handleW2Event(w01Event(initial), store: w01FreshStore(initial), dedup: V2W2.W2DedupStore(), thisDeviceId: targetDevice, nowMs: issuedAtMs)
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.kind, "auto_execute")
    }

    func testW01DuplicateDeliveryIsIdempotentNotReExecuted() {
        let initial = findVector("W01")
        let targetDevice = initial["target_device"] as! String
        let dedup = V2W2.W2DedupStore()
        let store = w01FreshStore(initial)
        let wire = w01Event(initial)
        let issuedAtMs = Int64(initial["issued_at_ms"] as! Int)
        _ = V2W2.handleW2Event(wire, store: store, dedup: dedup, thisDeviceId: targetDevice, nowMs: issuedAtMs)
        let second = V2W2.handleW2Event(wire, store: store, dedup: dedup, thisDeviceId: targetDevice, nowMs: issuedAtMs)
        XCTAssertTrue(second.ok)
        XCTAssertEqual(second.kind, "already_processed")
    }

    func testW01ExpiredRefusesWithReasonExpiredNeverExecutes() {
        let initial = findVector("W01")
        let targetDevice = initial["target_device"] as! String
        let outcome = V2W2.handleW2Event(w01Event(initial), store: w01FreshStore(initial), dedup: V2W2.W2DedupStore(), thisDeviceId: targetDevice, nowMs: 1700100000000)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "expired")
    }

    func testW01NotATargetRefusesWithReasonNotATargetNeverExecutes() {
        let initial = findVector("W01")
        let otherDevice = "aWtAWD2J_XfQIQPwAx7OBxwfFAVqhaVmbSqbjjN_sH4"
        let issuedAtMs = Int64(initial["issued_at_ms"] as! Int)
        let outcome = V2W2.handleW2Event(w01Event(initial), store: w01FreshStore(initial), dedup: V2W2.W2DedupStore(), thisDeviceId: otherDevice, nowMs: issuedAtMs)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "not_a_target")
    }

    // MARK: K02

    private func fillBytes(_ fill: UInt8) -> [UInt8] {
        return [UInt8](repeating: fill, count: 32)
    }

    private func k02FreshBindingKeys(_ initial: [String: Any]) -> V2KeyStore.BindingKeyStore {
        let bindingKeys = V2KeyStore.BindingKeyStore()
        bindingKeys.installCurrent(bindingId: initial["binding_id"] as! String, epoch: initial["epoch"] as! Int, master: fillBytes(UInt8(initial["current_master_fill_byte"] as! Int)))
        return bindingKeys
    }

    func testK02StaleConflictingNeverOverwritesCurrent() {
        let initial = findVector("K02")
        let bindingKeys = k02FreshBindingKeys(initial)
        let groupKeys = V2GroupKeyStore()
        let staleRecord = V2K2.KeyRecord(scopeKind: "private", chatId: "chat", bindingOrGenesisId: initial["binding_id"] as! String, epoch: initial["epoch"] as! Int, stateHash: nil, master: Base64Url.encode(fillBytes(1)))
        let outcome = V2Merge.mergeValidatedRecords([staleRecord], bindingKeyStore: bindingKeys, groupKeyStore: groupKeys)
        XCTAssertTrue(outcome.installed.isEmpty)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertEqual(outcome.skipped[0].reason, .conflictsWithCurrentState)
        XCTAssertEqual(bindingKeys.get(initial["binding_id"] as! String, initial["epoch"] as! Int)?.master, fillBytes(UInt8(initial["current_master_fill_byte"] as! Int)))
    }

    func testK02MatchesCurrentIsReportedAlreadyPresentNotRewritten() {
        let initial = findVector("K02")
        let bindingKeys = k02FreshBindingKeys(initial)
        let groupKeys = V2GroupKeyStore()
        let matching = V2K2.KeyRecord(scopeKind: "private", chatId: "chat", bindingOrGenesisId: initial["binding_id"] as! String, epoch: initial["epoch"] as! Int, stateHash: nil, master: Base64Url.encode(fillBytes(UInt8(initial["current_master_fill_byte"] as! Int))))
        let outcome = V2Merge.mergeValidatedRecords([matching], bindingKeyStore: bindingKeys, groupKeyStore: groupKeys)
        XCTAssertTrue(outcome.installed.isEmpty)
        XCTAssertEqual(outcome.alreadyPresent.count, 1)
    }

    // MARK: K03

    func testK03CorrectSecretDecryptsAndImportsExposingOnlyIdentityFields() {
        let initial = findVector("K03")
        let secret = Base64Url.decode(initial["carry_secret_b64url"] as! String)!
        let identitySk = Base64Url.decode(initial["identity_sk_b64url"] as! String)!
        let encapsulationSk = Base64Url.decode(initial["encapsulation_sk_b64url"] as! String)!
        let payload = V2Disaster.buildDisasterPayload(exportId: "qa-vector-k03", sourceDisplayName: "qa-vector-device", createdMs: "1700000000000", identitySk: identitySk, encapsulationSk: encapsulationSk, keyRecords: [])
        let file = V2Disaster.buildDisasterFile(secret: secret, payload: payload)!

        let outcome = V2Disaster.decryptDisasterFile(file, secret: secret)
        XCTAssertTrue(outcome.ok)
        let imported = V2Disaster.importDisasterPayload(outcome.payload!)
        XCTAssertEqual(imported?.identitySk, identitySk)
        XCTAssertEqual(imported?.encapsulationSk, encapsulationSk)
        XCTAssertTrue(imported!.keyRecords.isEmpty)
    }

    func testK03WrongSecretFailsWithTheSameUniformReasonAsK01W01() {
        let initial = findVector("K03")
        let secret = Base64Url.decode(initial["carry_secret_b64url"] as! String)!
        let identitySk = Base64Url.decode(initial["identity_sk_b64url"] as! String)!
        let encapsulationSk = Base64Url.decode(initial["encapsulation_sk_b64url"] as! String)!
        let payload = V2Disaster.buildDisasterPayload(exportId: "qa-vector-k03", sourceDisplayName: "qa-vector-device", createdMs: "1700000000000", identitySk: identitySk, encapsulationSk: encapsulationSk, keyRecords: [])
        let file = V2Disaster.buildDisasterFile(secret: secret, payload: payload)!

        let wrongSecret = secret.map { $0 ^ 0xff }
        let outcome = V2Disaster.decryptDisasterFile(file, secret: wrongSecret)
        XCTAssertFalse(outcome.ok)
        XCTAssertEqual(outcome.reason, "invalid")
    }
}
