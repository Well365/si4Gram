import XCTest
@testable import SecutgCore

/// Ported from Android's `MergeTest.java` — v1.4 section 18 step 6/7.
final class V2MergeTests: XCTestCase {

    private func master(_ fill: UInt8) -> String {
        return Base64Url.encode([UInt8](repeating: fill, count: 32))
    }

    private func masterBytes(_ fill: UInt8) -> [UInt8] {
        return [UInt8](repeating: fill, count: 32)
    }

    func testAPrivateRecordWithNoLocalStateInstallsAsHistorical() {
        let bindingKeys = V2KeyStore.BindingKeyStore()
        let record = V2K2.KeyRecord(scopeKind: "private", chatId: "c1", bindingOrGenesisId: "b1", epoch: 1, stateHash: nil, master: master(1))
        let outcome = V2Merge.mergeValidatedRecords([record], bindingKeyStore: bindingKeys, groupKeyStore: V2GroupKeyStore())
        XCTAssertEqual(outcome.installed.count, 1)
        XCTAssertTrue(outcome.alreadyPresent.isEmpty)
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertEqual(bindingKeys.get("b1", 1)?.status, .historical)
    }

    func testAGroupRecordInstallsIntoGroupKeyStoreKeyedByItsOwnStateHashAsHistorical() {
        let groupKeys = V2GroupKeyStore()
        let record = V2K2.KeyRecord(scopeKind: "group", chatId: "g1", bindingOrGenesisId: "g1", epoch: 2, stateHash: "sh2", master: master(2))
        let outcome = V2Merge.mergeValidatedRecords([record], bindingKeyStore: V2KeyStore.BindingKeyStore(), groupKeyStore: groupKeys)
        XCTAssertEqual(outcome.installed.count, 1)
        XCTAssertEqual(groupKeys.get("g1", "sh2")?.status, .historical)
    }

    func testImportingNeverMakesARecordCurrentEvenIntoAStoreWithNothingCurrentYet() {
        let bindingKeys = V2KeyStore.BindingKeyStore()
        let record = V2K2.KeyRecord(scopeKind: "private", chatId: "c1", bindingOrGenesisId: "b1", epoch: 1, stateHash: nil, master: master(1))
        _ = V2Merge.mergeValidatedRecords([record], bindingKeyStore: bindingKeys, groupKeyStore: V2GroupKeyStore())
        XCTAssertNotEqual(bindingKeys.get("b1", 1)?.status, .current)
    }

    func testARecordMatchingWhatIsAlreadyCurrentIsReportedPresentButNotRewritten() {
        let bindingKeys = V2KeyStore.BindingKeyStore()
        bindingKeys.installCurrent(bindingId: "b1", epoch: 1, master: masterBytes(1))
        let record = V2K2.KeyRecord(scopeKind: "private", chatId: "c1", bindingOrGenesisId: "b1", epoch: 1, stateHash: nil, master: master(1))
        let outcome = V2Merge.mergeValidatedRecords([record], bindingKeyStore: bindingKeys, groupKeyStore: V2GroupKeyStore())
        XCTAssertTrue(outcome.installed.isEmpty)
        XCTAssertEqual(outcome.alreadyPresent.count, 1)
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertEqual(bindingKeys.get("b1", 1)?.status, .current) // untouched, still current
    }

    func testAnOldBackupRecordThatDisagreesWithCurrentTrustedStateIsRefusedNeverOverwritesIt() {
        let bindingKeys = V2KeyStore.BindingKeyStore()
        bindingKeys.installCurrent(bindingId: "b1", epoch: 1, master: masterBytes(9)) // the REAL current key
        let staleRecord = V2K2.KeyRecord(scopeKind: "private", chatId: "c1", bindingOrGenesisId: "b1", epoch: 1, stateHash: nil, master: master(1)) // a DIFFERENT, stale one
        let outcome = V2Merge.mergeValidatedRecords([staleRecord], bindingKeyStore: bindingKeys, groupKeyStore: V2GroupKeyStore())
        XCTAssertTrue(outcome.installed.isEmpty)
        XCTAssertTrue(outcome.alreadyPresent.isEmpty)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertEqual(outcome.skipped[0].reason, .conflictsWithCurrentState)
        XCTAssertEqual(bindingKeys.get("b1", 1)?.master, masterBytes(9)) // unchanged
    }

    func testTheSameRuleProtectsAnExistingHistoricalRecordNotOnlyACurrentOne() {
        let bindingKeys = V2KeyStore.BindingKeyStore()
        bindingKeys.set(V2KeyStore.Record(bindingId: "b1", epoch: 1, status: .historical, master: masterBytes(9)))
        let conflicting = V2K2.KeyRecord(scopeKind: "private", chatId: "c1", bindingOrGenesisId: "b1", epoch: 1, stateHash: nil, master: master(1))
        let outcome = V2Merge.mergeValidatedRecords([conflicting], bindingKeyStore: bindingKeys, groupKeyStore: V2GroupKeyStore())
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertEqual(outcome.skipped[0].reason, .conflictsWithCurrentState)
    }

    func testAGroupRecordMissingStateHashIsSkippedWithItsOwnReason() {
        let record = V2K2.KeyRecord(scopeKind: "group", chatId: "g1", bindingOrGenesisId: "g1", epoch: 1, stateHash: nil, master: master(1))
        let outcome = V2Merge.mergeValidatedRecords([record], bindingKeyStore: V2KeyStore.BindingKeyStore(), groupKeyStore: V2GroupKeyStore())
        XCTAssertTrue(outcome.installed.isEmpty)
        XCTAssertTrue(outcome.alreadyPresent.isEmpty)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertEqual(outcome.skipped[0].reason, .missingStateHash)
    }

    func testAnUndecodeableMasterIsSkippedNeverCrashesTheWholeBatch() {
        let bad = V2K2.KeyRecord(scopeKind: "private", chatId: "c1", bindingOrGenesisId: "b1", epoch: 1, stateHash: nil, master: "not base64url!!!")
        let good = V2K2.KeyRecord(scopeKind: "private", chatId: "c2", bindingOrGenesisId: "b2", epoch: 1, stateHash: nil, master: master(1))
        let bindingKeys = V2KeyStore.BindingKeyStore()
        let outcome = V2Merge.mergeValidatedRecords([bad, good], bindingKeyStore: bindingKeys, groupKeyStore: V2GroupKeyStore())
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertEqual(outcome.skipped[0].reason, .malformedMaster)
        XCTAssertEqual(outcome.installed.count, 1)
    }

    func testOneConflictingRecordDoesNotBlockSiblingsFromInstalling() {
        let bindingKeys = V2KeyStore.BindingKeyStore()
        bindingKeys.installCurrent(bindingId: "b1", epoch: 1, master: masterBytes(9))
        let conflicting = V2K2.KeyRecord(scopeKind: "private", chatId: "c1", bindingOrGenesisId: "b1", epoch: 1, stateHash: nil, master: master(1))
        let clean = V2K2.KeyRecord(scopeKind: "private", chatId: "c2", bindingOrGenesisId: "b2", epoch: 1, stateHash: nil, master: master(2))
        let outcome = V2Merge.mergeValidatedRecords([conflicting, clean], bindingKeyStore: bindingKeys, groupKeyStore: V2GroupKeyStore())
        XCTAssertEqual(outcome.installed.count, 1)
        XCTAssertEqual(outcome.installed[0], clean)
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertEqual(outcome.skipped[0].reason, .conflictsWithCurrentState)
    }
}
