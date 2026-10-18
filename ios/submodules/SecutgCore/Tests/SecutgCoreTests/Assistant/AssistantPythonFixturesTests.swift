import XCTest
@testable import SecutgCore

/// Conformance (PLAN.md 3.45.2): the assistant's own protocol fixtures (secuTG-smart-mate, written by its Python
/// encoder by `tools/dump_fixtures.py`) against this side.
/// - Every request the assistant writes must decode here to a command (or to `unknown_op` for the unknown one).
/// - Every response and event the assistant expects must have the shape this side's encoder produces for the
///   same fixture name (`AssistantFixturesTests.all`): the same keys, the same value kinds.
/// - The values must mean the same: seconds vs milliseconds, the `telegram_id` numbering, `mention.kind`, and a
///   `mention.update` naming its mention's `seq` / `event_id`.
/// Skipped when the smart-mate checkout is not at its usual path.
final class AssistantPythonFixturesTests: XCTestCase {
    static let path = "/Volumes/claudeXyz/securityTG/secuTG-smart-mate/tests/fixtures/protocol-fixtures.json"
    /// Unix seconds stay below this until the year 5138; Unix milliseconds of today are far above it.
    static let secondsCeiling: Int64 = 100_000_000_000
    static let channelOffset: Int64 = 1_000_000_000_000
    /// Keys that are present only sometimes (a message's reply, an entity's user / url, a message's attachments
    /// and an attachment's file name — 2026-10-10).
    static let optionalKeys: Set<String> = ["reply_to_message_id", "user_peer_id", "url", "media", "file_name"]
    /// Ops this side answers that an assistant may not know yet (it then never asks, and must cope with an older
    /// client answering `unknown_op`). `media` (2026-10-10) is listed until the assistant's fixtures carry it.
    static let opsTheAssistantMayNotKnow: Set<String> = ["media"]
    /// Keys whose value may be null on either side.
    static let nullableKeys: Set<String> = ["username", "account", "last_rescan_at", "id", "active_account_peer_id"]
    /// Python fixture name → this side's fixture name, where they differ.
    static let aliases = ["bad_line.error.bad_params": "bad_json.error", "any.error.internal": "internal.error"]

    struct Row {
        let name: String
        let direction: String
        let value: AssistantJSON?
        let line: String
    }

    private func load() throws -> [Row] {
        guard FileManager.default.fileExists(atPath: Self.path) else {
            throw XCTSkip("\(Self.path) not present")
        }
        let rows = try XCTUnwrap(try AssistantJSON.parse(Data(contentsOf: URL(fileURLWithPath: Self.path))).arrayValue)
        return try rows.map { row in
            let line = try XCTUnwrap(row["line"]?.stringValue)
            return Row(name: try XCTUnwrap(row["name"]?.stringValue), direction: try XCTUnwrap(row["direction"]?.stringValue),
                       value: try? AssistantJSON.parse(line), line: line)
        }
    }

    private func row(_ rows: [Row], _ name: String) throws -> AssistantJSON {
        return try XCTUnwrap(rows.first { $0.name == name }?.value, name)
    }

    func testEveryRequestDecodesToACommand() throws {
        let requests = try load().filter { $0.direction == "assistant_to_client" }
        XCTAssertFalse(requests.isEmpty)
        var ops = Set<String>()
        for request in requests {
            let decoded = AssistantRequestDecoder.decode(line: Data(request.line.utf8))
            XCTAssertEqual(decoded.id, request.value?["id"], request.name)
            switch decoded.result {
            case .success:
                XCTAssertFalse(request.name.hasPrefix("unknown_op"), request.name)
                ops.insert(request.value?["op"]?.stringValue ?? "")
            case let .failure(failure):
                XCTAssertTrue(request.name.hasPrefix("unknown_op"), "\(request.name): \(failure.code.rawValue) \(failure.message)")
                XCTAssertEqual(failure.code, .unknownOp, request.name)
            }
        }
        let all = Set(AssistantOp.allCases.map { $0.rawValue })
        XCTAssertTrue(ops.isSubset(of: all), "\(ops.subtracting(all).sorted())")
        XCTAssertTrue(all.subtracting(ops).isSubset(of: Self.opsTheAssistantMayNotKnow), "\(all.subtracting(ops).sorted())")
    }

