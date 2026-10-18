import XCTest
@testable import SecutgCore

/// Implementation plan C1.3: every op's success and error path, unknown op, missing params, bad JSON.
final class AssistantProtocolTests: XCTestCase {
    private func decode(_ line: String) -> AssistantDecodedRequest {
        return AssistantRequestDecoder.decode(line: Data(line.utf8))
    }

    private func command(_ line: String) -> AssistantCommand? {
        if case let .success(command) = decode(line).result { return command }
        return nil
    }

    private func failure(_ line: String) -> AssistantFailure? {
        if case let .failure(failure) = decode(line).result { return failure }
        return nil
    }

    func testHello() {
        XCTAssertEqual(command(#"{"id":"1","op":"hello","params":{"client":"secutg-mate","version":"0.1"}}"#),
                       .hello(client: "secutg-mate", version: "0.1"))
        XCTAssertEqual(failure(#"{"id":"1","op":"hello","params":{"client":"x"}}"#)?.code, .badParams)
    }

    func testStatusAndDirectoryTakeNoParams() {
        XCTAssertEqual(command(#"{"id":"1","op":"status"}"#), .status)
        XCTAssertEqual(command(#"{"id":"1","op":"directory","params":{}}"#), .directory)
        XCTAssertEqual(failure(#"{"id":"1","op":"status","params":[]}"#)?.code, .badParams)
    }

    func testSubscribe() {
        XCTAssertEqual(command(#"{"id":"1","op":"subscribe","params":{"since":12}}"#), .subscribe(since: 12))
        XCTAssertEqual(command(#"{"id":"1","op":"subscribe","params":{}}"#), .subscribe(since: 0))
        XCTAssertEqual(failure(#"{"id":"1","op":"subscribe","params":{"since":-1}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"subscribe","params":{"since":"3"}}"#)?.code, .badParams)
    }

    func testAck() {
        XCTAssertEqual(command(#"{"id":"1","op":"ack","params":{"seq":7}}"#), .ack(seq: 7))
        XCTAssertEqual(failure(#"{"id":"1","op":"ack","params":{}}"#)?.code, .badParams)
    }

    func testContext() {
        XCTAssertEqual(command(#"{"id":"1","op":"context","params":{"chat_peer_id":-5,"message_id":9,"before":3,"after":0}}"#),
                       .context(chatPeerId: -5, messageId: 9, before: 3, after: 0))
        XCTAssertEqual(command(#"{"id":"1","op":"context","params":{"chat_peer_id":5,"message_id":9}}"#),
                       .context(chatPeerId: 5, messageId: 9, before: AssistantProtocol.defaultContextBefore,
                                after: AssistantProtocol.defaultContextAfter))
        XCTAssertEqual(failure(#"{"id":"1","op":"context","params":{"chat_peer_id":5}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"context","params":{"chat_peer_id":5,"message_id":9,"before":201}}"#)?.code, .badParams)
    }

    func testSend() {
        XCTAssertEqual(command(#"{"id":"1","op":"send","params":{"chat_peer_id":5,"text":"收到","reply_to_message_id":9}}"#),
                       .send(chatPeerId: 5, text: "收到", replyToMessageId: 9, encryption: .follow))
        XCTAssertEqual(command(#"{"id":"1","op":"send","params":{"chat_peer_id":5,"text":"ok","reply_to_message_id":null}}"#),
                       .send(chatPeerId: 5, text: "ok", replyToMessageId: nil, encryption: .follow))
        XCTAssertEqual(failure(#"{"id":"1","op":"send","params":{"chat_peer_id":5,"text":"  "}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"send","params":{"text":"x"}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"send","params":{"chat_peer_id":5,"text":"x","reply_to_message_id":0}}"#)?.code, .badParams)
    }

    /// Phase 2 (C2.1): `encryption` is optional, defaults to `follow`, and takes exactly the three wire names.
    func testSendEncryption() {
        XCTAssertEqual(command(#"{"id":"1","op":"send","params":{"chat_peer_id":5,"text":"x","encryption":"encrypted"}}"#),
                       .send(chatPeerId: 5, text: "x", replyToMessageId: nil, encryption: .encrypted))
        XCTAssertEqual(command(#"{"id":"1","op":"send","params":{"chat_peer_id":5,"text":"x","encryption":"plaintext"}}"#),
                       .send(chatPeerId: 5, text: "x", replyToMessageId: nil, encryption: .plaintext))
        XCTAssertEqual(command(#"{"id":"1","op":"send","params":{"chat_peer_id":5,"text":"x","encryption":"follow"}}"#),
                       .send(chatPeerId: 5, text: "x", replyToMessageId: nil, encryption: .follow))
        XCTAssertEqual(command(#"{"id":"1","op":"send","params":{"chat_peer_id":5,"text":"x","encryption":null}}"#),
                       .send(chatPeerId: 5, text: "x", replyToMessageId: nil, encryption: .follow))
        XCTAssertEqual(failure(#"{"id":"1","op":"send","params":{"chat_peer_id":5,"text":"x","encryption":"Encrypted"}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"send","params":{"chat_peer_id":5,"text":"x","encryption":"none"}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"send","params":{"chat_peer_id":5,"text":"x","encryption":1}}"#)?.code, .badParams)
        XCTAssertEqual(AssistantSendEncryption.allCases.map { $0.rawValue }, ["follow", "encrypted", "plaintext"])
    }

    func testSendTooLongCountsUTF16() {
        let exact = String(repeating: "a", count: AssistantProtocol.maxSendTextLength)
        XCTAssertNotNil(command(AssistantLine.request(id: "1", op: .send, params: ["chat_peer_id": .int(1), "text": .string(exact)])))
        let over = String(repeating: "🔒", count: AssistantProtocol.maxSendTextLength / 2 + 1)
        XCTAssertEqual(failure(AssistantLine.request(id: "1", op: .send, params: ["chat_peer_id": .int(1), "text": .string(over)]))?.code, .tooLong)
    }

    func testRead() {
        XCTAssertEqual(command(#"{"id":"1","op":"read","params":{"chat_peer_id":5,"message_id":9}}"#), .read(chatPeerId: 5, messageId: 9))
        XCTAssertEqual(failure(#"{"id":"1","op":"read","params":{"chat_peer_id":5,"message_id":0}}"#)?.code, .badParams)
    }

    /// `open` (PLAN.md 3.45.2, 2026-10-03): `message_id` and `account_peer_id` are both optional.
    func testOpen() {
        XCTAssertEqual(command(#"{"id":"1","op":"open","params":{"chat_peer_id":5}}"#),
                       .open(chatPeerId: 5, messageId: nil, accountPeerId: nil))
        XCTAssertEqual(command(#"{"id":"1","op":"open","params":{"chat_peer_id":5,"message_id":9,"account_peer_id":11}}"#),
                       .open(chatPeerId: 5, messageId: 9, accountPeerId: 11))
        XCTAssertEqual(command(#"{"id":"1","op":"open","params":{"chat_peer_id":5,"message_id":null,"account_peer_id":null}}"#),
                       .open(chatPeerId: 5, messageId: nil, accountPeerId: nil))
        XCTAssertEqual(failure(#"{"id":"1","op":"open","params":{"chat_peer_id":5,"message_id":0}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"open","params":{"chat_peer_id":5,"account_peer_id":"x"}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"open","params":{}}"#)?.code, .badParams)
    }

    func testHistory() {
        XCTAssertEqual(command(#"{"id":"1","op":"history","params":{"chat_peer_id":5,"since":1790000000,"limit":50}}"#),
                       .history(chatPeerId: 5, since: 1_790_000_000, limit: 50))
        XCTAssertEqual(command(#"{"id":"1","op":"history","params":{"chat_peer_id":5,"since":0}}"#),
                       .history(chatPeerId: 5, since: 0, limit: AssistantProtocol.defaultHistoryLimit))
        XCTAssertEqual(failure(#"{"id":"1","op":"history","params":{"chat_peer_id":5}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"history","params":{"chat_peer_id":5,"since":-1}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"history","params":{"chat_peer_id":5,"since":0,"limit":0}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"history","params":{"chat_peer_id":5,"since":0,"limit":501}}"#)?.code, .badParams)
    }

    func testMedia() {
        XCTAssertEqual(command(#"{"id":"1","op":"media","params":{"chat_peer_id":5,"message_id":9,"index":0,"max_bytes":2000000}}"#),
                       .media(chatPeerId: 5, messageId: 9, index: 0, maxBytes: 2_000_000))
        XCTAssertEqual(command(#"{"id":"1","op":"media","params":{"chat_peer_id":5,"message_id":9,"index":1}}"#),
                       .media(chatPeerId: 5, messageId: 9, index: 1, maxBytes: AssistantProtocol.maxMediaBytes))
        // A larger ask is capped, not refused: an assistant that does not know the ceiling still gets an answer.
        XCTAssertEqual(command(#"{"id":"1","op":"media","params":{"chat_peer_id":5,"message_id":9,"index":0,"max_bytes":99999999999}}"#),
                       .media(chatPeerId: 5, messageId: 9, index: 0, maxBytes: AssistantProtocol.maxMediaBytes))
        XCTAssertEqual(failure(#"{"id":"1","op":"media","params":{"chat_peer_id":5,"message_id":9}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"media","params":{"chat_peer_id":5,"message_id":9,"index":-1}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"media","params":{"chat_peer_id":5,"message_id":0,"index":0}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"media","params":{"chat_peer_id":5,"message_id":9,"index":0,"max_bytes":0}}"#)?.code, .badParams)
    }

    func testFolders() {
        XCTAssertEqual(command(#"{"id":"1","op":"folders"}"#), .folders)
        XCTAssertEqual(command(#"{"id":"1","op":"folder_update","params":{"action":"create","title":" 后端 ","peer_ids":[5,6,5]}}"#),
                       .folderUpdate(action: .create, folderId: nil, title: "后端", peerIds: [5, 6]))
        XCTAssertEqual(command(#"{"id":"1","op":"folder_update","params":{"action":"create","title":"空"}}"#),
                       .folderUpdate(action: .create, folderId: nil, title: "空", peerIds: []))
        XCTAssertEqual(command(#"{"id":"1","op":"folder_update","params":{"action":"rename","folder_id":3,"title":"运营"}}"#),
                       .folderUpdate(action: .rename, folderId: 3, title: "运营", peerIds: []))
        XCTAssertEqual(command(#"{"id":"1","op":"folder_update","params":{"action":"add","folder_id":3,"peer_ids":[7]}}"#),
                       .folderUpdate(action: .add, folderId: 3, title: nil, peerIds: [7]))
        XCTAssertEqual(command(#"{"id":"1","op":"folder_update","params":{"action":"delete","folder_id":3}}"#),
                       .folderUpdate(action: .delete, folderId: 3, title: nil, peerIds: []))
        XCTAssertEqual(failure(#"{"id":"1","op":"folder_update","params":{"action":"move","folder_id":3}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"folder_update","params":{"action":"add","folder_id":3}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"folder_update","params":{"action":"add","peer_ids":[1]}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"folder_update","params":{"action":"set","folder_id":3,"peer_ids":["x"]}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"folder_update","params":{"action":"create","title":"  "}}"#)?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1","op":"folder_update","params":{"action":"create","title":"一二三四五六七八九十一二三"}}"#)?.code, .tooLong)
        let many = (1...201).map(String.init).joined(separator: ",")
        XCTAssertEqual(failure(#"{"id":"1","op":"folder_update","params":{"action":"set","folder_id":3,"peer_ids":["# + many + "]}}")?.code, .tooLong)
    }

    func testUnknownOpKeepsTheId() {
        let decoded = decode(#"{"id":"abc","op":"unpair","params":{}}"#)
        XCTAssertEqual(decoded.id, .string("abc"))
        XCTAssertEqual(failure(#"{"id":"abc","op":"unpair","params":{}}"#)?.code, .unknownOp)
    }

    func testBadJSONAndMissingOp() {
        XCTAssertEqual(decode("{nope").id, .null)
        XCTAssertEqual(failure("{nope")?.code, .badParams)
        XCTAssertEqual(failure("[1]")?.code, .badParams)
        XCTAssertEqual(failure(#"{"id":"1"}"#)?.code, .badParams)
        XCTAssertEqual(decode(#"{"id":{"x":1},"op":"status"}"#).id, .null)
        XCTAssertEqual(decode(#"{"id":7,"op":"status"}"#).id, .int(7))
    }

    func testEveryOpNameIsKnown() {
        XCTAssertEqual(AssistantOp.allCases.map { $0.rawValue },
                       ["hello", "status", "directory", "subscribe", "ack", "context", "send", "read", "open", "history",
                        "folders", "folder_update", "media"])
        XCTAssertEqual(AssistantErrorCode.allCases.map { $0.rawValue },
                       ["unknown_op", "bad_params", "not_ready", "no_key", "locked", "refused", "not_found", "too_long",
                        "internal", "other_account", "unsupported", "too_large", "timeout"])
    }

    func testResponseLines() throws {
        let ok = AssistantLine.ok(id: .string("1"), result: AssistantResults.send(localMessageId: 42))
        XCTAssertEqual(ok, #"{"id":"1","ok":true,"result":{"local_message_id":42}}"#)
        let error = AssistantLine.error(id: .null, AssistantFailure(.locked, "group password is not unlocked"))
        XCTAssertEqual(error, #"{"error":{"code":"locked","message":"group password is not unlocked"},"id":null,"ok":false}"#)
        XCTAssertEqual(try AssistantJSON.parse(ok)["ok"], .bool(true))
    }
}
