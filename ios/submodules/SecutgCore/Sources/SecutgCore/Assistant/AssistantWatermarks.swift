import Foundation

/// PLAN.md 3.45.2 "不漏" / implementation plan C1.6–C1.7: everything the client keeps in `watermarks.json`.
///
/// - `seq` / `dropped`: the queue's counters (`AssistantEventQueue`).
/// - `capture_since`: Unix seconds when capture was first switched on; nothing older is ever an event, so turning
///   the switch on does not replay a chat's whole history.
/// - `chats`: chat peer_id → `last_scanned_message_id`, how far the offline rescan has looked.
/// - `emitted`: chat peer_id → message ids above that watermark already turned into events by the live hook, so the
///   rescan that later passes them does not emit them twice. Pruned as the watermark moves past them.
/// - `last_rescan_at`: Unix ms of the last finished rescan, or null.
/// - `account`: the account peer id every other field belongs to. Message ids of private chats and basic groups
///   are per account, and the queue holds that account's decrypted words, so files written for another account (or
///   for none — a file from before this field) are never used: `rebound(to:)` keeps only the counters, and the
///   glue deletes the queue with it.
public struct AssistantWatermarks: Equatable {
    public static let rescanFirstDelaySeconds: Double = 30
    public static let rescanIntervalSeconds: Double = 600
    public static let rescanPerChatLimit = 500
    /// A chat keeps at most this many emitted ids above its watermark (oldest go first).
    public static let emittedPerChatCap = 256
    /// How long the rescan keeps a chat's watermark below something it could not look at yet (a row it could not
    /// open, a history hole): a key or a hole fill that comes later than this is not waited for.
    public static let pinSeconds: Int64 = 7 * 24 * 60 * 60

    public var accountPeerId: Int64?
    public var seq: Int64
    public var dropped: Int64
    public var captureSince: Int64
    public var lastRescanAtMs: Int64?
    public var chats: [Int64: Int32]
    public var emitted: [Int64: [Int32]]

    public init(accountPeerId: Int64? = nil, seq: Int64 = 0, dropped: Int64 = 0, captureSince: Int64 = 0, lastRescanAtMs: Int64? = nil,
                chats: [Int64: Int32] = [:], emitted: [Int64: [Int32]] = [:]) {
        self.accountPeerId = accountPeerId
        self.seq = seq
        self.dropped = dropped
        self.captureSince = captureSince
        self.lastRescanAtMs = lastRescanAtMs
        self.chats = chats
        self.emitted = emitted
    }

    /// Should a message be judged at all? Not when it predates capture, sits at or below the chat's watermark
    /// (the rescan has already judged it), or has already been emitted.
    public func shouldConsider(chat: Int64, messageId: Int32, date: Int32) -> Bool {
        guard Int64(date) >= captureSince else { return false }
        if let mark = chats[chat], messageId <= mark { return false }
        return !(emitted[chat]?.contains(messageId) ?? false)
    }

    public mutating func markEmitted(chat: Int64, messageId: Int32) {
        var ids = emitted[chat] ?? []
        guard !ids.contains(messageId) else { return }
        ids.append(messageId)
        ids.sort()
        if ids.count > AssistantWatermarks.emittedPerChatCap { ids.removeFirst(ids.count - AssistantWatermarks.emittedPerChatCap) }
        emitted[chat] = ids
    }

    /// The rescan's question for one chat: nil when its newest message is not above the watermark (nothing new);
    /// otherwise the exclusive floor to scan down to (0 for a chat never scanned).
    public func rescanFloor(chat: Int64, topMessageId: Int32) -> Int32? {
        let mark = chats[chat] ?? 0
        return topMessageId > mark ? mark : nil
    }

    /// After a chat was scanned up to `topMessageId`. Never moves backwards; drops emitted ids now covered.
    public mutating func advance(chat: Int64, to topMessageId: Int32) {
        let mark = max(chats[chat] ?? 0, topMessageId)
        chats[chat] = mark
        if let ids = emitted[chat] {
            let left = ids.filter { $0 > mark }
            emitted[chat] = left.isEmpty ? nil : left
        }
    }

    /// The same file for `account`: the queue counters stay (so `seq` never goes back and a subscriber's position
    /// stays meaningful), everything that described the previous account's chats goes.
    public func rebound(to account: Int64?) -> AssistantWatermarks {
        return AssistantWatermarks(accountPeerId: account, seq: seq, dropped: dropped)
    }

    /// One message the rescan looked at: its id, its date, and whether its words could be read (false for a row
    /// that could not be opened or a group still locked — not for media or control lines, which never will be).
    public struct Scanned: Equatable {
        public let id: Int32
        public let date: Int32
        public let readable: Bool

