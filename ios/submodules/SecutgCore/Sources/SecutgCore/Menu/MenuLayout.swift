import Foundation

/// SECUTG: PLAN.md 3.49 — the shared, pure description of how the secuTG lock menu's already-decided actions
/// group into sections, and which of them are red. This file is display-only plumbing: it builds no UI, keeps
/// no state, and decides nothing about whether an action applies to a given chat. Every client's existing
/// per-state logic still decides WHICH ids a chat offers — iOS `SecutgChatMenu.privatePrimary` / `groupPrimary`
/// / `privateMore` / `groupMore`, macOS `secutgPrivatePrimary` / `secutgGroupPrimary` / `secutgPrivateMore` and
/// the group's own inline `more` list. Handing this file an id nobody has decided to offer would only teach it
/// a second copy of a rule the per-state code already enforces, which PLAN.md 3.49's "不增减任何功能" rules out.
///
/// `sections(_:)` / `moreSections(_:)` take exactly the ids a caller has already decided this chat offers (in
/// whatever order the caller built them), and return them regrouped into the fixed sections of PLAN.md 3.49
/// rule 1 / rule 3, each internally ordered by the fixed rank tables below. An id neither table knows about
/// traps in DEBUG rather than being silently dropped — see `order`/`moreOrder` and the note on `group(_:order:)`.
///
/// Byte-identical between the iOS and macOS copies of SecutgCore (the one file PLAN.md 3.49 asks to keep that
/// way): the grouping and colour rules are product decisions, not platform ones, so there is exactly one
/// correct table and every client reads it rather than keeping its own.
public enum MenuLayout {

    /// The first level's five fixed sections, in display order (PLAN.md 3.49 rule 1).
    public enum Section: Int, CaseIterable, Sendable {
        case guide = 0          // ① 加密使用指南
        case status = 1         // ② 本聊天的状态与配对
        case keys = 2           // ③ 钥匙动作
        case chatSettings = 3   // ④ 本聊天设置
        case more = 4           // ⑤ 更多…
    }

    /// 更多…'s own three fixed sections (PLAN.md 3.49 rule 3).
    public enum MoreSection: Int, CaseIterable, Sendable {
        case view = 0     // 查看
        case backup = 1   // 备份
        case danger = 2   // 危险
    }

