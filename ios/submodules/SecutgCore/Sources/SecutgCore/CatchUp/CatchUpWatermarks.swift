import Foundation

/// PLAN.md 3.47 point 2 / point 5: per chat, the highest message id the catch-up pass has looked at.
///
/// Local state of this device only: kept in the app's own preferences beside the other secuTG records, never in
/// the keyring, so it never rides along in a backup or a transfer — another device has its own database and its
/// own idea of what it has looked at. Dropped by the emergency wipe with the rest of those records.
///
/// A missing or unreadable record means "never enabled": the runtime then records every chat in the list as owed a
/// bounded look-back (`firstEnabled`) and starts on them in the same pass. Until 2026-10-01 first enable set every
/// watermark straight to the chat's top, which left every row the extension had stored before that moment — no
/// secuTG meta, raw wire on disk — below the watermark for good (a real device lost a V2Q import's history to it).
public struct CatchUpWatermarks: Equatable {
    public static let version = 1

    /// Chat id (`SharedChatId` form) → highest message id looked at.
    public private(set) var marks: [String: Int32]
    /// Chats that were in the list at first enable and are still owed their look-back over the newest
    /// `CatchUp.firstEnableLookback` messages. A chat leaves the set when its watermark is first set.
    public private(set) var lookback: Set<String>

    public init(marks: [String: Int32] = [:], lookback: Set<String> = []) {
        let kept = marks.filter { $0.value > 0 && !$0.key.isEmpty }
        self.marks = kept
        self.lookback = lookback.filter { !$0.isEmpty && kept[$0] == nil }
    }

    public static func storageKey(accountKey: String) -> String {
        return "secutg.catchup.watermarks.\(accountKey)"
    }

    /// 0 for a chat never seen.
    public func floor(_ chatId: String) -> Int32 {
        return marks[chatId] ?? 0
    }

    /// Whether this chat's next scan is its first-enable look-back.
    public func isPendingLookback(_ chatId: String) -> Bool {
        return lookback.contains(chatId) && marks[chatId] == nil
    }

    /// First enable: no watermark yet, every chat with a message owed a look-back over its newest
    /// `CatchUp.firstEnableLookback` messages. The pass works through them under its usual budget; what it does
    /// not reach stays owed and is picked up by the next pass.
    public static func firstEnabled(_ chats: [CatchUp.ChatTop]) -> CatchUpWatermarks {
        return CatchUpWatermarks(marks: [:], lookback: Set(chats.filter { $0.topMessageId > 0 }.map { $0.chatId }))
    }

    /// Only ever upwards: a pass that lost a race with a later one must not pull the mark back. Setting a chat's
    /// mark ends its look-back.
    public func advancing(_ chatId: String, to messageId: Int32) -> CatchUpWatermarks {
        guard !chatId.isEmpty, messageId > floor(chatId) else { return self }
        var next = marks
        next[chatId] = messageId
        return CatchUpWatermarks(marks: next, lookback: lookback)
    }

    // MARK: codec

    /// `{"v":1,"marks":{"<chat id>":<id>},"lookback":["<chat id>",…]}`, `lookback` optional (absent when empty, and
    /// in every record written before it existed). nil for anything that is not that shape — read as "never
    /// enabled", which starts the bounded look-back again: idempotent, since a row the hook has written meta on is
    /// never a candidate. A single bad entry inside an otherwise good record is dropped on its own.
    public static func parse(_ text: String?) -> CatchUpWatermarks? {
        guard let data = text?.data(using: .utf8), let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any],
              let v = object["v"] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(), v.intValue == version,
              let rawMarks = object["marks"] as? [String: Any] else { return nil }
        var marks: [String: Int32] = [:]
        for (chatId, value) in rawMarks {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(), double > 0, double <= Double(Int32.max) else { continue }
            marks[chatId] = Int32(double)
        }
        let lookback = (object["lookback"] as? [Any] ?? []).compactMap { $0 as? String }
        return CatchUpWatermarks(marks: marks, lookback: Set(lookback))
    }

    public func serialize() -> String {
        var object: [String: Any] = ["v": CatchUpWatermarks.version, "marks": marks.mapValues { NSNumber(value: $0) }]
        if !lookback.isEmpty { object["lookback"] = lookback.sorted() }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"marks\":{},\"v\":1}" }
        return text
    }
}
