import Foundation

/// PLAN.md 3.45.2: the local control protocol between the macOS client and the assistant (secuTG-smart-mate).
///
/// One JSON object per line (UTF-8, `\n`-terminated) on `~/Library/Application Support/secutg-assistant/control.sock`.
///   request   `{"id":"<uuid>","op":"<name>","params":{…}}`
///   response  `{"id":…,"ok":true,"result":{…}}` | `{"id":…,"ok":false,"error":{"code":"…","message":"…"}}`
///   event     `{"event":"mention","data":{…}}` | `{"event":"mention.update","data":{…}}`
/// Field and op names are the contract with the other side; they only ever grow (implementation plan §7).
public enum AssistantProtocol {
    public static let version: Int64 = 1
    /// Longest line either side accepts, newline excluded. Longer → the connection is dropped (C1.2).
    public static let maxLineBytes = 1 << 20
    /// Longest text `send` accepts, in UTF-16 units like every Telegram length.
    public static let maxSendTextLength = 4096
    /// `context`'s `before` / `after` defaults and ceiling.
    public static let defaultContextBefore = 30
    public static let defaultContextAfter = 10
    public static let maxContextWindow = 200
    /// `history` (PLAN.md 3.45.4 C): how many messages one call returns by default and at most.
    public static let defaultHistoryLimit = 200
    public static let maxHistoryLimit = 500
    /// `folder_update` (2026-10-08): Telegram's own limits — a folder title is at most 12 characters, a folder holds
    /// at most 200 chats (100 without Premium; the server enforces that one).
    public static let maxFolderTitleLength = 12
    public static let maxFolderPeers = 200
    /// `media` (2026-10-10): the most bytes one picture may have, whatever `max_bytes` asks — base64 makes the
    /// answer a third longer, and the assistant reads lines of up to 16 MiB. `max_bytes` defaults to this.
    public static let maxMediaBytes: Int64 = 10 * 1024 * 1024
    /// How long `media` waits for a picture that is not on this Mac yet to download.
    public static let mediaDownloadTimeoutSeconds: Double = 30

    /// Can `raw` be handed to Postbox's `PeerId(_:)` as a user / basic group / channel id? That initialiser asserts
    /// on an id it cannot hold, which aborts a Debug build, so a `chat_peer_id` from the socket is checked here
    /// first. The layout (Postbox `PeerId.init(_ n: Int64)`): bits 0–31 the id's low half, 32–34 the namespace,
    /// 35–63 the id's high bits; the id must fit in 56 bits. Namespaces 0 / 1 / 2 are CloudUser / CloudGroup /
    /// CloudChannel (TelegramCore `Namespaces.Peer`); a secret chat (3) or anything else is not a chat here.
    public static func isCloudChatPeerId(_ raw: Int64) -> Bool {
        let bits = UInt64(bitPattern: raw)
        let namespace = (bits >> 32) & 0x7
        guard namespace <= 2 else { return false }
        let idHigh = (bits >> 35) & 0xffff_ffff
        let id = (idHigh << 32) | (bits & 0xffff_ffff)
        return id != 0 && id & ~UInt64(0x00ff_ffff_ffff_ffff) == 0
    }
}

/// The whole error vocabulary (implementation plan §7). Raw values are wire strings.
public enum AssistantErrorCode: String, CaseIterable, Equatable {
    case unknownOp = "unknown_op"
    case badParams = "bad_params"
    case notReady = "not_ready"
    case noKey = "no_key"
    case locked = "locked"
    case refused = "refused"
    case notFound = "not_found"
    case tooLong = "too_long"
    case `internal` = "internal"
    /// `open` (PLAN.md 3.45.2, 2026-10-03): `account_peer_id` was given and differs from the client's current account.
    case otherAccount = "other_account"
    /// `media` (2026-10-10): the item is not a picture (video, sticker, a non-image document).
    case unsupported = "unsupported"
    /// `media`: the picture has more bytes than `max_bytes`.
    case tooLarge = "too_large"
    /// `media`: the picture did not finish downloading in time.
    case timeout = "timeout"
}

public struct AssistantFailure: Error, Equatable {
    public let code: AssistantErrorCode
    public let message: String

