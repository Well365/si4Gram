import Foundation

/// PLAN.md 3.47: the rules of the iOS catch-up pass over messages that reached the database without passing the
/// receive hook — the Notification Service Extension pulls them from the server and writes them into the shared
/// Postbox while the app is suspended, and it carries no secuTG runtime, so `transformIncoming` never saw them.
///
/// Everything in here is pure and shared by both Apple copies of this package; the Postbox scan, the
/// `transformIncoming` call and the write-back are the iOS runtime's (`SecutgCatchUp.swift` in TelegramCore).
/// The rules:
///
///   - **which chats** — every chat whose top Cloud message id is above its watermark (`dueChats`), most recently
///     active first, so a pass cut short by its time budget has spent it where the user is about to look;
///   - **which messages** — above the watermark, never touched by the hook (no `SecutgTextMetaAttribute`), and a
///     secuTG wire by structure (`isCandidate`); anything else is ordinary text and is only stepped over;
///   - **in what order** — ascending id, because control messages are state transitions (a rekey before the
///     message encrypted under it);
///   - **how much** — at most `maxMessagesPerChat` candidates per chat per pass and about `passBudgetMs` per pass
///     (`slice`, `Budget`); what is left waits for the next pass, and the watermark only moves over what was done.
public enum CatchUp {
    /// "每个聊天每轮最多 500 条" (PLAN.md 3.47 point 2).
    public static let maxMessagesPerChat = 500
    /// "整轮有时间预算（如 2 秒）".
    public static let passBudgetMs: Int64 = 2_000
    /// How far down from the top one chat's scan reads per pass. Postbox only scans newest-first, so to start with
    /// the oldest message above the watermark the scan has to reach it; this bounds what one pass may read. A chat
    /// with more new messages than this since the last pass is reported `truncated` (see `Slice.truncated`).
    public static let scanWindowPerChat = 2_000
    /// How many passes may chain on their own when one ran out of budget with work left (`CatchUpGate`).
    public static let maxChainedPasses = 8
    /// First enable (2026-10-01 真机 fix): how far back each chat already in the list is looked at, newest first,
    /// before its watermark is set. The rows the extension stored before the pass existed carry no meta and would
    /// otherwise sit under the watermark forever. Equal to `maxMessagesPerChat`, so one chat's look-back always
    /// fits in one pass's share and the watermark goes straight to its top.
    public static let firstEnableLookback = 500

    // MARK: candidates

    /// A secuTG wire, judged by structure through the recognisers the send and receive paths already use — no
    /// prefix table of its own. `V2Dispatch.isProtocolWire` covers P2 / E2 / N2 / W2, v1's `E1:` ciphertext and
    /// (through `Rekey.isControlMessage`) R1 / P1 / U1 / N1 / G2 / GP1; `V2E2.isWire` adds the merely
    /// E2-shaped wire, which the receive hook claims too and stores as the 3.17 notice.
    ///
    /// `G1` (a group invite) is not here on purpose: it only ever travels inside an `E1:` envelope, which is
    /// what the hook opens, so a bare `G1:` in the database is text somebody typed.
    public static func isSecutgWire(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return V2Dispatch.isProtocolWire(text) || V2E2.isWire(text)
    }

    /// PLAN.md 3.47 point 3. `hasSecutgMeta` is whether the stored message carries a `SecutgTextMetaAttribute`:
    /// the receive hook writes one on every message it acts on — a control line (P2 included) gets `.control`, a
    /// decrypted or sealed message `.decrypted` / `.sealed`, a refusal `.undecryptable` — so a message with one
    /// has already been through the hook and is never processed twice. It also protects a decrypted message whose
    /// words happen to look like a wire: those carry `.decrypted`, and re-reading their text would destroy them.
    public static func isCandidate(text: String, hasSecutgMeta: Bool) -> Bool {
        return !hasSecutgMeta && isSecutgWire(text)
    }

    // MARK: rows that never passed the hook, outside this pass

    /// A secuTG *content* wire — v1's `E1:` ciphertext or an E2-shaped wire — by structure. Control lines are not
    /// content: they carry no words for a key to open.
    public static func isContentWire(_ text: String) -> Bool {
        if text.hasPrefix("E1:") { return E1Format.isEncrypted(text) }
        if text.hasPrefix("E2:") { return V2E2.isWire(text) }
        return false
    }

    /// What the stored row says about itself, reduced to the three facts the 3.17 sweep needs.
    public enum StoredMeta: Equatable {
        /// No `SecutgTextMetaAttribute`: the receive hook never saw it (the extension stored it).
        case unmarked
        /// `.undecryptable`: the hook tried and had no key.
        case undecryptable
        /// Any other kind: decrypted, sealed, control, plaintext, invite — already settled.
        case other
    }

    /// PLAN.md 3.17 point 3, widened 2026-10-01: which rows the re-decrypt sweep asks again when a key arrives.
    /// A refusal the hook wrote (any text, the hook only writes it for a wire), and a content wire the hook never
    /// saw at all — the row the extension stored while the app was in the background, which under the old rule
    /// was never re-opened. Never a settled row: a decrypted message whose words look like a wire is `.other`.
    public static func isRedecryptCandidate(text: String, stored: StoredMeta) -> Bool {
        switch stored {
        case .undecryptable: return !text.isEmpty
        case .unmarked: return isContentWire(text)
        case .other: return false
        }
    }

    /// The 3.17 notice detail for a row that never passed the hook and whose text is a secuTG wire: "not opened
    /// yet" (`not_ready`, the loading line), until the catch-up pass or the sweep writes its real verdict. nil for
    /// every other row. PLAN.md 3.17: a wire is never drawn as its own base64.
    public static let unmarkedWireNoticeDetail = "not_ready"

