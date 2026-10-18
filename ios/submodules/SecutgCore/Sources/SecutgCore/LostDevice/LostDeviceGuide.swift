import Foundation

/// PLAN.md 3.46.1: the pure half of 〔丢了设备？〕 — the page's step 3 list and the one local record it needs.
///
/// Step 3 names the private chats a lost device may still be able to read as this device: the chats this device
/// **imported by QR** (a 3.39.13 clone binding — the lost device may be the one that showed the code), and the chats
/// this device **showed a code for** (the lost device may be the one that scanned it). The first comes from the v2
/// bindings; the second has no trace anywhere else, so the share page writes a record of it: chat id and time,
/// never a key, a code or a safety number. The record is capped (`maxShownCodes`, newest kept, one entry per chat)
/// and goes with the emergency wipe (PLAN.md 3.16). Purely local; nothing here is sent anywhere.
public enum LostDeviceGuide {
    public static let maxShownCodes = 200

    public struct ShownCode: Equatable {
        public let chatId: String
        public let atMs: Int64

        public init(chatId: String, atMs: Int64) {
            self.chatId = chatId
            self.atMs = atMs
        }
    }

    public struct AffectedChat: Equatable {
        public let chatId: String
        /// This device holds a QR clone of the chat (imported by scanning).
        public let imported: Bool
        /// When this device last showed a code for it; nil = never.
        public let shownAtMs: Int64?

        public init(chatId: String, imported: Bool, shownAtMs: Int64?) {
            self.chatId = chatId
            self.imported = imported
            self.shownAtMs = shownAtMs
        }
    }

    public static func shownCodesKey(accountKey: String) -> String {
        return "secutg.lostDevice.shownCodes.\(accountKey)"
    }

    // MARK: the record

    /// Records one shown code: the chat's earlier entry (if any) is replaced, the list is kept newest first and
    /// cut to `maxShownCodes`.
    public static func recording(_ list: [ShownCode], chatId: String, atMs: Int64, cap: Int = maxShownCodes) -> [ShownCode] {
        guard !chatId.isEmpty else { return normalized(list, cap: cap) }
        return normalized(list.filter { $0.chatId != chatId } + [ShownCode(chatId: chatId, atMs: atMs)], cap: cap)
    }

    /// Newest first (ties: chat id, code-unit order), one entry per chat (its newest), at most `cap`.
    static func normalized(_ list: [ShownCode], cap: Int = maxShownCodes) -> [ShownCode] {
        var newest: [String: Int64] = [:]
        for entry in list where !entry.chatId.isEmpty {
            newest[entry.chatId] = max(newest[entry.chatId] ?? Int64.min, entry.atMs)
        }
        let sorted = newest.map { ShownCode(chatId: $0.key, atMs: $0.value) }.sorted { a, b in
            if a.atMs != b.atMs { return a.atMs > b.atMs }
            return a.chatId.utf16.lexicographicallyPrecedes(b.chatId.utf16)
        }
        return Array(sorted.prefix(max(0, cap)))
    }

    /// `[{"chat":"<id>","at":<ms>}]`; anything else reads as empty, a bad entry is dropped on its own.
    public static func parseShownCodes(_ text: String?) -> [ShownCode] {
        guard let data = text?.data(using: .utf8), let raw = try? JSONSerialization.jsonObject(with: data),
              let array = raw as? [Any] else { return [] }
        var out: [ShownCode] = []
        for item in array {
            guard let object = item as? [String: Any], let chatId = object["chat"] as? String, !chatId.isEmpty,
                  let number = object["at"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue == number.doubleValue.rounded() else { continue }
            out.append(ShownCode(chatId: chatId, atMs: number.int64Value))
        }
        return normalized(out)
    }

    public static func serializeShownCodes(_ list: [ShownCode]) -> String {
        let array = normalized(list).map { ["chat": $0.chatId, "at": NSNumber(value: $0.atMs)] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    // MARK: step 3

    /// The union of both sources, one row per chat: chats with a shown code first, newest first; then the
    /// imported-only ones in code-unit order. Saved Messages (`ownUserId`) and anything that is not a private chat
    /// are left out — step 3 is about pairings, and groups are step 4.
    public static func affectedChats(importedChatIds: [String], shownCodes: [ShownCode], ownUserId: String) -> [AffectedChat] {
        let imported = Set(importedChatIds.filter { isPrivateChat($0, ownUserId: ownUserId) })
        var rows: [AffectedChat] = []
        var listed = Set<String>()
        for code in normalized(shownCodes, cap: Int.max) where isPrivateChat(code.chatId, ownUserId: ownUserId) {
            listed.insert(code.chatId)
            rows.append(AffectedChat(chatId: code.chatId, imported: imported.contains(code.chatId), shownAtMs: code.atMs))
        }
        let rest = imported.subtracting(listed).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        rows.append(contentsOf: rest.map { AffectedChat(chatId: $0, imported: true, shownAtMs: nil) })
        return rows
    }

    /// The chats with a current v2 binding that came from a QR clone — the same judgement as the check-up's
    /// item 6 (`SecurityAuditReader.isClonedBinding`), so the two pages never disagree about which chats these are.
    public static func importedChatIds(v2: V2Runtime?) -> [String] {
        guard let store = v2?.pairing.bindingStore else { return [] }
        return store.allChatIdsWithCurrentBinding()
            .filter { chatId in store.current(chatId).map(SecurityAuditReader.isClonedBinding) ?? false }
            .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    static func isPrivateChat(_ chatId: String, ownUserId: String) -> Bool {
        guard chatId != ownUserId, let decoded = SharedChatId.decode(chatId) else { return false }
        return decoded.kind == .user
    }
}
