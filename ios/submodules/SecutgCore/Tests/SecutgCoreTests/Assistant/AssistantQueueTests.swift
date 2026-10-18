import XCTest
@testable import SecutgCore

/// Implementation plan C1.6 / C1.7: write-before-push, ack deletes, cap drops the oldest, seq survives restarts,
/// rescan watermarks persist and never re-emit.
final class AssistantQueueTests: XCTestCase {
    // Write-before-push is tested where the push happens: AssistantHubTests.

    func testAppendHasWrittenTheFileWhenItReturns() throws {
        let storage = AssistantMemoryQueueStorage()
        let queue = try AssistantEventQueue(storage: storage, lastSeq: 0, dropped: 0)
        let appended = try queue.append { seq in Data("event \(seq)".utf8) }
        XCTAssertEqual(storage.files[appended.seq], Data("event 1".utf8))
        XCTAssertEqual(queue.pending, [1])
    }

    func testFailedWriteConsumesNoSeqAndPushesNothing() throws {
        let storage = AssistantMemoryQueueStorage()
        let queue = try AssistantEventQueue(storage: storage, lastSeq: 4, dropped: 0)
        storage.failWrites = true
        XCTAssertThrowsError(try queue.append { _ in Data() })
        XCTAssertEqual(queue.lastSeq, 4)
        storage.failWrites = false
        XCTAssertEqual(try queue.append { _ in Data() }.seq, 5)
    }

    func testAckRemovesEverythingUpToSeq() throws {
        let storage = AssistantMemoryQueueStorage()
        let queue = try AssistantEventQueue(storage: storage, lastSeq: 0, dropped: 0)
        for _ in 0..<4 { _ = try queue.append { Data("\($0)".utf8) } }
        XCTAssertEqual(queue.ack(2), [1, 2])
        XCTAssertEqual(queue.pending, [3, 4])
        XCTAssertEqual(Set(storage.files.keys), [3, 4])
        XCTAssertEqual(queue.pending(after: 3), [4])
        XCTAssertNil(queue.read(seq: 1))
        XCTAssertEqual(queue.read(seq: 4), Data("4".utf8))
    }

    func testCapDropsOldestAndCounts() throws {
        let storage = AssistantMemoryQueueStorage()
        let queue = try AssistantEventQueue(storage: storage, cap: 3, lastSeq: 0, dropped: 2)
        for _ in 0..<5 { _ = try queue.append { Data("\($0)".utf8) } }
        XCTAssertEqual(queue.pending, [3, 4, 5])
        XCTAssertEqual(queue.dropped, 4)
        XCTAssertEqual(Set(storage.files.keys), [3, 4, 5])
    }

    func testEvictionThatCannotRemoveTheFileKeepsItPending() throws {
        let storage = AssistantMemoryQueueStorage()
        let queue = try AssistantEventQueue(storage: storage, cap: 2, lastSeq: 0, dropped: 0)
        for _ in 0..<2 { _ = try queue.append { Data("\($0)".utf8) } }
        storage.failRemoves = true
        let blocked = try queue.append { Data("\($0)".utf8) }
        XCTAssertEqual(blocked.evicted, [])
        XCTAssertEqual(queue.pending, [1, 2, 3])
        XCTAssertEqual(queue.dropped, 0)
        storage.failRemoves = false
        let freed = try queue.append { Data("\($0)".utf8) }
        XCTAssertEqual(freed.evicted, [1, 2])
        XCTAssertEqual(queue.pending, [3, 4])
        XCTAssertEqual(queue.dropped, 2)
        // After a restart the disk and the count agree: nothing reported dropped comes back.
        XCTAssertEqual(try AssistantEventQueue(storage: storage, cap: 2, lastSeq: 4, dropped: 2).pending, [3, 4])
    }

    func testDefaultCapIs5000() {
        XCTAssertEqual(AssistantEventQueue.defaultCap, 5000)
    }

    func testSeqSurvivesRestartEvenIfTheCounterWasNotSaved() throws {
        let storage = AssistantMemoryQueueStorage()
        let first = try AssistantEventQueue(storage: storage, lastSeq: 0, dropped: 0)
        for _ in 0..<3 { _ = try first.append { Data("\($0)".utf8) } }
        // The process died before watermarks.json recorded seq 3: the files say so.
        let second = try AssistantEventQueue(storage: storage, lastSeq: 1, dropped: 0)
        XCTAssertEqual(second.lastSeq, 3)
        XCTAssertEqual(second.pending, [1, 2, 3])
        XCTAssertEqual(try second.append { _ in Data() }.seq, 4)
        // Everything acknowledged: the saved counter still keeps seq monotonic.
        _ = second.ack(4)
        let third = try AssistantEventQueue(storage: storage, lastSeq: 4, dropped: 0)
        XCTAssertEqual(try third.append { _ in Data() }.seq, 5)
    }