    public static func unmarkedWireNotice(text: String, hasSecutgMeta: Bool) -> String? {
        return isCandidate(text: text, hasSecutgMeta: hasSecutgMeta) ? unmarkedWireNoticeDetail : nil
    }

    // MARK: chats

    public struct ChatTop: Equatable {
        public let chatId: String
        public let topMessageId: Int32

        public init(chatId: String, topMessageId: Int32) {
            self.chatId = chatId
            self.topMessageId = topMessageId
        }
    }

    public struct DueChat: Equatable {
        public let chatId: String
        public let topMessageId: Int32
        /// Messages with an id above this are looked at; 0 for a chat the watermarks have never seen.
        public let floor: Int32
        /// A chat that was in the list at first enable and has not been looked back over yet: its scan stops at
        /// the newest `firstEnableLookback` messages instead of going down to the floor.
        public let isLookback: Bool

        public init(chatId: String, topMessageId: Int32, floor: Int32, isLookback: Bool = false) {
            self.chatId = chatId
            self.topMessageId = topMessageId
            self.floor = floor
            self.isLookback = isLookback
        }

        /// How many messages, newest first, this chat's scan may read in one pass.
        public var scanWindow: Int {
            return isLookback ? CatchUp.firstEnableLookback : CatchUp.scanWindowPerChat
        }
    }

    /// The chats with anything above their watermark, newest top first (ties: chat id, code-unit order, so the
    /// order is stable). A chat the watermarks have never seen starts at 0: it appeared after the first enable,
    /// and the case this pass exists for — a new contact's pairing invite arriving while the phone was locked —
    /// is exactly a chat like that. A chat still owed its first-enable look-back starts at 0 too, with the
    /// bounded window (`DueChat.isLookback`).
    public static func dueChats(_ chats: [ChatTop], marks: CatchUpWatermarks) -> [DueChat] {
        var due: [DueChat] = []
        var seen = Set<String>()
        for chat in chats where seen.insert(chat.chatId).inserted {
            let floor = marks.floor(chat.chatId)
            if chat.topMessageId > floor {
                due.append(DueChat(chatId: chat.chatId, topMessageId: chat.topMessageId, floor: floor,
                                   isLookback: marks.isPendingLookback(chat.chatId)))
            }
        }
        return due.sorted { a, b in
            if a.topMessageId != b.topMessageId { return a.topMessageId > b.topMessageId }
            return a.chatId.utf16.lexicographicallyPrecedes(b.chatId.utf16)
        }
    }

    // MARK: one chat's messages

    public struct Scanned: Equatable {
        public let id: Int32
        public let isCandidate: Bool

        public init(id: Int32, isCandidate: Bool) {
            self.id = id
            self.isCandidate = isCandidate
        }
    }

    public struct Slice: Equatable {
        /// Candidate ids to run through the receive hook, ascending.
        public let process: [Int32]
        /// Where the chat's watermark goes once `process` is done; nil = it stays.
        public let advanceTo: Int32?
        /// Candidates above the watermark left for the next pass (the per-chat cap was reached).
        public let remaining: Int
        /// The scan stopped at its window before reaching the watermark: messages between the watermark and the
        /// oldest scanned one were not seen by this pass and never will be by this mechanism (the watermark moves
        /// past them). Reported so the runtime can log it; PLAN.md 3.17's sweep still covers the content wires
        /// (`E1` / `E2`, `isRedecryptCandidate`) among them.
        public let truncated: Bool

        public init(process: [Int32], advanceTo: Int32?, remaining: Int, truncated: Bool) {
            self.process = process
            self.advanceTo = advanceTo
            self.remaining = remaining
            self.truncated = truncated
        }
    }

    /// One chat's share of a pass. `scanned` is whatever the newest-first scan returned (any order, duplicates
    /// tolerated); `reachedFloor` is whether the scan got down to a message at or below `floor` (or to the bottom
    /// of the chat). Ids at or below `floor` are ignored.
    ///
    /// The watermark advances to the highest scanned id when every candidate fits, and otherwise to the last
    /// candidate processed — never past one that was not, so the next pass starts exactly where this one stopped.
    /// Non-candidates in between need nothing and are passed over either way.
    public static func slice(scanned: [Scanned], floor: Int32, reachedFloor: Bool, limit: Int = maxMessagesPerChat) -> Slice {
        var byId: [Int32: Bool] = [:]
        for item in scanned where item.id > floor {
            byId[item.id] = (byId[item.id] ?? false) || item.isCandidate
        }
        let ascending = byId.keys.sorted()
        guard let top = ascending.last else {
            return Slice(process: [], advanceTo: nil, remaining: 0, truncated: false)
        }
        let candidates = ascending.filter { byId[$0] == true }
        let cap = max(0, limit)
        if candidates.count <= cap {
            return Slice(process: candidates, advanceTo: top, remaining: 0, truncated: !reachedFloor)
        }
        let process = Array(candidates.prefix(cap))
        return Slice(process: process, advanceTo: process.last, remaining: candidates.count - cap, truncated: !reachedFloor)
    }

    // MARK: time

    /// "整轮有时间预算": checked before each chat, so a pass may overrun by at most one chat's share (itself capped
    /// by `maxMessagesPerChat` and `scanWindowPerChat`).
    public struct Budget: Equatable {
        public let startedAtMs: Int64
        public let limitMs: Int64

        public init(startedAtMs: Int64, limitMs: Int64 = CatchUp.passBudgetMs) {
            self.startedAtMs = startedAtMs
            self.limitMs = limitMs
        }

        /// A clock that went backwards reads as "no time spent", never as "out of time".
        public func isExhausted(nowMs: Int64) -> Bool {
            return nowMs - startedAtMs >= limitMs
        }
    }
}
