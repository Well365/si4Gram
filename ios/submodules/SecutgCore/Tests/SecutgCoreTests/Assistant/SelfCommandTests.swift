import XCTest
@testable import SecutgCore

/// PLAN.md 3.45.7 "只认自己的指令" and the 3.45.2 `command` event: the predicate, the parse, the event's shape, the
/// send-side loop guard and the durable path it shares with mentions.
final class SelfCommandTests: XCTestCase {
    private func own(_ text: String) -> Bool {
        return SelfCommand.isSelfCommand(chatIsSavedMessages: true, authorIsSelf: true, isOutgoing: true, text: text)
    }

    // MARK: predicate

    func testOwnSavedMessagesLinesThatAreCommands() {
        for text in ["/secu", "/secu status", "  /secu inbox  ", "/secu remind 18:00 交周报", "\n/secu\tpause", "/secu\nresume",
                     "/secu mute 2020 2h"] {
            XCTAssertTrue(own(text), text)
        }
    }

    func testOwnSavedMessagesLinesThatAreNot() {
        for text in ["", "   ", "secu status", "/secux", "/secustatus", "/SECU status", "/Secu", "请 /secu status", "//secu status",
                     "/secu@bot status", "／secu status", "/sec u"] {
            XCTAssertFalse(own(text), text)
        }
    }

    func testOnlySavedMessagesOnlyThisAccountOnlyOutgoingNeverForwarded() {
        let text = "/secu status"
        XCTAssertFalse(SelfCommand.isSelfCommand(chatIsSavedMessages: false, authorIsSelf: true, isOutgoing: true, text: text))
        XCTAssertFalse(SelfCommand.isSelfCommand(chatIsSavedMessages: true, authorIsSelf: false, isOutgoing: true, text: text))
        XCTAssertFalse(SelfCommand.isSelfCommand(chatIsSavedMessages: true, authorIsSelf: true, isOutgoing: false, text: text))
        XCTAssertFalse(SelfCommand.isSelfCommand(chatIsSavedMessages: true, authorIsSelf: true, isOutgoing: true, isForwarded: true, text: text))
        XCTAssertFalse(SelfCommand.isSelfCommand(chatIsSavedMessages: false, authorIsSelf: false, isOutgoing: false, text: text))
        XCTAssertTrue(SelfCommand.isSelfCommand(chatIsSavedMessages: true, authorIsSelf: true, isOutgoing: true, isForwarded: false, text: text))
    }

    // MARK: parse

    func testParseSplitsNameAndArgs() {
        XCTAssertEqual(SelfCommand.parse("/secu"), AssistantSelfCommand(name: "", args: ""))
        XCTAssertEqual(SelfCommand.parse("/secu   "), AssistantSelfCommand(name: "", args: ""))
        XCTAssertEqual(SelfCommand.parse("/secu status"), AssistantSelfCommand(name: "status", args: ""))
        XCTAssertEqual(SelfCommand.parse("/secu STATUS"), AssistantSelfCommand(name: "status", args: ""))
        XCTAssertEqual(SelfCommand.parse("/secu  remind   18:00  交 周报 "), AssistantSelfCommand(name: "remind", args: "18:00  交 周报"))
        XCTAssertEqual(SelfCommand.parse("/secu remind 明天\n第一行\n第二行"), AssistantSelfCommand(name: "remind", args: "明天\n第一行\n第二行"))
        XCTAssertEqual(SelfCommand.parse("/secu\nmute 2020 2h"), AssistantSelfCommand(name: "mute", args: "2020 2h"))
        XCTAssertEqual(SelfCommand.parse("/secu 状态"), AssistantSelfCommand(name: "状态", args: ""))
        XCTAssertNil(SelfCommand.parse("/secux"))
        XCTAssertNil(SelfCommand.parse("x /secu"))
    }

    // MARK: send loop guard