        public init(id: Int32, date: Int32, readable: Bool) {
            self.id = id
            self.date = date
            self.readable = readable
        }
    }

    /// How far a chat's watermark may move after a rescan pass that looked at `scanned` (any order) between
    /// `lowerBound` (exclusive: the old watermark, the last message older than capture, or the bottom of what is
    /// stored) and `top`. It stops just below
    /// - the oldest message it could not read, so a key that arrives later gets it judged again;
    /// - the lowest history hole in that range, so messages Postbox fills in later are judged when they land
    ///   (the receive tap) or on the next pass — `scanTopMessages` walks straight over holes.
    /// Either only while it is younger than `pinSeconds` (a hole is dated by the stored message just above it).
    public static func rescanTarget(top: Int32, lowerBound: Int32, scanned: [Scanned], holes: IndexSet, now: Int64) -> Int32 {
        let oldestPinned = now - pinSeconds
        var target = top
        for message in scanned where !message.readable && Int64(message.date) >= oldestPinned && message.id > lowerBound {
            target = min(target, message.id - 1)
        }
        let byId = scanned.sorted { $0.id < $1.id }
        for range in holes.rangeView {
            let low = Int64(range.lowerBound)
            let high = Int64(range.upperBound) - 1
            guard high > Int64(lowerBound), low <= Int64(top) else { continue }
            let first = Int32(max(low, Int64(lowerBound) + 1))
            let above = byId.first { Int64($0.id) > high }
            if let above, Int64(above.date) < oldestPinned { continue }
            target = min(target, first - 1)
        }
        return max(target, lowerBound)
    }

    // MARK: file form

    public var json: AssistantJSON {
        var chatFields: [String: AssistantJSON] = [:]
        for (chat, mark) in chats { chatFields[String(chat)] = .int(Int64(mark)) }
        var emittedFields: [String: AssistantJSON] = [:]
        for (chat, ids) in emitted where !ids.isEmpty { emittedFields[String(chat)] = .array(ids.map { .int(Int64($0)) }) }
        return .object([
            "version": .int(1), "account": .optionalInt(accountPeerId), "seq": .int(seq), "dropped": .int(dropped), "capture_since": .int(captureSince),
            "last_rescan_at": .optionalInt(lastRescanAtMs), "chats": .object(chatFields), "emitted": .object(emittedFields),
        ])
    }

    /// Lenient: a field that is missing or malformed reads as its default, so a damaged file costs at most a
    /// rescan, never a crash or a refusal to start.
    public init(json: AssistantJSON) {
        self.init()
        accountPeerId = json["account"]?.int64Value
        seq = max(0, json["seq"]?.int64Value ?? 0)
        dropped = max(0, json["dropped"]?.int64Value ?? 0)
        captureSince = max(0, json["capture_since"]?.int64Value ?? 0)
        lastRescanAtMs = json["last_rescan_at"]?.int64Value
        for (key, value) in json["chats"]?.objectValue ?? [:] {
            guard let chat = Int64(key), let mark = value.int64Value, let id = Int32(exactly: mark) else { continue }
            chats[chat] = id
        }
        for (key, value) in json["emitted"]?.objectValue ?? [:] {
            guard let chat = Int64(key) else { continue }
            let ids = (value.arrayValue ?? []).compactMap { $0.int64Value.flatMap { Int32(exactly: $0) } }
            if !ids.isEmpty { emitted[chat] = Array(Set(ids)).sorted() }
        }
    }
}

/// PLAN.md 3.45.2 event body limits: reply chain ≤ 5; context before = the 30 messages before the mention, none
/// older than 2 hours before it; context after = what arrives in the 2 minutes after the event, at most 30.
public enum AssistantContextPolicy {
    public static let replyChainMax = 5
    public static let beforeCount = 30
    public static let beforeWindowSeconds: Int32 = 2 * 60 * 60
    public static let afterWindowSeconds: Double = 120
    public static let afterMax = 30

    /// `candidates` in ascending order, all before the mention. Keeps the newest `count` of those no older than
    /// `window` seconds before `mentionDate`, still ascending.
    public static func selectBefore<T>(_ candidates: [T], date: (T) -> Int32, mentionDate: Int32,
                                       count: Int = beforeCount, window: Int32 = beforeWindowSeconds) -> [T] {
        let floor = Int64(mentionDate) - Int64(window)
        let recent = candidates.filter { Int64(date($0)) >= floor }
        return Array(recent.suffix(max(0, count)))
    }

