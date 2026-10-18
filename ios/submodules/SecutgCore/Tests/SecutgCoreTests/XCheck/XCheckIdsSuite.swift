import Foundation
@testable import SecutgCore

/// The shared chat id, both ways (PLAN.md 3.0).
///
/// This is the regression gate for the one bug class that never announces itself: a client that spells
/// the channel id differently does not fail, it succeeds against a chat that is not the one the user
/// meant. Every table in the keyring is indexed by this string, so a disagreement here quietly binds a
/// key to a conversation the other side does not have.
struct XCheckIdsSuite: XCheckSuite {
    let name = "ids"

    func produce(_ env: XCheckEnv) throws -> [[String: Any]] {
        return try env.list("ids").map { spec in
            let kind = try spec.string("kind")
            let bareId = try spec.int64("bareId")
            return [
                "id": try spec.string("id"),
                "kind": kind,
                "bareId": NSNumber(value: bareId),
                "chatKey": SharedChatId.encodeString(kind: try XCheckIdsSuite.kind(kind), bareId: bareId),
            ]
        }
    }

    func consume(_ env: XCheckEnv, producer: String, vectorCase: [String: Any], results: XCheckResults) throws {
        let check = results.begin(producer: producer, suite: name, caseId: try vectorCase.string("id"))
        let kind = try vectorCase.string("kind")
        let bareId = try vectorCase.int64("bareId")
        let chatKey = try vectorCase.string("chatKey")

        check.eq("chatKey", chatKey, SharedChatId.encodeString(kind: try XCheckIdsSuite.kind(kind), bareId: bareId))

        if let decoded = SharedChatId.decode(chatKey) {
            check.eq("decoded kind", kind, XCheckIdsSuite.kindName(decoded.kind))
            check.eq("decoded bareId", NSNumber(value: bareId), NSNumber(value: decoded.bareId))
        } else {
            check.isTrue("chatKey \(chatKey) does not parse back", false)
        }
        check.end()
    }

    /// The vector spells the kinds in camelCase; this client's own raw values are snake_case, so the
    /// mapping is written out rather than leaning on `rawValue` — a rename on either side should be a
    /// compile error here, not a silently wrong lookup.
    static func kind(_ name: String) throws -> SharedChatId.Kind {
        switch name {
        case "user": return .user
        case "basicGroup": return .basicGroup
        case "channel": return .channel
        default: throw XCheckError.message("unknown chat kind \(name)")
        }
    }

    static func kindName(_ kind: SharedChatId.Kind) -> String {
        switch kind {
        case .user: return "user"
        case .basicGroup: return "basicGroup"
        case .channel: return "channel"
        }
    }
}