    func testTheAssistantCannotSendACommandIntoSavedMessages() {
        XCTAssertEqual(SelfCommand.sendRefusal(chatIsSavedMessages: true, text: "/secu status")?.code, .refused)
        XCTAssertEqual(SelfCommand.sendRefusal(chatIsSavedMessages: true, text: " /secu")?.code, .refused)
        XCTAssertNil(SelfCommand.sendRefusal(chatIsSavedMessages: true, text: "未处理 3 条；用法：/secu inbox"))
        XCTAssertNil(SelfCommand.sendRefusal(chatIsSavedMessages: false, text: "/secu status"))
    }

    // MARK: event

    static let savedMessages = AssistantChat(peerId: 7_654_321, telegramId: 7_654_321, kind: .user, title: "张三", username: "zhangsan_dev",
                                             encryption: .v2)
    static let me = AssistantPerson(peerId: 7_654_321, telegramId: 7_654_321, name: "张三", username: "zhangsan_dev")

    static func event(seq: Int64, id: Int32 = 5001, text: String = "/secu remind 18:00 交周报") -> AssistantCommandEvent {
        return AssistantCommandEvent(
            seq: seq, atMs: 1_790_000_401_500, chat: savedMessages,
            message: AssistantMessage(id: id, date: 1_790_000_400, sender: me, text: text, entities: [], wasEncrypted: true, replyToMessageId: nil),
            command: SelfCommand.parse(text)!)
    }

    func testEventCarriesEveryField() throws {
        let line = Self.event(seq: 18).line
        XCTAssertFalse(line.contains("\n"))
        let parsed = try AssistantJSON.parse(line)
        XCTAssertEqual(parsed["event"], .string("command"))
        let data = try XCTUnwrap(parsed["data"]?.objectValue)
        XCTAssertEqual(Set(data.keys), ["seq", "event_id", "at_ms", "chat", "message", "command"])
        XCTAssertEqual(data["event_id"], .string("c-7654321-5001"))
        XCTAssertEqual(data["seq"], .int(18))
        XCTAssertEqual(data["command"], .object(["name": .string("remind"), "args": .string("18:00 交周报")]))
        XCTAssertEqual(Set(data["message"]?.objectValue?.keys ?? [:].keys), ["id", "date", "sender", "text", "entities", "was_encrypted"])
        XCTAssertEqual(data["chat"]?["peer_id"], data["message"]?["sender"]?["peer_id"], "Saved Messages is the account's own chat")
    }

    func testCommandAndMentionIdsNeverCollide() {
        XCTAssertNotEqual(AssistantCommandEvent.eventId(chatPeerId: 1, messageId: 2), AssistantMentionEvent.eventId(chatPeerId: 1, messageId: 2))
    }

    /// The command rides the mention's durable path: one seq counter, queue file before push, replay on
    /// subscribe while unacknowledged, gone after ack.
    func testCommandSharesTheQueueAndSeqWithMentions() throws {
        let storage = AssistantMemoryQueueStorage()
        var pushed: [String] = []
        let hub = AssistantEventHub(queue: try AssistantEventQueue(storage: storage, lastSeq: 17, dropped: 0)) { _, line in
            pushed.append(line)
            storage.note("push")
        }
        hub.subscribe(1, requestId: .string("s"), since: 17)
        storage.note("--")
        let published = try hub.publish { Self.event(seq: $0) }
        XCTAssertEqual(published.event.seq, 18)
        XCTAssertEqual(storage.log.split(separator: "--").last.map(Array.init), ["write:18", "push"])
        XCTAssertEqual(pushed.last, published.event.line)

        // The assistant was down: a new subscriber gets it replayed until it is acked.
        pushed.removeAll()
        hub.subscribe(2, requestId: .string("s2"), since: 0)
        XCTAssertEqual(pushed.count, 2)
        XCTAssertEqual(pushed.last, published.event.line)
        XCTAssertEqual(hub.ack(18), [18])
        XCTAssertEqual(hub.queue.pendingCount, 0)
        XCTAssertEqual(hub.queue.lastSeq, 18)
    }
}
