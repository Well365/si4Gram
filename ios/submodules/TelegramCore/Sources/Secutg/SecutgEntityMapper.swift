import Foundation
import Postbox
import SecutgCore

/// Maps Postbox `MessageTextEntity` ↔ the envelope's Telegram-JSON entities (`MessageEntityBold`, …),
/// byte-compatible with Web A (`buildApiMessageEntity`) and Android (`EntityMapper`).
enum SecutgEntityMapper {
    static func toEnvelope(_ entities: [MessageTextEntity]) -> [E1Entity] {
        return entities.compactMap { entity in
            let offset = entity.range.lowerBound
            let length = entity.range.upperBound - entity.range.lowerBound
            switch entity.type {
            case .Bold: return E1Entity(type: "MessageEntityBold", offset: offset, length: length)
            case .Italic: return E1Entity(type: "MessageEntityItalic", offset: offset, length: length)
            case .Underline: return E1Entity(type: "MessageEntityUnderline", offset: offset, length: length)
            case .Strikethrough: return E1Entity(type: "MessageEntityStrike", offset: offset, length: length)
            case .Spoiler: return E1Entity(type: "MessageEntitySpoiler", offset: offset, length: length)
            case .Code: return E1Entity(type: "MessageEntityCode", offset: offset, length: length)
            case .Pre(let language): return E1Entity(type: "MessageEntityPre", offset: offset, length: length, extras: ["language": .string(language ?? "")])
            case .Url: return E1Entity(type: "MessageEntityUrl", offset: offset, length: length)
            case .Email: return E1Entity(type: "MessageEntityEmail", offset: offset, length: length)
            case .PhoneNumber: return E1Entity(type: "MessageEntityPhone", offset: offset, length: length)
            case .Mention: return E1Entity(type: "MessageEntityMention", offset: offset, length: length)
            case .Hashtag: return E1Entity(type: "MessageEntityHashtag", offset: offset, length: length)
            case .BotCommand: return E1Entity(type: "MessageEntityBotCommand", offset: offset, length: length)
            case .TextUrl(let url): return E1Entity(type: "MessageEntityTextUrl", offset: offset, length: length, extras: ["url": .string(url)])
            case .TextMention(let peerId): return E1Entity(type: "MessageEntityMentionName", offset: offset, length: length, extras: ["userId": .string(String(peerId.id._internalGetInt64Value()))]) // SECUTG-HOOK (fix, 2026-09-30): Web/Android key
            case .BlockQuote(let isCollapsed): return E1Entity(type: "MessageEntityBlockquote", offset: offset, length: length, extras: ["collapsed": .bool(isCollapsed)])
            case .CustomEmoji(_, let fileId): return E1Entity(type: "MessageEntityCustomEmoji", offset: offset, length: length, extras: ["document_id": .string(String(fileId))])
            case .BankCard: return E1Entity(type: "MessageEntityBankCard", offset: offset, length: length)
            default: return nil // Unknown, Custom and any newer entity kinds carry nothing across platforms
            }
        }
    }

    static func fromEnvelope(_ entities: [E1Entity]) -> [MessageTextEntity] {
        return entities.compactMap { entity in
            let range = entity.offset..<(entity.offset + entity.length)
            let type: MessageTextEntityType
            switch entity.type {
            case "MessageEntityBold": type = .Bold
            case "MessageEntityItalic": type = .Italic
            case "MessageEntityUnderline": type = .Underline
            case "MessageEntityStrike": type = .Strikethrough
            case "MessageEntitySpoiler": type = .Spoiler
            case "MessageEntityCode": type = .Code
            case "MessageEntityPre": type = .Pre(language: entity.extras["language"]?.stringValue)
            case "MessageEntityUrl": type = .Url
            case "MessageEntityEmail": type = .Email
            case "MessageEntityPhone": type = .PhoneNumber
            case "MessageEntityMention": type = .Mention
            case "MessageEntityHashtag": type = .Hashtag
            case "MessageEntityBotCommand": type = .BotCommand
            case "MessageEntityTextUrl":
                guard let url = entity.extras["url"]?.stringValue else { return nil }
                type = .TextUrl(url: url)
            case "MessageEntityMentionName":
                // SECUTG-HOOK (fix, 2026-09-30): `userId` is the cross-client key; `user_id` is what iOS/macOS wrote before.
                guard let raw = entity.extras["userId"] ?? entity.extras["user_id"], let id = raw.stringValue.flatMap(Int64.init) ?? raw.intValue.map(Int64.init) else { return nil }
                type = .TextMention(peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(id)))
            case "MessageEntityBlockquote":
                if case .bool(let collapsed)? = entity.extras["collapsed"] { type = .BlockQuote(isCollapsed: collapsed) } else { type = .BlockQuote(isCollapsed: false) }
            case "MessageEntityCustomEmoji":
                guard let raw = entity.extras["document_id"], let id = raw.stringValue.flatMap(Int64.init) ?? raw.intValue.map(Int64.init) else { return nil }
                type = .CustomEmoji(stickerPack: nil, fileId: id)
            case "MessageEntityBankCard": type = .BankCard
            default: return nil
            }
            return MessageTextEntity(range: range, type: type)
        }
    }
}