    /// Canonical action ids, matching Web's `canonicalIds` in `src/secutg/ui/menu-layout-expectations.json`
    /// (PLAN.md 3.49's shared, four-client contract) id for id. The raw value equals the real `Entry.id` /
    /// `ContextMenuItem` id used by iOS and macOS wherever one id already names the action unambiguously.
    ///
    /// Two raw ids are reused by more than one concrete menu entry, and this enum cannot tell those apart by
    /// string alone — callers resolve the ambiguity themselves, by construction, before they ever reach this
    /// file:
    /// - `showKey` (private chat's own key QR, section ③) is the very same `Entry.id`/`"showKey"` a GROUP's
    ///   manual-mode admin uses for the offline invite QR — but that one is `inviteOffline` here (its own, later
    ///   rank in section ③), because `groupPrimary`/`secutgGroupPrimary` is the only caller that ever offers it
    ///   and always means the group sense. `privatePrimary`/`secutgPrivatePrimary` is the only caller of the
    ///   private sense.
    /// - `import` is section ③'s `importKey` when a caller's own primary-level list offers it (a group's first
    ///   key, or a group member importing one) and `importManual` — the expectations table's own name for it —
    ///   when a caller's own "更多…" list offers it (a private chat's "导入对方密钥…"); the two never appear in
    ///   the same caller's id list, because they come from two different functions (`groupPrimary` vs.
    ///   `privateMore`), and callers map the "更多…" occurrence's real `"import"` id to `importManual` before
    ///   calling `moreSections`/`moreOrder`.
    ///
    /// `groupPw` is the one id with no handler of its own: PLAN.md 3.49 decision B's merged "群密码 · 已设置"
    /// row, which opens a small sheet over the untouched `groupPwChange` / `groupPwDisable` actions. A caller
    /// offers either the plain `groupPwSet` id (no password yet) or the merged `groupPw` id (one already set)
    /// — never both, and never the real `groupPwChange`/`groupPwDisable` ids directly at this level, which is
    /// exactly the layer this file does not re-decide.
    public enum Id: String, Sendable, CaseIterable {
        // ① guide
        case guide
        // ② 本聊天的状态与配对
        case toggle, safety, repair, repairHere, waiting, accept, pair, due
        // macOS only (PLAN.md 3.30 rule 1): accepting a group invite card from a private chat's own menu — the
        // same rank as the other pairing actions, which it is one of in spirit (there is no equivalent entry
        // on iOS/Android/Web today, so no per-state expectation table row names it).
        case inviteAccept
        // ③ 钥匙动作
        case chatKeyShare, manual, showKey, create
        case importKey = "import"
        case quickShareScan, quickShareImportFile, inviteOffline
        case groupPwSet, groupPw, groupPwUnlock, recreateGroupKey
        // ④ 本聊天设置
        case keyRequired, relay
        // ⑤ 更多…
        case more
        // 更多…: 查看
        case status, about, sponsor, announce
        // 更多…: 备份 — `importManual` is Web's own name for the "更多…" occurrence of `import` (see above)
        case transfer, importManual, importKeyring
        // 更多…: 危险 (grouping only — see `dangerIds` for which of these are actually coloured red)
        // PLAN.md 3.50 (2026-10-03): `resetChatLocal` (仅在本机重置本聊天的加密) ranks immediately before
        // `resetChat` (双方一起重置本聊天的加密, the pre-3.50 "一键恢复初始状态" entry, unchanged) — private
        // chats only, danger section always ends with this pair in this order.
        case rotate, unpair, resetChatLocal, resetChat, groupPwDisable
    }

    /// Fixed section + in-section rank for every id a caller's PRIMARY-level list may offer (PLAN.md 3.49 rule
    /// 1), verified against every state in `menu-layout-expectations.json`. Two ids sharing a rank (the five
    /// pairing-action ids, or `quickShareScan`/`quickShareImportFile`) are never both offered for the same chat
    /// state — `sections(_:)` is a stable sort, so if a caller ever did hand both, whichever came first in its
    /// own list would stay first.
    private static let order: [Id: (section: Section, rank: Int)] = [
        .guide: (.guide, 0),

        .toggle: (.status, 0),
        .safety: (.status, 1),
        .repair: (.status, 2), .repairHere: (.status, 2), .waiting: (.status, 2), .accept: (.status, 2), .pair: (.status, 2),
        .inviteAccept: (.status, 2),
        .due: (.status, 3),

        .chatKeyShare: (.keys, 0),
        .manual: (.keys, 1),
        .showKey: (.keys, 2),
        .create: (.keys, 3),
        .importKey: (.keys, 4),
        .quickShareScan: (.keys, 5), .quickShareImportFile: (.keys, 5),
        .inviteOffline: (.keys, 6),
        .groupPwSet: (.keys, 7), .groupPw: (.keys, 7),
        .groupPwUnlock: (.keys, 8),
        .recreateGroupKey: (.keys, 9),

        .keyRequired: (.chatSettings, 0),
        .relay: (.chatSettings, 1),

        .more: (.more, 0),
    ]

    /// Fixed section + in-section rank for every id a caller's "更多…" list may offer (PLAN.md 3.49 rule 3),
    /// verified against every state in `menu-layout-expectations.json`.
    private static let moreOrder: [Id: (section: MoreSection, rank: Int)] = [
        .status: (.view, 0), .about: (.view, 1), .sponsor: (.view, 2), .announce: (.view, 3),

        .transfer: (.backup, 0), .importManual: (.backup, 1), .importKeyring: (.backup, 1),

        .rotate: (.danger, 0), .unpair: (.danger, 1),
        .resetChatLocal: (.danger, 2), .resetChat: (.danger, 3),
        .groupPwDisable: (.danger, 4),
    ]

