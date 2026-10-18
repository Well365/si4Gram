import Foundation

/// Encrypted group invite (PLAN.md 3.13). Lives INSIDE an `E1` envelope of a private chat, so the server never
/// sees it: `G1:<group_chat_id>:<key_payload_b64url>:<title_b64url>`. Byte-identical to Web A `rekey/g1.ts`.
public struct GroupInvite: Equatable {
    public static let prefix = "G1:"

    public enum BuildError: Error, Equatable { case notAGroupChat, notAKeyPayload }

    public let groupChatId: String
    /// The `secutg://key?…` text, exactly what the offline QR code carries
    public let keyPayload: String
    /// Group name, for display only
    public let title: String

    public init(groupChatId: String, keyPayload: String, title: String) {
        self.groupChatId = groupChatId
        self.keyPayload = keyPayload
        self.title = title
    }

    public static func isG1(_ text: String) -> Bool {
        return text.hasPrefix(prefix)
    }

    public static func build(_ invite: GroupInvite) throws -> String {
        guard invite.groupChatId.hasPrefix("-") else { throw BuildError.notAGroupChat }
        guard invite.keyPayload.hasPrefix(KeyPayload.prefix) else { throw BuildError.notAKeyPayload }
        return ["G1", invite.groupChatId, Base64Url.encode([UInt8](invite.keyPayload.utf8)), Base64Url.encode([UInt8](invite.title.utf8))].joined(separator: ":")
    }

    /// nil for anything that is not a well-formed invite whose payload is a `secutg://key?…` text.
    public static func parse(_ text: String) -> GroupInvite? {
        guard isG1(text) else { return nil }
        let parts = text.components(separatedBy: ":")
        guard parts.count == 4 else { return nil }
        let groupChatId = parts[1]
        guard groupChatId.range(of: "^-\\d+$", options: .regularExpression) != nil,
              let payloadBytes = Base64Url.decode(parts[2]), let titleBytes = Base64Url.decode(parts[3]),
              let keyPayload = String(bytes: payloadBytes, encoding: .utf8), let title = String(bytes: titleBytes, encoding: .utf8),
              keyPayload.hasPrefix(KeyPayload.prefix) else { return nil }
        return GroupInvite(groupChatId: groupChatId, keyPayload: keyPayload, title: title)
    }
}
