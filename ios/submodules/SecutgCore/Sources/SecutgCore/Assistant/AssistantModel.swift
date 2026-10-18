import Foundation

/// PLAN.md 3.45.2 data shapes: the chat, the person, the message, the mention and the two events.
///
/// Ids: `peer_id` is the client's own Postbox peer id (what every op takes back); `telegram_id` is the id a person
/// reads elsewhere — a user's bare id, a basic group's `-id`, a supergroup / channel's `-(10^12 + id)`, i.e. the
/// `SharedChatId` numbering every secuTG client already uses. Times: a field named `…_ms` (`at_ms`) is Unix
/// milliseconds; every other time field (`date`, `generated_at`, `last_rescan_at`) is Unix seconds.
public enum AssistantChatKind: String, CaseIterable {
    case user, group, supergroup, channel
}

public enum AssistantEncryption: String, CaseIterable {
    case none, v1, v2, group
}

public enum AssistantMentionKind: String, CaseIterable {
    case entity, username, name
}

public struct AssistantPerson: Equatable {
    public let peerId: Int64
    public let telegramId: Int64
    public let name: String
    public let username: String?

    public init(peerId: Int64, telegramId: Int64, name: String, username: String?) {
        self.peerId = peerId
        self.telegramId = telegramId
        self.name = name
        self.username = username
    }

    public var json: AssistantJSON {
        return .object(["peer_id": .int(peerId), "telegram_id": .int(telegramId), "name": .string(name),
                        "username": .optionalString(username)])
    }
}

/// A message entity in UTF-16 offsets, like Telegram's. `type` is Bot-API style (`mention`, `text_mention`,
/// `url`, `text_url`, `bold` …); `user_peer_id` only on `text_mention`, `url` only on `text_url`.
public struct AssistantEntity: Equatable {
    public let type: String
    public let offset: Int
    public let length: Int
    public let userPeerId: Int64?
    public let url: String?

    public init(type: String, offset: Int, length: Int, userPeerId: Int64? = nil, url: String? = nil) {
        self.type = type
        self.offset = offset
        self.length = length
        self.userPeerId = userPeerId
        self.url = url
    }

    public var json: AssistantJSON {
        var fields: [String: AssistantJSON] = ["type": .string(type), "offset": .int(Int64(offset)), "length": .int(Int64(length))]
        if let userPeerId { fields["user_peer_id"] = .int(userPeerId) }
        if let url { fields["url"] = .string(url) }
        return .object(fields)
    }
}

public struct AssistantChat: Equatable {
    public let peerId: Int64
    public let telegramId: Int64
    public let kind: AssistantChatKind
    public let title: String
    public let username: String?
    public let encryption: AssistantEncryption

    public init(peerId: Int64, telegramId: Int64, kind: AssistantChatKind, title: String, username: String?, encryption: AssistantEncryption) {
        self.peerId = peerId
        self.telegramId = telegramId
        self.kind = kind
        self.title = title
        self.username = username
        self.encryption = encryption
    }

    public var json: AssistantJSON {
        return .object(["peer_id": .int(peerId), "telegram_id": .int(telegramId), "kind": .string(kind.rawValue),
                        "title": .string(title), "username": .optionalString(username),
                        "encryption": .string(encryption.rawValue)])
    }

    /// The directory's row: the event's chat plus `muted`.
    public func directoryJSON(muted: Bool) -> AssistantJSON {
        guard case var .object(fields) = json else { return json }
        fields["muted"] = .bool(muted)
        return .object(fields)
    }
}

/// One message as the assistant sees it. `text` is the decrypted words, or a placeholder for media / control
/// lines / anything that could not be opened (`AssistantPlaceholder`) — never a wire. `sender` is never null (the
/// contract's message shape has no null sender); `reply_to_message_id` is present only when the message replies to
/// something; `media` (2026-10-10) only when something is attached (`AssistantMediaItem`, described, never the bytes).
public struct AssistantMessage: Equatable {
    public let id: Int32
    public let date: Int32
    public let sender: AssistantPerson
    public let text: String
    public let entities: [AssistantEntity]
    public let wasEncrypted: Bool
    public let replyToMessageId: Int32?
    public let media: [AssistantMediaItem]

    public init(id: Int32, date: Int32, sender: AssistantPerson, text: String, entities: [AssistantEntity], wasEncrypted: Bool, replyToMessageId: Int32?,
                media: [AssistantMediaItem] = []) {
        self.id = id
        self.date = date
        self.sender = sender
        self.text = text
        self.entities = entities
        self.wasEncrypted = wasEncrypted
        self.replyToMessageId = replyToMessageId
        self.media = media
    }

    public var json: AssistantJSON {
        var fields: [String: AssistantJSON] = [
            "id": .int(Int64(id)), "date": .int(Int64(date)), "sender": sender.json, "text": .string(text),
            "entities": .array(entities.map { $0.json }), "was_encrypted": .bool(wasEncrypted),
        ]
        if let replyToMessageId { fields["reply_to_message_id"] = .int(Int64(replyToMessageId)) }
        if !media.isEmpty { fields["media"] = .array(media.map { $0.json }) }
        return .object(fields)
    }
}

