import XCTest
@testable import SecutgCore

/// Ported from Android's `EventLogTest`/`SelectionCasTest`/`OutboxQueueTest`/`SyncGateTest` (CORE-02).
final class V2CoreStoreTests: XCTestCase {

    // MARK: V2EventLog

    func testEventLogFirstRecordReturnsFirst() {
        let log = V2EventLog<String>()
        let result = log.record(eventId: "e1", contentHash: "h1") { "computed" }
        XCTAssertEqual(result.kind, .first)
        XCTAssertEqual(result.result, "computed")
    }

    func testEventLogSameEventIdSameContentReplays() {
        let log = V2EventLog<String>()
        _ = log.record(eventId: "e1", contentHash: "h1") { "computed" }
        let second = log.record(eventId: "e1", contentHash: "h1") { "should not run" }
        XCTAssertEqual(second.kind, .replay)
        XCTAssertEqual(second.result, "computed")
    }

    func testEventLogSameEventIdDifferentContentConflicts() {
        let log = V2EventLog<String>()
        _ = log.record(eventId: "e1", contentHash: "h1") { "first" }
        let second = log.record(eventId: "e1", contentHash: "h2") { "second" }
        XCTAssertEqual(second.kind, .conflict)
        XCTAssertEqual(second.existing, "first")
        XCTAssertNil(second.result)
    }

    func testEventLogHasAndSize() {
        let log = V2EventLog<Int>()
        XCTAssertFalse(log.has("e1"))
        _ = log.record(eventId: "e1", contentHash: "h1") { 1 }
        XCTAssertTrue(log.has("e1"))
        XCTAssertEqual(log.size, 1)
    }

    // MARK: V2SelectionCas

    func testSelectionCasFirstCallerWins() {
        let cas = V2SelectionCas<String>()
        let result = cas.select(slotKey: "chat-1", candidateId: "txn-a")
        XCTAssertTrue(result.won)
        XCTAssertEqual(result.selected, "txn-a")
    }

    func testSelectionCasSecondCallerLoses() {
        let cas = V2SelectionCas<String>()
        _ = cas.select(slotKey: "chat-1", candidateId: "txn-a")
        let second = cas.select(slotKey: "chat-1", candidateId: "txn-b")
        XCTAssertFalse(second.won)
        XCTAssertEqual(second.selected, "txn-a")
    }

    func testSelectionCasARetryOfTheWinnerReportsWonFalseButSameSelected() {
        let cas = V2SelectionCas<String>()
        _ = cas.select(slotKey: "chat-1", candidateId: "txn-a")
        let retry = cas.select(slotKey: "chat-1", candidateId: "txn-a")
        XCTAssertFalse(retry.won)
        XCTAssertEqual(retry.selected, "txn-a")
    }

    func testSelectionCasForceReplaceOverwritesTheSlot() {
        let cas = V2SelectionCas<String>()
        _ = cas.select(slotKey: "chat-1", candidateId: "txn-a")
        cas.forceReplace(slotKey: "chat-1", candidateId: "txn-c")
        XCTAssertEqual(cas.get("chat-1"), "txn-c")
    }

    func testSelectionCasHasAndGet() {
        let cas = V2SelectionCas<String>()
        XCTAssertFalse(cas.has("chat-1"))
        XCTAssertNil(cas.get("chat-1"))
        _ = cas.select(slotKey: "chat-1", candidateId: "txn-a")
        XCTAssertTrue(cas.has("chat-1"))
    }

    // MARK: V2SyncGate

    func testSyncGateStartsCatchingUpAndMarksSyncedWithNoGaps() {
        let gate = V2SyncGate()
        XCTAssertFalse(gate.isSynced)
        XCTAssertTrue(gate.markSynced())
        XCTAssertTrue(gate.isSynced)
    }

    func testSyncGateRefusesToMarkSyncedWithAnOpenGap() {
        let gate = V2SyncGate()
        gate.recordGap("gap-1")
        XCTAssertFalse(gate.markSynced())
        XCTAssertFalse(gate.isSynced)
        gate.closeGap("gap-1")
        XCTAssertTrue(gate.markSynced())
    }

    func testSyncGateBeginCatchUpResetsSyncedState() {
        let gate = V2SyncGate()
        XCTAssertTrue(gate.markSynced())
        gate.beginCatchUp()
        XCTAssertFalse(gate.isSynced)
    }

    func testSyncGateHasOpenGaps() {
        let gate = V2SyncGate()
        XCTAssertFalse(gate.hasOpenGaps)
        gate.recordGap("gap-1")
        XCTAssertTrue(gate.hasOpenGaps)
    }

    // MARK: V2OutboxQueue

    func testOutboxQueueEnqueueThenGet() {
        let queue = V2OutboxQueue()
        queue.enqueue(eventId: "e1", bytes: "wire-bytes", family: "INVITE")
        let item = queue.get("e1")
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.status, .pending)
        XCTAssertEqual(item?.bytes, "wire-bytes")
    }

    func testOutboxQueueRepeatEnqueueOfSameEventIdIsANoOp() {
        let queue = V2OutboxQueue()
        queue.enqueue(eventId: "e1", bytes: "first", family: "INVITE")
        queue.enqueue(eventId: "e1", bytes: "second", family: "ACCEPT")
        XCTAssertEqual(queue.get("e1")?.bytes, "first")
        XCTAssertEqual(queue.size, 1)
    }

    func testOutboxQueueMarkSentOnlyAffectsPendingItems() {
        let queue = V2OutboxQueue()
        queue.enqueue(eventId: "e1", bytes: "wire", family: "INVITE")
        queue.markSent("e1")
        XCTAssertEqual(queue.get("e1")?.status, .sent)
        queue.cancel(eventId: "e1", reason: "too late") // already sent, no-op
        XCTAssertEqual(queue.get("e1")?.status, .sent)
    }

    func testOutboxQueueCancelRecordsReason() {
        let queue = V2OutboxQueue()
        queue.enqueue(eventId: "e1", bytes: "wire", family: "INVITE")
        queue.cancel(eventId: "e1", reason: "expired")
        XCTAssertEqual(queue.get("e1")?.status, .cancelled)
        XCTAssertEqual(queue.get("e1")?.cancelReason, "expired")
    }

    func testOutboxQueuePendingOrdersByFamilyDependencyThenEnqueueOrder() {
        let queue = V2OutboxQueue()
        queue.enqueue(eventId: "e-ready", bytes: "r", family: "READY")
        queue.enqueue(eventId: "e-invite", bytes: "i", family: "INVITE")
        queue.enqueue(eventId: "e-select", bytes: "s", family: "SELECT")
        queue.enqueue(eventId: "e-other", bytes: "o", family: "UNKNOWN")
        let order = queue.pending().map { $0.eventId }
        XCTAssertEqual(order, ["e-invite", "e-select", "e-ready", "e-other"])
    }

    func testOutboxQueueRecoverPendingCancelsInvalidItemsAndReturnsSurvivors() {
        let queue = V2OutboxQueue()
        queue.enqueue(eventId: "e-good", bytes: "g", family: "INVITE")
        queue.enqueue(eventId: "e-bad", bytes: "b", family: "ACCEPT")
        let survivors = queue.recoverPending { item in
            item.eventId == "e-bad" ? .invalid("revoked") : .valid()
        }
        XCTAssertEqual(survivors.map { $0.eventId }, ["e-good"])
        XCTAssertEqual(queue.get("e-bad")?.status, .cancelled)
        XCTAssertEqual(queue.get("e-bad")?.cancelReason, "revoked")
        XCTAssertEqual(queue.get("e-good")?.status, .pending)
    }
}