    public init(_ code: AssistantErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum AssistantOp: String, CaseIterable {
    case hello, status, directory, subscribe, ack, context, send, read, open, history, folders
    case folderUpdate = "folder_update"
    case media
}

/// `send`'s optional `encryption` (PLAN.md 3.45.2, phase 2 / implementation plan C2.1). Raw values are wire strings.
/// - `follow` (the default): the chat's own setting, through the ordinary outgoing queue and its gates.
/// - `encrypted`: this one message is encrypted even if the chat's switch is off; `no_key` when the chat has no key.
/// - `plaintext`: this one message goes in the clear, and only where it would anyway — refused in any chat that is
///   encrypting, whose encryption state is unknown, that requires a key (3.41) or that has a group password (3.38).
public enum AssistantSendEncryption: String, CaseIterable, Equatable {
    case follow
    case encrypted
    case plaintext
}

/// A request decoded and its params checked — what the router acts on. Everything here is plain data.
public enum AssistantCommand: Equatable {
    case hello(client: String, version: String)
    case status
    case directory
    case subscribe(since: Int64)
    case ack(seq: Int64)
    case context(chatPeerId: Int64, messageId: Int32, before: Int, after: Int)
    case send(chatPeerId: Int64, text: String, replyToMessageId: Int32?, encryption: AssistantSendEncryption)
    case read(chatPeerId: Int64, messageId: Int32)
    /// `open` (PLAN.md 3.45.2, 2026-10-03): bring the client to the chat (and, with `messageId`, the message).
    /// Navigation only. `accountPeerId`, when given, must be the client's current account.
    case open(chatPeerId: Int64, messageId: Int32?, accountPeerId: Int64?)
    /// `history` (PLAN.md 3.45.4 C, 2026-10-07): the chat's messages dated at or after `since` (Unix seconds), the
    /// newest `limit` of them, oldest first — what the assistant's hourly group briefing reads. Read only, like
    /// `context`; no anchor message needed.
    case history(chatPeerId: Int64, since: Int64, limit: Int)
    /// `folders` (2026-10-08): the account's Telegram chat folders and the chats each one lists by hand — the
    /// assistant's 自定义分组 are these folders, so a group made in either place shows in both.
    case folders
    /// `folder_update` (2026-10-08): create / rename / delete a folder, or add / remove / set the chats it lists.
    /// Only a folder's own chat list is touched: no chat is left, deleted or muted, and a folder's rules (all
    /// contacts, all groups, …) and exclusions stay as they are.
    case folderUpdate(action: AssistantFolderAction, folderId: Int32?, title: String?, peerIds: [Int64])
    /// `media` (2026-10-10): the bytes of attachment `index` of a message (`AssistantMediaItem.index`), when it is a
    /// picture of at most `maxBytes` bytes (capped at `AssistantProtocol.maxMediaBytes`). Read only.
    case media(chatPeerId: Int64, messageId: Int32, index: Int, maxBytes: Int64)
}

/// One decoded line: the request id (echoed verbatim, `null` when absent or unreadable) and either a command or
/// the failure to answer with.
public struct AssistantDecodedRequest: Equatable {
    public let id: AssistantJSON
    public let result: Result<AssistantCommand, AssistantFailure>
}

public enum AssistantRequestDecoder {
    public static func decode(line: Data) -> AssistantDecodedRequest {
        let value: AssistantJSON
        do {
            value = try AssistantJSON.parse(line)
        } catch {
            return AssistantDecodedRequest(id: .null, result: .failure(AssistantFailure(.badParams, "invalid JSON")))
        }
        guard case let .object(fields) = value else {
            return AssistantDecodedRequest(id: .null, result: .failure(AssistantFailure(.badParams, "request must be an object")))
        }
        let id = requestId(fields["id"])
        guard let opName = fields["op"]?.stringValue else {
            return AssistantDecodedRequest(id: id, result: .failure(AssistantFailure(.badParams, "missing op")))
        }
        guard let op = AssistantOp(rawValue: opName) else {
            return AssistantDecodedRequest(id: id, result: .failure(AssistantFailure(.unknownOp, "unknown op")))
        }
        let params: [String: AssistantJSON]
        switch fields["params"] {
        case .none, .some(.null): params = [:]
        case let .some(.object(object)): params = object
        default:
            return AssistantDecodedRequest(id: id, result: .failure(AssistantFailure(.badParams, "params must be an object")))
        }
        return AssistantDecodedRequest(id: id, result: command(op, params))
    }

    /// Strings and integers are echoed; anything else (objects, arrays) is not an id and reads as null.
    private static func requestId(_ value: AssistantJSON?) -> AssistantJSON {
        switch value {
        case let .some(.string(text)): return .string(text)
        case let .some(.int(number)): return .int(number)
        default: return .null
        }
    }

    static func command(_ op: AssistantOp, _ params: [String: AssistantJSON]) -> Result<AssistantCommand, AssistantFailure> {
        do {
            switch op {
            case .hello:
                return .success(.hello(client: try requiredString(params, "client"), version: try requiredString(params, "version")))
            case .status:
                return .success(.status)
            case .directory:
                return .success(.directory)
            case .subscribe:
                return .success(.subscribe(since: try optionalInt(params, "since", default: 0, range: 0...Int64.max)))
            case .ack:
                return .success(.ack(seq: try requiredInt(params, "seq", range: 0...Int64.max)))
            case .context:
                let window = Int64(AssistantProtocol.maxContextWindow)
                return .success(.context(
                    chatPeerId: try requiredInt(params, "chat_peer_id", range: Int64.min...Int64.max),
                    messageId: Int32(try requiredInt(params, "message_id", range: 1...Int64(Int32.max))),
                    before: Int(try optionalInt(params, "before", default: Int64(AssistantProtocol.defaultContextBefore), range: 0...window)),
                    after: Int(try optionalInt(params, "after", default: Int64(AssistantProtocol.defaultContextAfter), range: 0...window))))
            case .send:
                let chat = try requiredInt(params, "chat_peer_id", range: Int64.min...Int64.max)
                let text = try requiredString(params, "text")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AssistantFailure(.badParams, "text is empty")
                }
                guard text.utf16.count <= AssistantProtocol.maxSendTextLength else {
                    throw AssistantFailure(.tooLong, "text is longer than \(AssistantProtocol.maxSendTextLength)")
                }
                var replyTo: Int32?
                if let raw = params["reply_to_message_id"], raw != .null {
                    guard let value = raw.int64Value, (1...Int64(Int32.max)).contains(value) else {
                        throw AssistantFailure(.badParams, "reply_to_message_id must be a positive integer")
                    }
                    replyTo = Int32(value)
                }
                var encryption = AssistantSendEncryption.follow
                if let raw = params["encryption"], raw != .null {
                    guard let name = raw.stringValue, let value = AssistantSendEncryption(rawValue: name) else {
                        throw AssistantFailure(.badParams, "encryption must be one of follow, encrypted, plaintext")
                    }
                    encryption = value
                }
                return .success(.send(chatPeerId: chat, text: text, replyToMessageId: replyTo, encryption: encryption))
            case .read:
                return .success(.read(chatPeerId: try requiredInt(params, "chat_peer_id", range: Int64.min...Int64.max),
                                      messageId: Int32(try requiredInt(params, "message_id", range: 1...Int64(Int32.max)))))
            case .open:
                let chat = try requiredInt(params, "chat_peer_id", range: Int64.min...Int64.max)
                var messageId: Int32?
                if let raw = params["message_id"], raw != .null {
                    guard let value = raw.int64Value, (1...Int64(Int32.max)).contains(value) else {
                        throw AssistantFailure(.badParams, "message_id must be a positive integer")
                    }
                    messageId = Int32(value)
                }
                var accountPeerId: Int64?
                if let raw = params["account_peer_id"], raw != .null {
                    guard let value = raw.int64Value else {
                        throw AssistantFailure(.badParams, "account_peer_id must be an integer")
                    }
                    accountPeerId = value
                }
                return .success(.open(chatPeerId: chat, messageId: messageId, accountPeerId: accountPeerId))
            case .history:
                return .success(.history(
                    chatPeerId: try requiredInt(params, "chat_peer_id", range: Int64.min...Int64.max),
                    since: try requiredInt(params, "since", range: 0...Int64(Int32.max)),
                    limit: Int(try optionalInt(params, "limit", default: Int64(AssistantProtocol.defaultHistoryLimit),
                                               range: 1...Int64(AssistantProtocol.maxHistoryLimit)))))
            case .folders:
                return .success(.folders)
            case .folderUpdate:
                guard let name = params["action"]?.stringValue, let action = AssistantFolderAction(rawValue: name) else {
                    throw AssistantFailure(.badParams, "action must be one of create, rename, add, remove, set, delete")
                }
                var folderId: Int32?
                if action != .create {
                    folderId = Int32(try requiredInt(params, "folder_id", range: 1...Int64(Int32.max)))
                }
                var title: String?
                if action == .create || action == .rename {
                    let raw = try requiredString(params, "title").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { throw AssistantFailure(.badParams, "title is empty") }
                    guard raw.count <= AssistantProtocol.maxFolderTitleLength else {
                        throw AssistantFailure(.tooLong, "title is longer than \(AssistantProtocol.maxFolderTitleLength)")
                    }
                    title = raw
                }
                var peerIds: [Int64] = []
                if [.create, .add, .remove, .set].contains(action), let raw = params["peer_ids"], raw != .null {
                    guard let items = raw.arrayValue else { throw AssistantFailure(.badParams, "peer_ids must be an array of integers") }
                    for item in items {
                        guard let value = item.int64Value else { throw AssistantFailure(.badParams, "peer_ids must be an array of integers") }
                        if !peerIds.contains(value) { peerIds.append(value) }
                    }
                    guard peerIds.count <= AssistantProtocol.maxFolderPeers else {
                        throw AssistantFailure(.tooLong, "a folder holds at most \(AssistantProtocol.maxFolderPeers) chats")
                    }
                } else if [.add, .remove, .set].contains(action) {
                    throw AssistantFailure(.badParams, "peer_ids must be an array of integers")
                }
                return .success(.folderUpdate(action: action, folderId: folderId, title: title, peerIds: peerIds))
            case .media:
                let maxBytes = try optionalInt(params, "max_bytes", default: AssistantProtocol.maxMediaBytes, range: 1...Int64.max)
                return .success(.media(
                    chatPeerId: try requiredInt(params, "chat_peer_id", range: Int64.min...Int64.max),
                    messageId: Int32(try requiredInt(params, "message_id", range: 1...Int64(Int32.max))),
                    index: Int(try requiredInt(params, "index", range: 0...Int64(Int32.max))),
                    maxBytes: min(maxBytes, AssistantProtocol.maxMediaBytes)))
            }
        } catch let failure as AssistantFailure {
            return .failure(failure)
        } catch {
            return .failure(AssistantFailure(.badParams, "bad params"))
        }
    }

    private static func requiredString(_ params: [String: AssistantJSON], _ key: String) throws -> String {
        guard let value = params[key]?.stringValue else { throw AssistantFailure(.badParams, "\(key) must be a string") }
        return value
    }

    private static func requiredInt(_ params: [String: AssistantJSON], _ key: String, range: ClosedRange<Int64>) throws -> Int64 {
        guard let value = params[key]?.int64Value, range.contains(value) else {
            throw AssistantFailure(.badParams, "\(key) must be an integer in range")
        }
        return value
    }

    private static func optionalInt(_ params: [String: AssistantJSON], _ key: String, default fallback: Int64, range: ClosedRange<Int64>) throws -> Int64 {
        guard let raw = params[key], raw != .null else { return fallback }
        guard let value = raw.int64Value, range.contains(value) else {
            throw AssistantFailure(.badParams, "\(key) must be an integer in range")
        }
        return value
    }
}

/// Building the three kinds of outgoing line. Each returns the line WITHOUT its trailing newline.
public enum AssistantLine {
    public static func ok(id: AssistantJSON, result: [String: AssistantJSON]) -> String {
        return AssistantJSON.object(["id": id, "ok": .bool(true), "result": .object(result)]).encoded()
    }

    public static func error(id: AssistantJSON, _ failure: AssistantFailure) -> String {
        return AssistantJSON.object([
            "id": id, "ok": .bool(false),
            "error": .object(["code": .string(failure.code.rawValue), "message": .string(failure.message)]),
        ]).encoded()
    }

    public static func event(_ name: String, data: [String: AssistantJSON]) -> String {
        return AssistantJSON.object(["event": .string(name), "data": .object(data)]).encoded()
    }

    public static func request(id: String, op: AssistantOp, params: [String: AssistantJSON]) -> String {
        return AssistantJSON.object(["id": .string(id), "op": .string(op.rawValue), "params": .object(params)]).encoded()
    }
}
