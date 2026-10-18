import Foundation

/// PLAN.md 3.45.2 "提及了我" / implementation plan C1.4 — run after decryption on the receive hook and by the offline
/// rescan, so an encrypted message is judged on its words exactly like a plain one.
///
/// Precedence: a `text_mention` entity naming this account > a `mention` entity whose `@name` is one of this
/// account's active usernames > the text fallback (`@username`, then a display name), which only runs when
/// `fallbackEnabled` AND the message was encrypted — a plain message's entities were set by the sender's client
/// and the server, an encrypted one's may have been lost in transit. Never a hit: this account's own messages,
/// a bot's, a channel broadcast.
///
/// Offsets and lengths are UTF-16 units, like Telegram's entities.
public enum MentionDetector {
    /// Display names shorter than this (in UTF-16 units, trimmed) are never matched as text: "A" would match
    /// everything.
    public static let minimumNameLength = 2

    public static func detect(text: String, entities: [AssistantEntity], selfPeerId: Int64, selfUsernames: [String],
                              selfDisplayNames: [String] = [], senderIsSelf: Bool, isBot: Bool, isChannel: Bool,
                              wasEncrypted: Bool, fallbackEnabled: Bool) -> AssistantMention? {
        if senderIsSelf || isBot || isChannel { return nil }
        let utf16 = Array(text.utf16)
        if let entity = entities.first(where: { $0.type == "text_mention" && $0.userPeerId == selfPeerId && valid($0, count: utf16.count) }) {
            return AssistantMention(kind: .entity, offset: entity.offset, length: entity.length)
        }
        let usernames = normalizedUsernames(selfUsernames)
        for entity in entities where entity.type == "mention" && valid(entity, count: utf16.count) {
            let slice = Array(utf16[entity.offset..<entity.offset + entity.length])
            guard let word = String(utf16CodeUnits: slice, count: slice.count).lowercasedIfValid else { continue }
            let name = word.hasPrefix("@") ? String(word.dropFirst()) : word
            if usernames.contains(name) {
                return AssistantMention(kind: .username, offset: entity.offset, length: entity.length)
            }
        }
        guard fallbackEnabled, wasEncrypted else { return nil }
        for username in usernames.sorted(by: { $0.count > $1.count }) {
            if let range = find("@" + username, in: utf16, requireBoundaryAfter: true) {
                return AssistantMention(kind: .username, offset: range.lowerBound, length: range.count)
            }
        }
        for name in selfDisplayNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.utf16.count >= minimumNameLength else { continue }
            if let range = find(trimmed, in: utf16, requireBoundaryAfter: false) {
                return AssistantMention(kind: .name, offset: range.lowerBound, length: range.count)
            }
        }
        return nil
    }

    private static func valid(_ entity: AssistantEntity, count: Int) -> Bool {
        return entity.offset >= 0 && entity.length > 0 && entity.offset + entity.length <= count
    }

    private static func normalizedUsernames(_ raw: [String]) -> [String] {
        var out: [String] = []
        for name in raw {
            var value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasPrefix("@") { value.removeFirst() }
            if !value.isEmpty, !out.contains(value) { out.append(value) }
        }
        return out
    }

    /// Case-insensitive search in UTF-16 units. A match must not sit inside a word: the unit before it is not a
    /// username character, and — for `@username`, or for a name whose edge is ASCII alphanumeric — neither is the
    /// unit after it. Names in scripts without spaces (中文) match as plain substrings.
    private static func find(_ needle: String, in haystack: [UInt16], requireBoundaryAfter: Bool) -> Range<Int>? {
        let target = Array(needle.lowercased().utf16)
        guard !target.isEmpty, target.count <= haystack.count else { return nil }
        let lowered = Array(String(utf16CodeUnits: haystack, count: haystack.count).lowercasedIfValid.map { Array($0.utf16) } ?? haystack)
        // Lowercasing can change length (rare scripts); fall back to exact units when it does.
        let source = lowered.count == haystack.count ? lowered : haystack
        var start = 0
        while start + target.count <= source.count {
            if Array(source[start..<start + target.count]) == target {
                let end = start + target.count
                let before = start > 0 ? source[start - 1] : nil
                let after = end < source.count ? source[end] : nil
                let firstIsWord = isWordUnit(target[0])
                let lastIsWord = isWordUnit(target[target.count - 1])
                let beforeOK = before.map { !(isWordUnit($0) && (firstIsWord || target[0] == UInt16(UInt8(ascii: "@")))) } ?? true
                let afterOK = after.map { !(isWordUnit($0) && (requireBoundaryAfter || lastIsWord)) } ?? true
                if beforeOK && afterOK { return start..<end }
            }
            start += 1
        }
        return nil
    }

    /// ASCII letters, digits and `_` — the characters a Telegram username is made of.
    private static func isWordUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: return true
        default: return false
        }
    }
}

private extension String {
    /// Lowercased, or nil for a string that came out of an invalid UTF-16 slice (a split surrogate pair).
    var lowercasedIfValid: String? {
        return unicodeScalars.contains("\u{FFFD}") ? nil : lowercased()
    }
}