    /// PLAN.md 3.49 rule 2: the one red list, shared by every client. Everything in it is destructive wherever
    /// it is offered — on today's iOS most of these are already drawn that way; this is the list macOS and any
    /// future caller checks to catch up (`unpair` / `resetChat` were plain there before this change).
    ///
    /// `rotate` (换新密钥, the old-path admin's rekey, 更多…/危险) is deliberately NOT in this set even though
    /// PLAN.md 3.49's design doc sketches it inside a "危险（红）" bucket: it groups with the danger items —
    /// `moreOrder` puts it in `.danger` — but it was never drawn red on any client before this change and PLAN
    /// 3.49's own written rule 2 enumerates exactly seven ids, `rotate` not among them. Grouping and colour are
    /// two separate questions in this file on purpose.
    ///
    /// PLAN.md 3.50 (2026-10-03): `resetChatLocal` joins `resetChat` here — both red, private chats only.
    public static let dangerIds: Set<Id> = [.recreateGroupKey, .groupPwDisable, .unpair, .resetChatLocal, .resetChat, .repair, .repairHere, .due]

    public static func isDanger(_ id: Id) -> Bool {
        return dangerIds.contains(id)
    }

    /// Groups `ids` — exactly what a caller's own per-state logic already decided this chat's primary level
    /// offers, in any order — into PLAN.md 3.49 rule 1's five sections, in order, each internally ordered by
    /// `order`'s rank. A section nobody populated is simply absent from the result, so a caller draws a
    /// separator only between sections it actually has something for.
    public static func sections(_ ids: [Id]) -> [(section: Section, ids: [Id])] {
        return group(ids, order: order, sectionCount: Section.allCases.count, make: { Section(rawValue: $0)! })
    }

    /// Same, for a caller's "更多…" list (PLAN.md 3.49 rule 3).
    public static func moreSections(_ ids: [Id]) -> [(section: MoreSection, ids: [Id])] {
        return group(ids, order: moreOrder, sectionCount: MoreSection.allCases.count, make: { MoreSection(rawValue: $0)! })
    }

    /// Convenience for a caller that only wants the final flat order (iOS's action sheet draws no section
    /// headers of its own — PLAN.md 3.49 rule 6 just needs ordering there, not the boundaries).
    public static func order(_ ids: [Id]) -> [Id] {
        return sections(ids).flatMap { $0.ids }
    }

    public static func moreOrder(_ ids: [Id]) -> [Id] {
        return moreSections(ids).flatMap { $0.ids }
    }

    private static func group<S: RawRepresentable>(
        _ ids: [Id], order table: [Id: (section: S, rank: Int)], sectionCount: Int, make: (Int) -> S
    ) -> [(section: S, ids: [Id])] where S.RawValue == Int {
        var buckets: [Int: [(rank: Int, position: Int, id: Id)]] = [:]
        for (position, id) in ids.enumerated() {
            guard let placement = table[id] else {
                // A caller tried to lay out an id this table has no place for. PLAN.md 3.49 rule "每端一条纯函数
                // 测试" exists to catch exactly this before it ships — see `order`/`moreOrder` above for where to
                // add it. Release builds keep the id out rather than crash on it: a menu with one item silently
                // out of place is recoverable, a hard crash building the menu is not.
                assertionFailure("MenuLayout: \(id.rawValue) has no section — add it to the table before offering it.")
                continue
            }
            buckets[placement.section.rawValue, default: []].append((placement.rank, position, id))
        }
        var out: [(section: S, ids: [Id])] = []
        for index in 0..<sectionCount {
            guard let bucket = buckets[index], !bucket.isEmpty else { continue }
            let ordered = bucket
                .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.position < $1.position }
                .map { $0.id }
            out.append((make(index), ordered))
        }
        return out
    }
}