public struct AssistantMention: Equatable {
    public let kind: AssistantMentionKind
    public let offset: Int
    public let length: Int

    public init(kind: AssistantMentionKind, offset: Int, length: Int) {
        self.kind = kind
        self.offset = offset
        self.length = length
    }

    public var json: AssistantJSON {
        return .object(["kind": .string(kind.rawValue), "offset": .int(Int64(offset)), "length": .int(Int64(length))])
    }
}

/// An event that takes a `seq` and a queue file (`mention`, `command`; not `mention.update`, which rides its
/// mention's). `line` is what is stored and pushed.
public protocol AssistantQueuedEvent {
    var seq: Int64 { get }
    var atMs: Int64 { get }
    var line: String { get }
}

/// The `mention` event's `data`. `event_id` is stable for a message (`m-<chat peer_id>-<message id>`), so a
/// consumer can drop a repeat whatever its `seq`.
public struct AssistantMentionEvent: Equatable, AssistantQueuedEvent {
    public let seq: Int64
    public let atMs: Int64
    public let chat: AssistantChat
    public let message: AssistantMessage
    public let mention: AssistantMention
    public let replyChain: [AssistantMessage]
    public let contextBefore: [AssistantMessage]
    public var contextAfter: [AssistantMessage]
    /// The account that received the mention (its Postbox peer id; 2026-10-02 addition, `account_peer_id`). Always
    /// set by the client; nil only in old queue files and tests.
    public let accountPeerId: Int64?

    public init(seq: Int64, atMs: Int64, chat: AssistantChat, message: AssistantMessage, mention: AssistantMention,
                replyChain: [AssistantMessage], contextBefore: [AssistantMessage], contextAfter: [AssistantMessage] = [],
                accountPeerId: Int64? = nil) {
        self.accountPeerId = accountPeerId
        self.seq = seq
        self.atMs = atMs
        self.chat = chat
        self.message = message
        self.mention = mention
        self.replyChain = replyChain
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }

    public var eventId: String { return AssistantMentionEvent.eventId(chatPeerId: chat.peerId, messageId: message.id) }

    public static func eventId(chatPeerId: Int64, messageId: Int32) -> String {
        return "m-\(chatPeerId)-\(messageId)"
    }

    public var data: [String: AssistantJSON] {
        var fields: [String: AssistantJSON] = [
            "seq": .int(seq), "event_id": .string(eventId), "at_ms": .int(atMs), "chat": chat.json,
            "message": message.json, "mention": mention.json,
            "reply_chain": .array(replyChain.map { $0.json }),
            "context_before": .array(contextBefore.map { $0.json }),
            "context_after": .array(contextAfter.map { $0.json }),
        ]
        if let accountPeerId { fields["account_peer_id"] = .int(accountPeerId) }
        return fields
    }

    /// The line pushed to subscribers and stored as `queue/<seq>.json`.
    public var line: String { return AssistantLine.event("mention", data: data) }

    /// `mention.update`: the event's `context_after` so far, in full (replace, not append — a repeat is harmless).
    /// Its `seq` / `event_id` are this mention's: an update takes no seq of its own and is not acked (PLAN.md 3.45.2).
    public var updateLine: String {
        return AssistantLine.event("mention.update", data: [
            "seq": .int(seq), "event_id": .string(eventId), "chat_peer_id": .int(chat.peerId),
            "context_after": .array(contextAfter.map { $0.json }),
        ])
    }
}

/// What the assistant is shown instead of something that is not text it may read (PLAN.md 3.45.2: control lines
/// and media are placeholders, never the wire).
public enum AssistantPlaceholder: String, CaseIterable {
    case control = "[系统消息]"
    case photo = "[图片]"
    case video = "[视频]"
    case voice = "[语音]"
    case file = "[文件]"
    case sticker = "[贴纸]"
    case media = "[媒体]"
    case undecryptable = "[无法解密]"
    case locked = "[需要群密码]"

    /// A media message's text: the placeholder, then its caption when it has one.
    public static func withCaption(_ placeholder: AssistantPlaceholder, caption: String) -> String {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? placeholder.rawValue : placeholder.rawValue + " " + caption
    }

    /// Words that carry key material and so are never handed out, whatever the row's meta says (a G1 invite that
    /// travelled inside E2 is stored as `.decrypted`, and the sender's own row has no meta at first): a G1 group
    /// invite, a `secutg://key?` payload anywhere in the text, a key transfer bundle, a quick share, a v2 join
    /// text. The caller shows `.control` instead.
    public static func carriesKeyMaterial(_ text: String) -> Bool {
        if text.contains(KeyPayload.prefix) { return true }
        let head = text.drop(while: { $0.isWhitespace })
        return [GroupInvite.prefix, TransferBundle.prefix, QuickShare.prefix, V2JoinText.prefix].contains { head.hasPrefix($0) }
    }
}
