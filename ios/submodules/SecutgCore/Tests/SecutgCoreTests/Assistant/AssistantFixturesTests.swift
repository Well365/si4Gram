import XCTest
@testable import SecutgCore

/// The protocol fixtures the conformance step replays against the assistant (docs/secutg/assistant-protocol-fixtures.json).
/// Every line is produced by the encoder the client uses. Run with SECUTG_ASSISTANT_FIXTURES_OUT=<path> to write the
/// file; without it the test only checks that every line parses back and covers every op.
///
/// A fixture marked `pending` is a line this side already sends but the assistant does not model yet. It goes to
/// `<name>.pending.json` beside the file instead of into it, so the assistant's conformance test — which requires
/// every event in the file to decode — keeps passing until the assistant adopts it; adopting means setting `pending`
/// back to false here and regenerating. None is pending today (`event.command`, PLAN.md 3.45.7, was adopted by the
/// assistant on 2026-10-01).
final class AssistantFixturesTests: XCTestCase {
    struct Fixture {
        let name: String
        let direction: String
        let line: String
        var pending = false
    }

    static let chat = AssistantChat(peerId: 9_824_502_482, telegramId: -1_001_234_567_890,
                                    kind: .supergroup, title: "2020", username: nil, encryption: .v2)
    static let alice = AssistantPerson(peerId: 1_234_567, telegramId: 1_234_567, name: "Alice Chen", username: "alice")
    static let me = AssistantPerson(peerId: 7_654_321, telegramId: 7_654_321, name: "张三", username: "zhangsan_dev")
    /// A second account logged in on the same Mac (PLAN.md 3.45.2 amendment 2026-10-02), its switch off.
    static let other = AssistantPerson(peerId: 7_654_399, telegramId: 7_654_399, name: "Rob", username: nil)

    static func message(_ id: Int32, _ date: Int32, _ sender: AssistantPerson, _ text: String,
                        entities: [AssistantEntity] = [], encrypted: Bool = true, replyTo: Int32? = nil,
                        media: [AssistantMediaItem] = []) -> AssistantMessage {
        return AssistantMessage(id: id, date: date, sender: sender, text: text, entities: entities, wasEncrypted: encrypted,
                                replyToMessageId: replyTo, media: media)
    }

    /// 2026-10-10: a photo's description on a message (`media`), and what the `media` op hands back for it.
    static let screenshot = AssistantMediaItem(index: 0, kind: .photo, mime: "image/jpeg", size: 160, width: 1, height: 1)
    /// A 1×1 white JPEG, small enough to keep the fixture readable.
    static let screenshotBytes = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==")!

    static var mentionEvent: AssistantMentionEvent {
        let trigger = message(1042, 1_790_000_300, alice, "@zhangsan_dev 看下 PROJ-123 这个报错",
                              entities: [AssistantEntity(type: "mention", offset: 0, length: 13)], replyTo: 1040)
        return AssistantMentionEvent(
            seq: 17, atMs: 1_790_000_301_250, chat: chat, message: trigger,
            mention: AssistantMention(kind: .username, offset: 0, length: 13),
            replyChain: [message(1040, 1_790_000_200, me, "登录页偶发 500", encrypted: true)],
            contextBefore: [
                message(1039, 1_790_000_100, alice, AssistantPlaceholder.withCaption(.photo, caption: "截图"), media: [screenshot]),
                message(1040, 1_790_000_200, me, "登录页偶发 500"),
                message(1041, 1_790_000_250, alice, AssistantPlaceholder.control.rawValue, encrypted: false),
            ], accountPeerId: me.peerId)
    }

    /// PLAN.md 3.45.7: `/secu remind …` written by this account in its own Saved Messages (on v2).
    static var commandEvent: AssistantCommandEvent {
        let text = "/secu remind 18:00 交周报"
        let savedMessages = AssistantChat(peerId: me.peerId, telegramId: me.telegramId, kind: .user, title: me.name,
                                          username: me.username, encryption: .v2)
        return AssistantCommandEvent(seq: 18, atMs: 1_790_000_401_500, chat: savedMessages,
                                     message: message(5001, 1_790_000_400, me, text), command: SelfCommand.parse(text)!,
                                     accountPeerId: me.peerId)
    }

    static func request(_ name: String, _ op: AssistantOp, _ params: [String: AssistantJSON]) -> Fixture {
        return Fixture(name: name, direction: "request", line: AssistantLine.request(id: "req-\(op.rawValue)", op: op, params: params))
    }