    /// `candidates` in ascending order, all after the mention: the ones already stored when the event is built
    /// (they arrived while it waited to be stored, or before an offline rescan found it). Keeps the oldest `count`
    /// of those no later than `window` seconds after `mentionDate`, still ascending; the live window adds the rest.
    public static func selectAfter<T>(_ candidates: [T], date: (T) -> Int32, mentionDate: Int32,
                                      count: Int = afterMax, window: Int32 = Int32(afterWindowSeconds)) -> [T] {
        let ceiling = Int64(mentionDate) + Int64(window)
        let early = candidates.filter { Int64(date($0)) <= ceiling }
        return Array(early.prefix(max(0, count)))
    }
}

/// PLAN.md 3.45.2 `send` / implementation plan C1.8: which error code a refused send gets. The same gates the
/// composer meets (3.38 group password, 3.41 key required, 3.0 fail-closed) are asked BEFORE anything is enqueued,
/// so a refused send leaves nothing in the chat. On top of them, the interface itself never carries protocol
/// lines, group invites or the wipe phrase (3.45.1: unpairing, rekeying, wiping are never open to the interface).
///
/// Phase 2 (C2.1) adds `send`'s `encryption`: `encrypted` needs a key and nothing else about the chat's switch;
/// `plaintext` is allowed only in a chat that would send in the clear anyway, so it can never be used to step
/// around 3.38 / 3.41 / 3.0 — every one of those answers `refused` for it.
public enum AssistantSendGate {
    public struct Facts: Equatable {
        public var utf16Length: Int
        public var isReservedText: Bool
        public var groupPasswordLocked: Bool
        public var keyRequiredRefuses: Bool
        public var encryptionStateUnknown: Bool
        public var encrypts: Bool
        public var hasSendKey: Bool
        public var maxPlaintextLength: Int
        /// 3.41.1's flag for this chat, whether or not a key is there right now.
        public var keyRequired: Bool
        /// The chat has an active group password (3.38), unlocked or not.
        public var hasGroupPassword: Bool

        public init(utf16Length: Int, isReservedText: Bool = false, groupPasswordLocked: Bool = false,
                    keyRequiredRefuses: Bool = false, encryptionStateUnknown: Bool = false, encrypts: Bool = false,
                    hasSendKey: Bool = true, maxPlaintextLength: Int = AssistantProtocol.maxSendTextLength,
                    keyRequired: Bool = false, hasGroupPassword: Bool = false) {
            self.utf16Length = utf16Length
            self.isReservedText = isReservedText
            self.groupPasswordLocked = groupPasswordLocked
            self.keyRequiredRefuses = keyRequiredRefuses
            self.encryptionStateUnknown = encryptionStateUnknown
            self.encrypts = encrypts
            self.hasSendKey = hasSendKey
            self.maxPlaintextLength = maxPlaintextLength
            self.keyRequired = keyRequired
            self.hasGroupPassword = hasGroupPassword
        }
    }

    public static func refusal(_ facts: Facts, encryption: AssistantSendEncryption = .follow) -> AssistantFailure? {
        if facts.utf16Length > AssistantProtocol.maxSendTextLength {
            return AssistantFailure(.tooLong, "text is longer than \(AssistantProtocol.maxSendTextLength)")
        }
        if facts.isReservedText { return AssistantFailure(.refused, "protocol lines, invites and the wipe phrase cannot be sent") }
        switch encryption {
        case .follow:
            if facts.groupPasswordLocked { return AssistantFailure(.locked, "group password is not unlocked") }
            if facts.keyRequiredRefuses { return AssistantFailure(.noKey, "chat requires a key and has none") }
            if facts.encryptionStateUnknown { return AssistantFailure(.refused, "chat encryption state is unknown") }
            if facts.encrypts && !facts.hasSendKey { return AssistantFailure(.noKey, "chat encrypts and has no key") }
            if facts.encrypts && facts.utf16Length > facts.maxPlaintextLength {
                return AssistantFailure(.tooLong, "text is longer than the encryption limit")
            }
        case .encrypted:
            if facts.groupPasswordLocked { return AssistantFailure(.locked, "group password is not unlocked") }
            if !facts.hasSendKey { return AssistantFailure(.noKey, "chat has no key to encrypt with") }
            if facts.utf16Length > facts.maxPlaintextLength {
                return AssistantFailure(.tooLong, "text is longer than the encryption limit")
            }
        case .plaintext:
            if facts.groupPasswordLocked || facts.hasGroupPassword {
                return AssistantFailure(.refused, "plaintext is not allowed in a chat with a group password")
            }
            if facts.keyRequired || facts.keyRequiredRefuses {
                return AssistantFailure(.refused, "plaintext is not allowed in a chat that requires a key")
            }
            if facts.encrypts || facts.encryptionStateUnknown {
                return AssistantFailure(.refused, "plaintext is not allowed in a chat that encrypts")
            }
        }
        return nil
    }
}