    func testReplaceOnlyTouchesPendingEvents() throws {
        let storage = AssistantMemoryQueueStorage()
        let queue = try AssistantEventQueue(storage: storage, lastSeq: 0, dropped: 0)
        _ = try queue.append { _ in Data("a".utf8) }
        XCTAssertTrue(try queue.replace(seq: 1, data: Data("b".utf8)))
        XCTAssertEqual(storage.files[1], Data("b".utf8))
        _ = queue.ack(1)
        XCTAssertFalse(try queue.replace(seq: 1, data: Data("c".utf8)))
        XCTAssertNil(storage.files[1])
    }

    // MARK: watermarks

    func testCaptureSinceAndWatermarkGateConsideration() {
        var marks = AssistantWatermarks(captureSince: 1000)
        XCTAssertFalse(marks.shouldConsider(chat: 5, messageId: 10, date: 999))
        XCTAssertTrue(marks.shouldConsider(chat: 5, messageId: 10, date: 1000))
        marks.markEmitted(chat: 5, messageId: 10)
        XCTAssertFalse(marks.shouldConsider(chat: 5, messageId: 10, date: 1000))
        marks.advance(chat: 5, to: 20)
        XCTAssertFalse(marks.shouldConsider(chat: 5, messageId: 15, date: 2000))
        XCTAssertTrue(marks.shouldConsider(chat: 5, messageId: 21, date: 2000))
        XCTAssertNil(marks.emitted[5])
    }

    func testRescanFloorOnlyForChatsWithNewMessages() {
        var marks = AssistantWatermarks()
        XCTAssertEqual(marks.rescanFloor(chat: 1, topMessageId: 50), 0)
        marks.advance(chat: 1, to: 50)
        XCTAssertNil(marks.rescanFloor(chat: 1, topMessageId: 50))
        XCTAssertEqual(marks.rescanFloor(chat: 1, topMessageId: 60), 50)
        marks.advance(chat: 1, to: 40)
        XCTAssertEqual(marks.chats[1], 50)
    }

    func testEmittedAboveWatermarkSurvivesAdvanceBelowIt() {
        var marks = AssistantWatermarks()
        marks.markEmitted(chat: 1, messageId: 70)
        marks.advance(chat: 1, to: 60)
        XCTAssertEqual(marks.emitted[1], [70])
        XCTAssertFalse(marks.shouldConsider(chat: 1, messageId: 70, date: 0))
    }

    func testEmittedIsBounded() {
        var marks = AssistantWatermarks()
        for id in 1...Int32(AssistantWatermarks.emittedPerChatCap + 10) { marks.markEmitted(chat: 1, messageId: id) }
        XCTAssertEqual(marks.emitted[1]?.count, AssistantWatermarks.emittedPerChatCap)
        XCTAssertEqual(marks.emitted[1]?.first, 11)
    }

    func testWatermarksPersistAcrossRestartWithoutReemitting() throws {
        var marks = AssistantWatermarks(seq: 9, dropped: 1, captureSince: 100, lastRescanAtMs: 123_456)
        marks.advance(chat: -1_000_000_000_042, to: 300)
        marks.markEmitted(chat: 8, messageId: 5)
        let reloaded = AssistantWatermarks(json: try AssistantJSON.parse(marks.json.encoded()))
        XCTAssertEqual(reloaded, marks)
        XCTAssertNil(reloaded.rescanFloor(chat: -1_000_000_000_042, topMessageId: 300))
        XCTAssertFalse(reloaded.shouldConsider(chat: 8, messageId: 5, date: 200))
    }

