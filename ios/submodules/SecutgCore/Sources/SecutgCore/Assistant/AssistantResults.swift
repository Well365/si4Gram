import Foundation

/// The `result` object of every op (PLAN.md 3.45.2 table), built in one place so the client and the protocol
/// fixtures come out of the same code.
public enum AssistantResults {
    public static func hello(build: String) -> [String: AssistantJSON] {
        return ["protocol": .int(AssistantProtocol.version), "build": .string(build)]
    }

    public struct Status: Equatable {
        public var account: AssistantPerson?
        public var online: Bool
        public var captureEnabled: Bool
        public var queuePending: Int
        public var dropped: Int64
        public var lastEventSeq: Int64
        /// Unix seconds (PLAN.md 3.45.2: only a `_ms` field is milliseconds).
        public var lastRescanAt: Int64?
        public var build: String
        /// PLAN.md 3.45.2 amendment 2026-10-02: every account logged in on this Mac, and which one is active.
        public var accounts: [AssistantAccountEntry]
        public var activeAccountPeerId: Int64?

        public init(account: AssistantPerson?, online: Bool, captureEnabled: Bool, queuePending: Int, dropped: Int64,
                    lastEventSeq: Int64, lastRescanAt: Int64?, build: String,
                    accounts: [AssistantAccountEntry] = [], activeAccountPeerId: Int64? = nil) {
            self.account = account
            self.online = online
            self.captureEnabled = captureEnabled
            self.queuePending = queuePending
            self.dropped = dropped
            self.lastEventSeq = lastEventSeq
            self.lastRescanAt = lastRescanAt
            self.build = build
            self.accounts = accounts
            self.activeAccountPeerId = activeAccountPeerId
        }
    }

    /// `account` is null while no account is signed in; `dropped` is the C1.10 addition to the PLAN's field list.
    /// `capture_enabled` is whether mentions of the active account are being captured right now (its switch is on
    /// and the interface serves); `accounts` / `active_account_peer_id` are the 2026-10-02 additions (several
    /// accounts on one Mac: which one is active, which ones have their switch on).
    public static func status(_ status: Status) -> [String: AssistantJSON] {
        return [
            "accounts": .array(status.accounts.map { $0.json }),
            "active_account_peer_id": .optionalInt(status.activeAccountPeerId),
            "account": status.account?.json ?? .null, "online": .bool(status.online),
            "capture_enabled": .bool(status.captureEnabled), "queue_pending": .int(Int64(status.queuePending)),
            "dropped": .int(status.dropped), "last_event_seq": .int(status.lastEventSeq),
            "last_rescan_at": .optionalInt(status.lastRescanAt), "build": .string(status.build),
        ]
    }

    public struct Contact: Equatable {
        public let person: AssistantPerson
        public let isContact: Bool

        public init(person: AssistantPerson, isContact: Bool) {
            self.person = person
            self.isContact = isContact
        }

        public var json: AssistantJSON {
            guard case var .object(fields) = person.json else { return person.json }
            fields["is_contact"] = .bool(isContact)
            return .object(fields)
        }
    }

    /// `generatedAt` is Unix seconds.
    public static func directory(generatedAt: Int64, chats: [(chat: AssistantChat, muted: Bool)], contacts: [Contact]) -> [String: AssistantJSON] {
        return [
            "generated_at": .int(generatedAt),
            "chats": .array(chats.map { $0.chat.directoryJSON(muted: $0.muted) }),
            "contacts": .array(contacts.map { $0.json }),
        ]
    }

    /// `subscribe` answers before the replay starts: how many stored events follow, and the newest seq.
    public static func subscribe(replaying: Int, lastEventSeq: Int64) -> [String: AssistantJSON] {
        return ["replaying": .int(Int64(replaying)), "last_event_seq": .int(lastEventSeq)]
    }

    public static func context(messages: [AssistantMessage]) -> [String: AssistantJSON] {
        return ["messages": .array(messages.map { $0.json })]
    }

    /// `history` (PLAN.md 3.45.4 C): oldest first; `truncated` = the chat has more messages since `since` than were
    /// returned (these are the newest ones).
    public static func history(messages: [AssistantMessage], truncated: Bool) -> [String: AssistantJSON] {
        return ["messages": .array(messages.map { $0.json }), "truncated": .bool(truncated)]
    }

    /// `folders` (2026-10-08): the account's chat folders in Telegram's order.
    public static func folders(_ folders: [AssistantFolder]) -> [String: AssistantJSON] {
        return ["folders": .array(folders.map { $0.json })]
    }

    /// `folder_update`: the folder as it is now; after `delete`, `{"deleted": <id>}`.
    public static func folder(_ folder: AssistantFolder) -> [String: AssistantJSON] {
        return ["folder": folder.json]
    }

    public static func folderDeleted(id: Int32) -> [String: AssistantJSON] {
        return ["deleted": .int(Int64(id))]
    }

    public static func send(localMessageId: Int32) -> [String: AssistantJSON] {
        return ["local_message_id": .int(Int64(localMessageId))]
    }

    public static let empty: [String: AssistantJSON] = [:]
}
