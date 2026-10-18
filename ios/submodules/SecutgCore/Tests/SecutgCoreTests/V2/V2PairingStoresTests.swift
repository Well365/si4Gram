import XCTest
@testable import SecutgCore

/// Ported (reduced set) from Android's `BindingTest`/`AuthorizationTest`/`KeyStoreTest`.
final class V2PairingStoresTests: XCTestCase {

    // MARK: V2Binding

    private func sampleBinding(chatId: String = "c1", bindingId: String = "b1", txnId: String = "t1") -> V2Binding {
        return V2Binding.freshTemplate(chatId: chatId, bindingId: bindingId, epoch: 1, deviceRoster: ["d1"], deviceKeys: [:], revision: 1, txnId: txnId, installedAtMs: 1000)
    }

    func testBindingInstallSetsCurrentAndStartsUnverifiedUnsuspended() {
        let store = V2Binding.BindingStore()
        store.install(sampleBinding())
        let current = store.current("c1")
        XCTAssertNotNil(current)
        XCTAssertFalse(current!.verified)
        XCTAssertFalse(current!.suspended)
        XCTAssertTrue(store.canSend("c1"))
    }

    func testBindingInstallingADifferentBindingIdMovesThePreviousOneToHistorical() {
        let store = V2Binding.BindingStore()
        store.install(sampleBinding(bindingId: "b1", txnId: "t1"))
        store.install(sampleBinding(bindingId: "b2", txnId: "t2"))
        XCTAssertEqual(store.current("c1")?.bindingId, "b2")
        XCTAssertEqual(store.historical("c1").count, 1)
        XCTAssertEqual(store.historical("c1")[0].bindingId, "b1")
    }

    func testBindingSuspendBlocksCanSend() {
        let store = V2Binding.BindingStore()
        store.install(sampleBinding())
        store.suspend("c1")
        XCTAssertFalse(store.canSend("c1"))
    }

    func testBindingMismatchBlocksCanSendUntilOverridden() {
        let store = V2Binding.BindingStore()
        store.install(sampleBinding())
        store.markMismatch(chatId: "c1", bindingId: "b1")
        XCTAssertFalse(store.canSend("c1"))
        store.overrideMismatch(chatId: "c1", bindingId: "b1")
        XCTAssertTrue(store.canSend("c1"))
    }

    func testBindingAlreadyInstalledForChecksCurrentAndHistorical() {
        let store = V2Binding.BindingStore()
        store.install(sampleBinding(bindingId: "b1", txnId: "t1"))
        store.install(sampleBinding(bindingId: "b2", txnId: "t2"))
        XCTAssertTrue(store.alreadyInstalledFor(chatId: "c1", txnId: "t1"))
        XCTAssertTrue(store.alreadyInstalledFor(chatId: "c1", txnId: "t2"))
        XCTAssertFalse(store.alreadyInstalledFor(chatId: "c1", txnId: "t3"))
    }

    func testBindingApplyRosterCommitRotatesEpochWithoutHistoricizing() {
        let store = V2Binding.BindingStore()
        store.install(sampleBinding())
        store.applyRosterCommit(chatId: "c1", epoch: 2, deviceRoster: ["d1", "d2"], deviceKeys: [:])
        XCTAssertEqual(store.current("c1")?.bindingId, "b1")
        XCTAssertEqual(store.current("c1")?.epoch, 2)
        XCTAssertTrue(store.historical("c1").isEmpty)
    }

    func testTombstoneStoreRecordCancelledIsWriteOnceAndUnpairedIsSeparatelyKeyed() {
        let store = V2Binding.TombstoneStore()
        store.recordCancelled(txnId: "t1", eventId: "e1", atMs: 1000)
        store.recordCancelled(txnId: "t1", eventId: "e2", atMs: 2000) // ignored, first wins
        XCTAssertEqual(store.cancelledFor("t1")?.eventId, "e1")
        XCTAssertNil(store.unpairedFor("t1"))
        store.recordUnpaired(bindingId: "b1", eventId: "e3", atMs: 3000)
        XCTAssertEqual(store.unpairedFor("b1")?.eventId, "e3")
    }

    // MARK: V2Authorization