    func testDamagedWatermarksReadAsDefaults() throws {
        let reloaded = AssistantWatermarks(json: try AssistantJSON.parse(#"{"seq":"x","chats":{"a":1,"5":"y","6":7},"emitted":[]}"#))
        XCTAssertEqual(reloaded.seq, 0)
        XCTAssertEqual(reloaded.chats, [6: 7])
        XCTAssertEqual(reloaded.emitted, [:])
    }

    func testRescanSchedule() {
        XCTAssertEqual(AssistantWatermarks.rescanFirstDelaySeconds, 30)
        XCTAssertEqual(AssistantWatermarks.rescanIntervalSeconds, 600)
        XCTAssertEqual(AssistantWatermarks.rescanPerChatLimit, 500)
    }

    func testWatermarksRecordTheirAccountAndReboundKeepsOnlyTheCounters() throws {
        var marks = AssistantWatermarks(accountPeerId: 111, seq: 40, dropped: 3, captureSince: 100, lastRescanAtMs: 5)
        marks.advance(chat: 1, to: 50_000)
        marks.markEmitted(chat: 2, messageId: 9)
        let reloaded = AssistantWatermarks(json: try AssistantJSON.parse(marks.json.encoded()))
        XCTAssertEqual(reloaded.accountPeerId, 111)
        let other = reloaded.rebound(to: 222)
        XCTAssertEqual(other, AssistantWatermarks(accountPeerId: 222, seq: 40, dropped: 3))
        // Account B's chat with the same peer: ids around 300 are not hidden behind A's 50000.
        XCTAssertTrue(other.shouldConsider(chat: 1, messageId: 300, date: 0))
        XCTAssertNil(reloaded.rebound(to: nil).accountPeerId)
    }

    func testFileWithoutAccountBelongsToNoAccount() throws {
        XCTAssertNil(AssistantWatermarks(json: try AssistantJSON.parse(#"{"seq":3,"chats":{"6":7}}"#)).accountPeerId)
    }

    // MARK: rescan target

    private let now: Int64 = 1_800_000_000

    private func scanned(_ ids: ClosedRange<Int32>, date: Int32 = 1_800_000_000, unreadable: Set<Int32> = []) -> [AssistantWatermarks.Scanned] {
        return ids.map { AssistantWatermarks.Scanned(id: $0, date: date, readable: !unreadable.contains($0)) }
    }

    func testRescanTargetIsTopWhenEverythingWasRead() {
        XCTAssertEqual(AssistantWatermarks.rescanTarget(top: 60, lowerBound: 50, scanned: scanned(51...60), holes: IndexSet(), now: now), 60)
    }

    func testRescanTargetStopsBelowTheOldestUnreadableMessage() {
        let target = AssistantWatermarks.rescanTarget(top: 60, lowerBound: 50, scanned: scanned(51...60, unreadable: [55, 58]),
                                                      holes: IndexSet(), now: now)
        XCTAssertEqual(target, 54)
    }

    func testUnreadableMessageOlderThanThePinWindowDoesNotHoldTheWatermark() {
        let old = Int32(now - AssistantWatermarks.pinSeconds - 1)
        let target = AssistantWatermarks.rescanTarget(top: 60, lowerBound: 50, scanned: scanned(51...60, date: old, unreadable: [55]),
                                                      holes: IndexSet(), now: now)
        XCTAssertEqual(target, 60)
    }

    func testRescanTargetStopsBelowAHoleInTheRange() {
        // Stored: 41...50 (old watermark 50) and 901...1000; the gap 51...900 is a hole.
        let target = AssistantWatermarks.rescanTarget(top: 1000, lowerBound: 50, scanned: scanned(901...1000),
                                                      holes: IndexSet(integersIn: 51...900), now: now)
        XCTAssertEqual(target, 50)
    }

    func testHolesOutsideTheRangeAreIgnored() {
        var holes = IndexSet(integersIn: 1...40)
        holes.insert(integersIn: 2000...3000)
        XCTAssertEqual(AssistantWatermarks.rescanTarget(top: 60, lowerBound: 50, scanned: scanned(51...60), holes: holes, now: now), 60)
    }

    func testHoleBelowOldMessagesDoesNotHoldTheWatermark() {
        let old = Int32(now - AssistantWatermarks.pinSeconds - 60)
        let target = AssistantWatermarks.rescanTarget(top: 1000, lowerBound: 50, scanned: scanned(901...1000, date: old),
                                                      holes: IndexSet(integersIn: 51...900), now: now)
        XCTAssertEqual(target, 1000)
    }

    func testRescanTargetNeverGoesBelowTheLowerBound() {
        let target = AssistantWatermarks.rescanTarget(top: 60, lowerBound: 50, scanned: scanned(51...60, unreadable: [51]),
                                                      holes: IndexSet(integersIn: 45...52), now: now)
        XCTAssertEqual(target, 50)
    }

    // MARK: context policy

    func testContextAfterSeedKeepsWhatCameWithinTwoMinutes() {
        let mention: Int32 = 10_000
        let dates: [Int32] = [mention + 1, mention + 60, mention + 120, mention + 121, mention + 3600]
        XCTAssertEqual(AssistantContextPolicy.selectAfter(dates, date: { $0 }, mentionDate: mention), [mention + 1, mention + 60, mention + 120])
        let many = (1...40).map { mention + Int32($0) }
        XCTAssertEqual(AssistantContextPolicy.selectAfter(many, date: { $0 }, mentionDate: mention).count, AssistantContextPolicy.afterMax)
    }

    func testContextBeforeIsThirtyAndTwoHours() {
        let dates: [Int32] = (0..<50).map { 10_000 + Int32($0) * 60 }
        let mention: Int32 = 10_000 + 50 * 60
        let picked = AssistantContextPolicy.selectBefore(dates, date: { $0 }, mentionDate: mention)
        XCTAssertEqual(picked.count, 30)
        XCTAssertEqual(picked.last, dates.last)
        let sparse: [Int32] = [mention - 3 * 3600, mention - 7200, mention - 10]
        XCTAssertEqual(AssistantContextPolicy.selectBefore(sparse, date: { $0 }, mentionDate: mention), [mention - 7200, mention - 10])
    }
}
