import XCTest
@testable import SecutgCore

/// Implementation plan C1.6 / C1.3 (review 2026-09-30): the ordering the glue relies on, tested on the real hub —
/// publish writes before it pushes, subscribe answers first and replays only what is pending after `since`, a live
/// event is not doubled by the replay, and a replayed file carries the folded `context_after`.
final class AssistantHubTests: XCTestCase {
    private var storage: AssistantMemoryQueueStorage!
    private var pushed: [(Int, String)] = []
    private var hub: AssistantEventHub!

    override func setUpWithError() throws {
        storage = AssistantMemoryQueueStorage()
        pushed = []
        let queue = try AssistantEventQueue(storage: storage, lastSeq: 0, dropped: 0)
        hub = AssistantEventHub(queue: queue) { [unowned self] subscriber, line in
            self.pushed.append((subscriber, line))
            // The push lands in the same log as the storage operations, so their order is observable.
            self.storage.note("push:\(subscriber)")
        }
    }

    private func event(_ seq: Int64, message id: Int32 = 100) -> AssistantMentionEvent {
        let sender = AssistantPerson(peerId: 7, telegramId: 7, name: "A", username: nil)
        let chat = AssistantChat(peerId: 42, telegramId: -42, kind: .group, title: "G", username: nil, encryption: .none)
        return AssistantMentionEvent(seq: seq, atMs: 1, chat: chat,
                                     message: AssistantMessage(id: id, date: 1, sender: sender, text: "@me", entities: [], wasEncrypted: false, replyToMessageId: nil),
                                     mention: AssistantMention(kind: .username, offset: 0, length: 3), replyChain: [], contextBefore: [])
    }

    private func decoded(_ line: String) throws -> AssistantJSON {
        return try AssistantJSON.parse(Data(line.utf8))
    }

    func testPublishWritesTheFileBeforeAnySubscriberIsPushed() throws {
        hub.subscribe(1, requestId: .string("s"), since: 0)
        storage.note("--")
        _ = try hub.publish { self.event($0) }
        XCTAssertEqual(storage.log.split(separator: "--").last.map(Array.init), ["write:1", "push:1"])
    }

    func testFailedWritePushesNothing() throws {
        hub.subscribe(1, requestId: .string("s"), since: 0)
        pushed.removeAll()
        storage.failWrites = true
        XCTAssertThrowsError(try hub.publish { self.event($0) })
        XCTAssertTrue(pushed.isEmpty)
        XCTAssertEqual(hub.queue.lastSeq, 0)
    }

    func testSubscribeAnswersFirstThenReplaysOnlyUnackedAfterSince() throws {
        for id in 1...4 { _ = try hub.publish { self.event($0, message: Int32(id)) } }
        hub.ack(1)
        hub.subscribe(9, requestId: .string("req"), since: 2)
        XCTAssertEqual(pushed.count, 3)
        let answer = try decoded(pushed[0].1)
        XCTAssertEqual(answer["id"], .string("req"))
        XCTAssertEqual(answer["result"]?["replaying"], .int(2))
        XCTAssertEqual(answer["result"]?["last_event_seq"], .int(4))
        XCTAssertEqual(try pushed[1...].map { try decoded($0.1)["data"]?["seq"] }, [.int(3), .int(4)])
    }

    func testLiveEventsAfterSubscribeAreNotDoubledByTheReplay() throws {
        _ = try hub.publish { self.event($0, message: 1) }
        hub.subscribe(1, requestId: .int(1), since: 0)
        _ = try hub.publish { self.event($0, message: 2) }
        let seqs = try pushed.dropFirst().map { try decoded($0.1)["data"]?["seq"] }
        XCTAssertEqual(seqs, [.int(1), .int(2)])
    }

    func testReplayedEventCarriesTheFoldedContextAfter() throws {
        let published = try hub.publish { self.event($0) }
        var updated = published.event
        updated.contextAfter = [AssistantMessage(id: 101, date: 2, sender: updated.message.sender, text: "details",
                                                 entities: [], wasEncrypted: false, replyToMessageId: nil)]
        hub.publishUpdate(updated)
        hub.subscribe(3, requestId: .null, since: 0)
        let replayed = try decoded(pushed.last!.1)
        XCTAssertEqual(replayed["event"], .string("mention"))
        XCTAssertEqual(replayed["data"]?["context_after"]?.arrayValue?.count, 1)
    }

    func testUnsubscribedConnectionIsNotPushed() throws {
        hub.subscribe(1, requestId: .null, since: 0)
        hub.unsubscribe(1)
        pushed.removeAll()
        _ = try hub.publish { self.event($0) }
        XCTAssertTrue(pushed.isEmpty)
        XCTAssertEqual(hub.queue.pending, [1])
    }

    func testAckedEventIsNotReplayed() throws {
        _ = try hub.publish { self.event($0) }
        XCTAssertEqual(hub.ack(1), [1])
        hub.subscribe(1, requestId: .null, since: 0)
        XCTAssertEqual(pushed.count, 1)
    }
}