    func testAuthorizationFindEligibleMatchesExactTripleAndRespectsExpiry() {
        let store = V2Authorization.AuthorizationStore()
        store.register(V2Authorization.Policy(policyId: "p1", localDevice: "dev", chatId: "c1", peerUser: "200", peerSignPk: "pk1", createdAtMs: 0, expiresAtMs: 10_000))
        XCTAssertNotNil(store.findEligible(chatId: "c1", peerUser: "200", peerSignPk: "pk1", nowMs: 5000, txnId: "t1"))
        XCTAssertNil(store.findEligible(chatId: "c1", peerUser: "200", peerSignPk: "pk1", nowMs: 20_000, txnId: "t1"))
        XCTAssertNil(store.findEligible(chatId: "c1", peerUser: "999", peerSignPk: "pk1", nowMs: 5000, txnId: "t1"))
    }

    func testAuthorizationLockToTxnRestrictsFutureEligibilityToThatTxn() {
        let store = V2Authorization.AuthorizationStore()
        store.register(V2Authorization.Policy(policyId: "p1", localDevice: "dev", chatId: "c1", peerUser: "200", peerSignPk: "pk1", createdAtMs: 0, expiresAtMs: 10_000))
        store.lockToTxn(policyId: "p1", txnId: "t1")
        XCTAssertNotNil(store.findEligible(chatId: "c1", peerUser: "200", peerSignPk: "pk1", nowMs: 100, txnId: "t1"))
        XCTAssertNil(store.findEligible(chatId: "c1", peerUser: "200", peerSignPk: "pk1", nowMs: 100, txnId: "t2"))
    }

    func testAuthorizationConsumeByTxnMarksTheLockedPolicyConsumed() {
        let store = V2Authorization.AuthorizationStore()
        store.register(V2Authorization.Policy(policyId: "p1", localDevice: "dev", chatId: "c1", peerUser: "200", peerSignPk: "pk1", createdAtMs: 0, expiresAtMs: 10_000))
        store.lockToTxn(policyId: "p1", txnId: "t1")
        store.consumeByTxn("t1")
        XCTAssertEqual(store.statusOf("p1"), .consumed)
        XCTAssertNil(store.findEligible(chatId: "c1", peerUser: "200", peerSignPk: "pk1", nowMs: 100, txnId: "t1"))
    }

    func testAuthorizationRevokeMakesItIneligible() {
        let store = V2Authorization.AuthorizationStore()
        store.register(V2Authorization.Policy(policyId: "p1", localDevice: "dev", chatId: "c1", peerUser: "200", peerSignPk: "pk1", createdAtMs: 0, expiresAtMs: 10_000))
        store.revoke("p1")
        XCTAssertNil(store.findEligible(chatId: "c1", peerUser: "200", peerSignPk: "pk1", nowMs: 100, txnId: "t1"))
    }

    // MARK: V2KeyStore

    func testKeyStoreInstallCurrentDemotesWhateverWasCurrentThenInstallsTheNewOne() {
        let store = V2KeyStore.BindingKeyStore()
        store.installCurrent(bindingId: "b1", epoch: 1, master: [1])
        store.installCurrent(bindingId: "b1", epoch: 2, master: [2])
        XCTAssertEqual(store.get("b1", 1)?.status, .historical)
        XCTAssertEqual(store.get("b1", 2)?.status, .current)
        XCTAssertEqual(store.get("b1", 2)?.master, [2])
    }

    func testKeyStoreOnlyOneRecordIsEverCurrentForAGivenBinding() {
        let store = V2KeyStore.BindingKeyStore()
        store.installCurrent(bindingId: "b1", epoch: 1, master: [1])
        store.installCurrent(bindingId: "b1", epoch: 2, master: [2])
        store.installCurrent(bindingId: "b1", epoch: 3, master: [3])
        XCTAssertEqual(store.all("b1").filter { $0.status == .current }.count, 1)
    }

    func testKeyStoreMissingReturnsOnlyRecordsMarkedMissing() {
        let store = V2KeyStore.BindingKeyStore()
        store.set(V2KeyStore.Record(bindingId: "b1", epoch: 1, status: .missing, master: nil))
        store.set(V2KeyStore.Record(bindingId: "b1", epoch: 2, status: .current, master: [1]))
        XCTAssertEqual(store.missing("b1").count, 1)
        XCTAssertEqual(store.missing("b1")[0].epoch, 1)
    }

    func testKeyStoreAllBindingIdsListsEveryBindingThisStoreHoldsAnyRecordFor() {
        let store = V2KeyStore.BindingKeyStore()
        store.installCurrent(bindingId: "b1", epoch: 1, master: [1])
        store.installCurrent(bindingId: "b2", epoch: 1, master: [2])
        let ids = Set(store.allBindingIds())
        XCTAssertEqual(ids, ["b1", "b2"])
    }
}
