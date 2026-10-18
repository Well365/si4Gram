import XCTest
@testable import SecutgCore

/// PLAN.md 3.0 / 3.21.1. The `shared_chat_id_format` block of `Vectors/watermark.json` is the
/// cross-client contract for how a conversation is named — in the keyring archive, in a `G1` invite
/// and in the watermark payload. Every client asserts its own chat-key function against it.
///
/// This exists because iOS, macOS and Windows all built the channel form by gluing the literal string
/// `"-100"` in front of the bare id, which equals the arithmetic `-(id + 10^12)` **only when the bare
/// id is exactly ten digits long**. The `bare_id = 1` case below is the one that separates them: the
/// string way gives `-1001`, everything else gives `-1000000000001`. A wrong id here does not fail
/// loudly — it silently archives keys under a name the other clients never look up, and stamps
/// screenshots with a conversation id pointing at some unrelated channel.
final class SharedChatIdTests: XCTestCase {
    let v = Vectors.load("watermark")

    private var block: [String: Any] {
        guard let block = v["shared_chat_id_format"] as? [String: Any] else {
            XCTFail("watermark.json is missing the shared_chat_id_format block")
            return [:]
        }
        return block
    }

    func testChannelBaseMatchesTheContract() {
        XCTAssertEqual(SharedChatId.channelBase, (block["channel_id_base"] as? String).flatMap(Int64.init))
    }

    func testEveryVectorCaseRoundTrips() {
        let cases = block["cases"] as? [[String: String]] ?? []
        XCTAssertFalse(cases.isEmpty, "shared_chat_id_format carries no cases")

        for entry in cases {
            guard let kindText = entry["kind"],
                  let bareText = entry["bare_id"], let bareId = Int64(bareText),
                  let expected = entry["chat_id"] else {
                XCTFail("malformed shared_chat_id_format case: \(entry)")
                continue
            }
            // A supergroup is a channel wearing another name; both encode identically.
            let kind: SharedChatId.Kind = kindText == "supergroup" ? .channel : SharedChatId.Kind(rawValue: kindText)!

            XCTAssertEqual(SharedChatId.encodeString(kind: kind, bareId: bareId), expected,
                           "\(kindText) \(bareText) must encode to \(expected)")

            let decoded = SharedChatId.decode(expected)
            XCTAssertEqual(decoded?.kind, kind, "\(expected) must decode back to \(kind.rawValue)")
            XCTAssertEqual(decoded?.bareId, bareId, "\(expected) must decode back to bare id \(bareText)")
        }
    }

    /// The exact shape of the old bug, stated as a test so nobody reintroduces the string form.
    func testShortChannelIdIsNotTheStringPrefixForm() {
        XCTAssertEqual(SharedChatId.encodeString(kind: .channel, bareId: 1), "-1000000000001")
        XCTAssertNotEqual(SharedChatId.encodeString(kind: .channel, bareId: 1), "-1001")
    }

    func testMalformedIdsDecodeToNothing() {
        XCTAssertNil(SharedChatId.decode("0"))
        XCTAssertNil(SharedChatId.decode("-1000000000000"))
        XCTAssertNil(SharedChatId.decode("not a number"))
        XCTAssertNil(SharedChatId.decode(""))
    }
}