    func testEveryResponseAndEventHasTheShapeThisSideSends() throws {
        let ours = Dictionary(uniqueKeysWithValues: AssistantFixturesTests.all.map { ($0.name, $0.line) })
        for theirs in try load() where theirs.direction == "client_to_assistant" {
            let name = Self.aliases[theirs.name] ?? theirs.name
            guard let line = ours[name] else {
                XCTFail("\(theirs.name): this side has no fixture \(name)")
                continue
            }
            let expected = try AssistantJSON.parse(line)
            let actual = try XCTUnwrap(theirs.value, theirs.name)
            assertSameShape(actual, expected, path: theirs.name)
            if let code = actual["error"]?["code"]?.stringValue {
                XCTAssertNotNil(AssistantErrorCode(rawValue: code), "\(theirs.name): \(code)")
            }
        }
    }

    func testTimesAreSecondsExceptMilliseconds() throws {
        let rows = try load()
        let status = try row(rows, "status.ok")["result"]
        let directory = try row(rows, "directory.ok")["result"]
        let mention = try row(rows, "event.mention")["data"]
        XCTAssertLessThan(try XCTUnwrap(status?["last_rescan_at"]?.int64Value), Self.secondsCeiling)
        XCTAssertLessThan(try XCTUnwrap(directory?["generated_at"]?.int64Value), Self.secondsCeiling)
        XCTAssertLessThan(try XCTUnwrap(mention?["message"]?["date"]?.int64Value), Self.secondsCeiling)
        XCTAssertGreaterThan(try XCTUnwrap(mention?["at_ms"]?.int64Value), Self.secondsCeiling)
    }

    func testTelegramIdsUseTheSecutgNumbering() throws {
        let rows = try load()
        var chats = try XCTUnwrap(try row(rows, "directory.ok")["result"]?["chats"]?.arrayValue)
        chats.append(try XCTUnwrap(try row(rows, "event.mention")["data"]?["chat"]))
        for chat in chats {
            let kind = try XCTUnwrap(chat["kind"]?.stringValue.flatMap(AssistantChatKind.init(rawValue:)))
            let id = try XCTUnwrap(chat["telegram_id"]?.int64Value)
            switch kind {
            case .user: XCTAssertGreaterThan(id, 0)
            case .group: XCTAssertTrue(id < 0 && id > -Self.channelOffset, "\(id)")
            case .supergroup, .channel: XCTAssertLessThanOrEqual(id, -Self.channelOffset)
            }
        }
    }

    func testMentionKindAndUpdateMeanWhatThisSideMeans() throws {
        let rows = try load()
        let mention = try XCTUnwrap(try row(rows, "event.mention")["data"])
        let update = try XCTUnwrap(try row(rows, "event.mention.update")["data"])
        let span = try XCTUnwrap(mention["mention"])
        let expected = ["text_mention": "entity", "mention": "username"]
        for entity in mention["message"]?["entities"]?.arrayValue ?? []
        where entity["offset"] == span["offset"] && entity["length"] == span["length"] {
            if let kind = entity["type"]?.stringValue.flatMap({ expected[$0] }) {
                XCTAssertEqual(span["kind"]?.stringValue, kind)
            }
        }
        XCTAssertEqual(update["seq"], mention["seq"])
        XCTAssertEqual(update["event_id"], mention["event_id"])
        XCTAssertEqual(update["chat_peer_id"], mention["chat"]?["peer_id"])
    }

    // MARK: shape

    private func kind(_ value: AssistantJSON) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private func assertSameShape(_ actual: AssistantJSON, _ expected: AssistantJSON, path: String, key: String = "") {
        if actual == .null || expected == .null {
            if actual != expected {
                XCTAssertTrue(Self.nullableKeys.contains(key), "\(path): null on one side only")
            }
            return
        }
        switch (actual, expected) {
        case let (.object(theirs), .object(ours)):
            let missing = Set(ours.keys).subtracting(theirs.keys).subtracting(Self.optionalKeys)
            let extra = Set(theirs.keys).subtracting(ours.keys).subtracting(Self.optionalKeys)
            XCTAssertTrue(missing.isEmpty, "\(path): the assistant lacks \(missing.sorted())")
            XCTAssertTrue(extra.isEmpty, "\(path): the assistant expects \(extra.sorted()) this side never sends")
            for (name, value) in theirs {
                if let other = ours[name] { assertSameShape(value, other, path: "\(path).\(name)", key: name) }
            }
        case let (.array(theirs), .array(ours)):
            guard let model = ours.first else { return }
            for (index, item) in theirs.enumerated() {
                assertSameShape(item, model, path: "\(path)[\(index)]", key: key)
            }
        default:
            XCTAssertEqual(kind(actual), kind(expected), path)
        }
    }
}
