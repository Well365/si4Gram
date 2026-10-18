import Foundation

/// PLAN.md 3.45.7 "只认自己的指令" / 3.45.2 `command` event: a `/secu …` line this account wrote in its own
/// Saved Messages is a command to the assistant; nothing else is.
///
/// The rule, all four at once:
/// - the chat is Saved Messages (the account's chat with itself);
/// - the author is this account, and the words are its own: not a forward, not an inline bot's result (the glue
///   answers `authorIsSelf` false for those, and passes `isForwarded` for a forward);
/// - the message is outgoing;
/// - after trimming, the text is `/secu` alone or `/secu` followed by whitespace and more. `/secux`, `/SECU` and
///   a `/secu` that is not at the start are not commands.
///
/// Someone else's message is never a command, wherever it is written.
public enum SelfCommand {
    public static let keyword = "/secu"

    public static func isSelfCommand(chatIsSavedMessages: Bool, authorIsSelf: Bool, isOutgoing: Bool, isForwarded: Bool = false,
                                     text: String) -> Bool {
        guard chatIsSavedMessages, authorIsSelf, isOutgoing, !isForwarded else { return false }
        return parse(text) != nil
    }

    /// The command in `text`, whoever wrote it (the caller asks `isSelfCommand` for that): `name` is the first word
    /// after `/secu`, ASCII-lowercased (`""` for a bare `/secu`), `args` the rest with its outer whitespace trimmed
    /// and its inner lines kept. nil when the text is not a `/secu` line.
    public static func parse(_ text: String) -> AssistantSelfCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(keyword) else { return nil }
        let rest = trimmed.dropFirst(keyword.count)
        if rest.isEmpty { return AssistantSelfCommand(name: "", args: "") }
        guard let first = rest.first, first.isWhitespace else { return nil }
        let body = rest.drop(while: { $0.isWhitespace })
        let name = body.prefix(while: { !$0.isWhitespace })
        let args = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantSelfCommand(name: asciiLowercased(String(name)), args: args)
    }

    /// The assistant's own `send` may never write a command into Saved Messages: what it sends there is a reply,
    /// and a reply that read as a command would be picked up again (a loop). Other chats are not this rule's
    /// business — a `/secu` line there is not a command.
    public static func sendRefusal(chatIsSavedMessages: Bool, text: String) -> AssistantFailure? {
        guard chatIsSavedMessages, parse(text) != nil else { return nil }
        return AssistantFailure(.refused, "the assistant cannot send a /secu command to Saved Messages")
    }

    private static func asciiLowercased(_ value: String) -> String {
        return String(value.map { $0.isASCII ? Character($0.lowercased()) : $0 })
    }
}

/// The `command` of a `command` event.
public struct AssistantSelfCommand: Equatable {
    public let name: String
    public let args: String

    public init(name: String, args: String) {
        self.name = name
        self.args = args
    }

    public var json: AssistantJSON {
        return .object(["name": .string(name), "args": .string(args)])
    }
}

/// The `command` event's `data` (PLAN.md 3.45.2 / 3.45.7). It rides the mention's durable path — queue file first,
/// then push, the same `seq` counter, the same `ack` — so a command given while the assistant is down waits for it.
/// `event_id` is stable for a message (`c-<chat peer_id>-<message id>`); `chat` is Saved Messages (its `peer_id` is
/// where a reply goes), `message` the command line as the account wrote it, `command` the parsed line.
public struct AssistantCommandEvent: Equatable, AssistantQueuedEvent {
    public static let name = "command"

    public let seq: Int64
    public let atMs: Int64
    public let chat: AssistantChat
    public let message: AssistantMessage
    public let command: AssistantSelfCommand
    /// The account whose Saved Messages carried the command (2026-10-02 addition, `account_peer_id`; equals
    /// `chat.peer_id`). Always set by the client; nil only in old queue files and tests.
    public let accountPeerId: Int64?

    public init(seq: Int64, atMs: Int64, chat: AssistantChat, message: AssistantMessage, command: AssistantSelfCommand,
                accountPeerId: Int64? = nil) {
        self.accountPeerId = accountPeerId
        self.seq = seq
        self.atMs = atMs
        self.chat = chat
        self.message = message
        self.command = command
    }

    public var eventId: String { return AssistantCommandEvent.eventId(chatPeerId: chat.peerId, messageId: message.id) }

    public static func eventId(chatPeerId: Int64, messageId: Int32) -> String {
        return "c-\(chatPeerId)-\(messageId)"
    }

    public var data: [String: AssistantJSON] {
        var fields: [String: AssistantJSON] = [
            "seq": .int(seq), "event_id": .string(eventId), "at_ms": .int(atMs), "chat": chat.json,
            "message": message.json, "command": command.json,
        ]
        if let accountPeerId { fields["account_peer_id"] = .int(accountPeerId) }
        return fields
    }

    /// The line pushed to subscribers and stored as `queue/<seq>.json`.
    public var line: String { return AssistantLine.event(AssistantCommandEvent.name, data: data) }
}
