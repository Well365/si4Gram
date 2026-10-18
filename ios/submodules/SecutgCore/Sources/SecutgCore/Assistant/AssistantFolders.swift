import Foundation

/// `folder_update`'s `action` (2026-10-08, the assistant's 自定义分组 = Telegram chat folders). Raw values are wire strings.
public enum AssistantFolderAction: String, CaseIterable, Equatable {
    case create, rename, add, remove, set, delete
}

/// One Telegram chat folder as the assistant sees it. `peerIds` are the chats the folder lists by hand
/// (`chat_peer_id`s, pinned ones first); `hasRules` = it also takes whole categories (all contacts, all groups, …)
/// or hides muted / read / archived chats, which the assistant shows but never changes; `shared` = a shared folder
/// (chat list link), which the assistant leaves to Telegram.
public struct AssistantFolder: Equatable {
    public let id: Int32
    public let title: String
    public let emoticon: String?
    public let peerIds: [Int64]
    public let hasRules: Bool
    public let shared: Bool

    public init(id: Int32, title: String, emoticon: String?, peerIds: [Int64], hasRules: Bool, shared: Bool) {
        self.id = id
        self.title = title
        self.emoticon = emoticon
        self.peerIds = peerIds
        self.hasRules = hasRules
        self.shared = shared
    }

    public var json: AssistantJSON {
        return .object([
            "id": .int(Int64(id)), "title": .string(title), "emoticon": emoticon.map { .string($0) } ?? .null,
            "peer_ids": .array(peerIds.map { .int($0) }), "has_rules": .bool(hasRules), "shared": .bool(shared),
        ])
    }
}

/// The pure part of `folder_update`: what a folder's hand-picked chat list becomes. The client applies the result
/// to TelegramCore's `ChatListFilterIncludePeers` (`setPeers`, which keeps the pins that are still listed).
public enum AssistantFolderEdit {
    /// `add` appends what is not listed yet; `remove` drops what is; `set` / `create` replace the list.
    /// `nil` = the action does not change the chat list (`rename`, `delete`).
    public static func peers(current: [Int64], action: AssistantFolderAction, peerIds: [Int64]) -> [Int64]? {
        switch action {
        case .create, .set:
            return peerIds
        case .add:
            return current + peerIds.filter { !current.contains($0) }
        case .remove:
            return current.filter { !peerIds.contains($0) }
        case .rename, .delete:
            return nil
        }
    }

    /// Why the client refuses an edit before touching anything, or nil. A shared folder is edited in Telegram only
    /// (its link members follow it); a list over the ceiling is `too_long`.
    public static func refusal(action: AssistantFolderAction, folderIsShared: Bool, resultingCount: Int?) -> AssistantFailure? {
        if folderIsShared && action != .create {
            return AssistantFailure(.refused, "shared folders are edited in Telegram")
        }
        if let count = resultingCount, count > AssistantProtocol.maxFolderPeers {
            return AssistantFailure(.tooLong, "a folder holds at most \(AssistantProtocol.maxFolderPeers) chats")
        }
        return nil
    }
}