    static func ok(_ name: String, _ op: AssistantOp, _ result: [String: AssistantJSON]) -> Fixture {
        return Fixture(name: name, direction: "response", line: AssistantLine.ok(id: .string("req-\(op.rawValue)"), result: result))
    }

    static func error(_ name: String, _ id: AssistantJSON, _ failure: AssistantFailure) -> Fixture {
        return Fixture(name: name, direction: "response", line: AssistantLine.error(id: id, failure))
    }

    static var all: [Fixture] {
        let status = AssistantResults.Status(account: me, online: true, captureEnabled: true, queuePending: 2, dropped: 0,
                                             lastEventSeq: 17, lastRescanAt: 1_790_000_000, build: "12.0 (4321) abc1234 · 2026-09-30",
                                             accounts: AssistantAccountEntry.list([(me, true), (other, false)], activePeerId: me.peerId),
                                             activeAccountPeerId: me.peerId)
        let directory = AssistantResults.directory(
            generatedAt: 1_790_000_400,
            chats: [(chat, false),
                    (AssistantChat(peerId: 8_599_811_135, telegramId: -1_000_009_876_543, kind: .supergroup, title: "2020",
                                   username: "team2020", encryption: .none), true),
                    (AssistantChat(peerId: 1_234_567, telegramId: 1_234_567, kind: .user, title: "Alice Chen",
                                   username: "alice", encryption: .v1), false),
                    (AssistantChat(peerId: 4_294_967_851, telegramId: -555, kind: .group, title: "家人", username: nil,
                                   encryption: .group), false),
                    (AssistantChat(peerId: 8_589_935_369, telegramId: -1_000_000_000_777, kind: .channel, title: "公告",
                                   username: "news", encryption: .none), true)],
            contacts: [AssistantResults.Contact(person: alice, isContact: true),
                       AssistantResults.Contact(person: AssistantPerson(peerId: 42, telegramId: 42, name: "Bob", username: nil), isContact: false)])
        let event = mentionEvent
        var updated = event
        updated.contextAfter = [message(1043, 1_790_000_330, alice, "日志在附件里")]
        let chatId = AssistantJSON.int(chat.peerId)
        let folder = AssistantFolder(id: 5, title: "后端", emoticon: nil, peerIds: [chat.peerId, alice.peerId, me.peerId],
                                     hasRules: false, shared: false)
        return [
            request("hello.request", .hello, ["client": .string("secutg-mate"), "version": .string("0.1.0")]),
            ok("hello.ok", .hello, AssistantResults.hello(build: "12.0 (4321) abc1234 · 2026-09-30")),
            error("hello.error.bad_params", .string("req-hello"), AssistantFailure(.badParams, "version must be a string")),
            request("status.request", .status, [:]),
            ok("status.ok", .status, AssistantResults.status(status)),
            error("status.error.not_ready", .string("req-status"), AssistantFailure(.notReady, "no account is signed in")),
            request("directory.request", .directory, [:]),
            ok("directory.ok", .directory, directory),
            error("directory.error.not_ready", .string("req-directory"), AssistantFailure(.notReady, "no account is signed in")),
            request("subscribe.request", .subscribe, ["since": .int(15)]),
            ok("subscribe.ok", .subscribe, AssistantResults.subscribe(replaying: 2, lastEventSeq: 17)),
            error("subscribe.error.bad_params", .string("req-subscribe"), AssistantFailure(.badParams, "since must be an integer in range")),
            Fixture(name: "event.mention", direction: "event", line: event.line),
            Fixture(name: "event.mention.update", direction: "event", line: updated.updateLine),
            Fixture(name: "event.command", direction: "event", line: commandEvent.line),
            request("ack.request", .ack, ["seq": .int(17)]),
            ok("ack.ok", .ack, AssistantResults.empty),
            error("ack.error.bad_params", .string("req-ack"), AssistantFailure(.badParams, "seq must be an integer in range")),
            request("context.request", .context, ["chat_peer_id": chatId, "message_id": .int(1042), "before": .int(2), "after": .int(1)]),
            ok("context.ok", .context, AssistantResults.context(messages: [event.contextBefore[1], event.contextBefore[2], event.message, updated.contextAfter[0]])),
            error("context.error.not_found", .string("req-context"), AssistantFailure(.notFound, "message not found")),
            error("context.error.locked", .string("req-context"), AssistantFailure(.locked, "group password is not unlocked")),
            request("history.request", .history, ["chat_peer_id": chatId, "since": .int(1_790_000_000), "limit": .int(200)]),
            ok("history.ok", .history, AssistantResults.history(messages: [event.contextBefore[1], event.contextBefore[2], event.message, updated.contextAfter[0]], truncated: false)),
            error("history.error.not_found", .string("req-history"), AssistantFailure(.notFound, "chat not found")),
            error("history.error.locked", .string("req-history"), AssistantFailure(.locked, "group password is not unlocked")),
            request("folders.request", .folders, [:]),
            ok("folders.ok", .folders, AssistantResults.folders([folder,
                AssistantFolder(id: 2, title: "工作", emoticon: "💼", peerIds: [], hasRules: true, shared: false)])),
            error("folders.error.not_ready", .string("req-folders"), AssistantFailure(.notReady, "secuTG runtime is not ready")),
            request("folder_update.request", .folderUpdate, ["action": .string("create"), "title": .string("后端"),
                                                             "peer_ids": .array([chatId, .int(alice.peerId)])]),
            request("folder_update.request.add", .folderUpdate, ["action": .string("add"), "folder_id": .int(5),
                                                                 "peer_ids": .array([.int(me.peerId)])]),
            request("folder_update.request.delete", .folderUpdate, ["action": .string("delete"), "folder_id": .int(5)]),
            ok("folder_update.ok", .folderUpdate, AssistantResults.folder(folder)),
            ok("folder_update.ok.deleted", .folderUpdate, AssistantResults.folderDeleted(id: 5)),
            error("folder_update.error.not_found", .string("req-folder_update"), AssistantFailure(.notFound, "folder not found")),
            error("folder_update.error.refused", .string("req-folder_update"), AssistantFailure(.refused, "shared folders are edited in Telegram")),
            error("folder_update.error.too_long", .string("req-folder_update"), AssistantFailure(.tooLong, "a folder holds at most 200 chats")),
            request("media.request", .media, ["chat_peer_id": chatId, "message_id": .int(1039), "index": .int(0), "max_bytes": .int(5_242_880)]),
            ok("media.ok", .media, AssistantResults.media(mime: "image/jpeg", data: screenshotBytes)),
            error("media.error.not_found", .string("req-media"), AssistantFailure(.notFound, "message has no media at that index")),
            error("media.error.unsupported", .string("req-media"), AssistantFailure(.unsupported, "media is not a picture")),
            error("media.error.too_large", .string("req-media"), AssistantFailure(.tooLarge, "media is 9000000 bytes, more than max_bytes 5242880")),
            error("media.error.timeout", .string("req-media"), AssistantFailure(.timeout, "media did not download in time")),
            error("media.error.locked", .string("req-media"), AssistantFailure(.locked, "group password is not unlocked")),
            error("media.error.not_ready", .string("req-media"), AssistantFailure(.notReady, "secuTG runtime is not ready")),
            request("send.request", .send, ["chat_peer_id": chatId, "text": .string("收到，我看一下"), "reply_to_message_id": .int(1042)]),
            request("send.request.encrypted", .send, ["chat_peer_id": chatId, "text": .string("收到"), "encryption": .string("encrypted")]),
            request("send.request.plaintext", .send, ["chat_peer_id": .int(8_599_811_135), "text": .string("收到"), "encryption": .string("plaintext")]),
            ok("send.ok", .send, AssistantResults.send(localMessageId: 1044)),
            ok("send.ok.direct", .send, AssistantResults.send(localMessageId: 0)),
            error("send.error.locked", .string("req-send"), AssistantFailure(.locked, "group password is not unlocked")),
            error("send.error.no_key", .string("req-send"), AssistantFailure(.noKey, "chat requires a key and has none")),
            error("send.error.refused", .string("req-send"), AssistantFailure(.refused, "protocol lines, invites and the wipe phrase cannot be sent")),
            error("send.error.refused.plaintext", .string("req-send"), AssistantFailure(.refused, "plaintext is not allowed in a chat that encrypts")),
            error("send.error.no_key.encrypted", .string("req-send"), AssistantFailure(.noKey, "chat has no key to encrypt with")),
            error("send.error.not_found", .string("req-send"), AssistantFailure(.notFound, "chat not found")),
            error("send.error.too_long", .string("req-send"), AssistantFailure(.tooLong, "text is longer than 4096")),
            error("send.error.not_ready", .string("req-send"), AssistantFailure(.notReady, "secuTG runtime is not ready")),
            request("read.request", .read, ["chat_peer_id": chatId, "message_id": .int(1042)]),
            ok("read.ok", .read, AssistantResults.empty),
            error("read.error.not_found", .string("req-read"), AssistantFailure(.notFound, "chat not found")),
            request("open.request", .open, ["chat_peer_id": chatId, "message_id": .int(1042), "account_peer_id": .int(me.peerId)]),
            request("open.request.chat_only", .open, ["chat_peer_id": chatId]),
            ok("open.ok", .open, AssistantResults.empty),
            error("open.error.other_account", .string("req-open"), AssistantFailure(.otherAccount, "the client's current account is different")),
            error("open.error.not_found", .string("req-open"), AssistantFailure(.notFound, "chat not found")),
            Fixture(name: "unknown_op.request", direction: "request", line: #"{"id":"req-x","op":"unpair","params":{}}"#),
            error("unknown_op.error", .string("req-x"), AssistantFailure(.unknownOp, "unknown op")),
            Fixture(name: "bad_json.request", direction: "request", line: #"{"id":"req-y","op":"#),
            error("bad_json.error", .null, AssistantFailure(.badParams, "invalid JSON")),
            error("internal.error", .string("req-status"), AssistantFailure(.internal, "internal error")),
        ]
    }

    func testEveryFixtureLineIsOneValidJSONObject() throws {
        for fixture in Self.all where fixture.name != "bad_json.request" {
            XCTAssertFalse(fixture.line.contains("\n"), fixture.name)
            XCTAssertNotNil(try AssistantJSON.parse(fixture.line).objectValue, fixture.name)
        }
    }

    func testEveryOpHasARequestASuccessAndAnError() {
        let names = Set(Self.all.map { $0.name })
        for op in AssistantOp.allCases {
            XCTAssertTrue(names.contains("\(op.rawValue).request"), op.rawValue)
            XCTAssertTrue(names.contains("\(op.rawValue).ok"), op.rawValue)
            XCTAssertTrue(names.contains { $0.hasPrefix("\(op.rawValue).error.") }, op.rawValue)
        }
        let codes = Set(Self.all.compactMap { try? AssistantJSON.parse($0.line)["error"]?["code"]?.stringValue })
        XCTAssertEqual(codes, Set(AssistantErrorCode.allCases.map { $0.rawValue }))
    }

    func testRequestFixturesDecodeToCommands() {
        for fixture in Self.all where fixture.direction == "request" && fixture.name.hasSuffix(".request")
            && !fixture.name.hasPrefix("unknown_op") && !fixture.name.hasPrefix("bad_json") {
            if case .failure = AssistantRequestDecoder.decode(line: Data(fixture.line.utf8)).result {
                XCTFail(fixture.name)
            }
        }
    }

    func testMentionEventCarriesEveryField() throws {
        let data = try XCTUnwrap(try AssistantJSON.parse(Self.mentionEvent.line)["data"]?.objectValue)
        XCTAssertEqual(Set(data.keys), ["seq", "event_id", "at_ms", "chat", "message", "mention", "reply_chain", "context_before",
                                        "context_after", "account_peer_id"])
        XCTAssertEqual(data["account_peer_id"], .int(Self.me.peerId))
        XCTAssertEqual(Set(data["chat"]?.objectValue?.keys ?? [:].keys), ["peer_id", "telegram_id", "kind", "title", "username", "encryption"])
        XCTAssertEqual(Set(data["message"]?.objectValue?.keys ?? [:].keys),
                       ["id", "date", "sender", "text", "entities", "was_encrypted", "reply_to_message_id"])
        XCTAssertEqual(Set(data["message"]?["sender"]?.objectValue?.keys ?? [:].keys), ["peer_id", "telegram_id", "name", "username"])
        XCTAssertEqual(data["event_id"], .string("m-9824502482-1042"))
    }

    /// PLAN.md 3.45.2: only a `_ms` field is milliseconds; `generated_at` / `last_rescan_at` / `date` are seconds.
    func testTimesAreSecondsExceptMilliseconds() throws {
        let lines = Dictionary(uniqueKeysWithValues: Self.all.map { ($0.name, $0.line) })
        let ceiling: Int64 = 100_000_000_000
        let status = try AssistantJSON.parse(try XCTUnwrap(lines["status.ok"]))["result"]
        let directory = try AssistantJSON.parse(try XCTUnwrap(lines["directory.ok"]))["result"]
        let mention = try AssistantJSON.parse(try XCTUnwrap(lines["event.mention"]))["data"]
        XCTAssertLessThan(try XCTUnwrap(status?["last_rescan_at"]?.int64Value), ceiling)
        XCTAssertLessThan(try XCTUnwrap(directory?["generated_at"]?.int64Value), ceiling)
        XCTAssertLessThan(try XCTUnwrap(mention?["message"]?["date"]?.int64Value), ceiling)
        XCTAssertGreaterThan(try XCTUnwrap(mention?["at_ms"]?.int64Value), ceiling)
    }

    func testMentionUpdateNamesItsMention() throws {
        let lines = Dictionary(uniqueKeysWithValues: Self.all.map { ($0.name, $0.line) })
        let mention = try XCTUnwrap(try AssistantJSON.parse(try XCTUnwrap(lines["event.mention"]))["data"])
        let update = try XCTUnwrap(try AssistantJSON.parse(try XCTUnwrap(lines["event.mention.update"]))["data"])
        XCTAssertEqual(Set(update.objectValue?.keys ?? [:].keys), ["seq", "event_id", "chat_peer_id", "context_after"])
        XCTAssertEqual(update["seq"], mention["seq"])
        XCTAssertEqual(update["event_id"], mention["event_id"])
    }

    func testCommandEventCarriesEveryField() throws {
        let lines = Dictionary(uniqueKeysWithValues: Self.all.map { ($0.name, $0.line) })
        let data = try XCTUnwrap(try AssistantJSON.parse(try XCTUnwrap(lines["event.command"]))["data"]?.objectValue)
        XCTAssertEqual(Set(data.keys), ["seq", "event_id", "at_ms", "chat", "message", "command", "account_peer_id"])
        XCTAssertEqual(data["account_peer_id"], data["chat"]?["peer_id"])
        XCTAssertEqual(data["event_id"], .string("c-7654321-5001"))
        XCTAssertEqual(data["chat"]?["peer_id"], data["message"]?["sender"]?["peer_id"])
        XCTAssertLessThan(try XCTUnwrap(data["message"]?["date"]?.int64Value), 100_000_000_000)
        XCTAssertGreaterThan(try XCTUnwrap(data["at_ms"]?.int64Value), 100_000_000_000)
    }

    /// PLAN.md 3.45.2 amendment 2026-10-02: `status` lists every logged-in account and names the active one.
    func testStatusListsTheAccounts() throws {
        let lines = Dictionary(uniqueKeysWithValues: Self.all.map { ($0.name, $0.line) })
        let result = try XCTUnwrap(try AssistantJSON.parse(try XCTUnwrap(lines["status.ok"]))["result"])
        XCTAssertEqual(result["active_account_peer_id"], .int(Self.me.peerId))
        let accounts = try XCTUnwrap(result["accounts"]?.arrayValue)
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(Set(accounts[0].objectValue?.keys ?? [:].keys),
                       ["peer_id", "telegram_id", "name", "username", "active", "capture_enabled"])
        XCTAssertEqual(accounts.map { $0["active"] }, [.bool(true), .bool(false)])
        XCTAssertEqual(accounts.map { $0["capture_enabled"] }, [.bool(true), .bool(false)])
        XCTAssertEqual(accounts[1]["username"], .null)
    }

    static func fixturesBody(_ fixtures: [Fixture]) -> String {
        let rows = fixtures.map { AssistantJSON.object(["name": .string($0.name), "direction": .string($0.direction), "line": .string($0.line)]).encoded() }
        return "[\n" + rows.joined(separator: ",\n") + "\n]\n"
    }

    func testWriteFixturesFileWhenAsked() throws {
        guard let path = ProcessInfo.processInfo.environment["SECUTG_ASSISTANT_FIXTURES_OUT"], !path.isEmpty else { return }
        let adopted = Self.all.filter { !$0.pending }
        let pending = Self.all.filter { $0.pending }
        let body = Self.fixturesBody(adopted)
        try Data(body.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertEqual(try AssistantJSON.parse(body).arrayValue?.count, adopted.count)
        let url = URL(fileURLWithPath: path)
        let pendingURL = url.deletingPathExtension().appendingPathExtension("pending").appendingPathExtension(url.pathExtension)
        // Nothing pending → nothing written (an old pending file is left for whoever adopts it to archive).
        guard !pending.isEmpty else { return }
        let pendingBody = Self.fixturesBody(pending)
        try Data(pendingBody.utf8).write(to: pendingURL, options: .atomic)
        XCTAssertEqual(try AssistantJSON.parse(pendingBody).arrayValue?.count, pending.count)
    }
}
