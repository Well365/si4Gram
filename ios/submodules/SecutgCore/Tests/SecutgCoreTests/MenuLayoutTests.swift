import XCTest
@testable import SecutgCore

/// PLAN.md 3.49: `MenuLayout` only groups/orders ids a caller already decided to offer — it never decides
/// presence — so these tests are about the grouping rules themselves (section order, in-section rank
/// stability, the red list) rather than about any one chat state. `MenuLayoutExpectationsTests` in this same
/// target asserts the full per-state table against `menu-layout-expectations.json`; this file guards the rank
/// tables `MenuLayout` itself is built from, independently of that fixture.
final class MenuLayoutTests: XCTestCase {
    func testSectionsComeOutInFixedOrder() {
        // Handed out of order on purpose: `sections` must still return them ①→⑤.
        let ids: [MenuLayout.Id] = [.more, .keyRequired, .due, .toggle, .guide, .recreateGroupKey]
        let sections = MenuLayout.sections(ids)
        XCTAssertEqual(sections.map { $0.section }, [.guide, .status, .keys, .chatSettings, .more])
        XCTAssertEqual(sections[0].ids, [.guide])
        XCTAssertEqual(sections[1].ids, [.toggle, .due])
        XCTAssertEqual(sections[2].ids, [.recreateGroupKey])
        XCTAssertEqual(sections[3].ids, [.keyRequired])
        XCTAssertEqual(sections[4].ids, [.more])
    }

    func testEmptySectionsAreOmittedNotPadded() {
        let sections = MenuLayout.sections([.guide, .more])
        XCTAssertEqual(sections.map { $0.section }, [.guide, .more])
    }

    func testStatusSectionOrdersToggleThenSafetyThenPairingActionThenDue() {
        // Rule: toggle, safety, one-of(repair/repairHere/waiting/accept/pair), due. `showKey` moved to section
        // ③ (PLAN.md 3.49, verified against menu-layout-expectations.json's private_key_changed /
        // private_other_device / private_manual_no_pairing states, each of which puts it in its own bucket
        // after section ②'s toggle+pairing-action, not inside section ②).
        let ids: [MenuLayout.Id] = [.due, .repair, .safety, .toggle]
        XCTAssertEqual(MenuLayout.order(ids), [.toggle, .safety, .repair, .due])
    }

    func testKeysSectionOrder() {
        // chatKeyShare, manual, showKey, create, import, quickShareScan(+quickShareImportFile), inviteOffline,
        // groupPwSet|groupPw, groupPwUnlock, recreateGroupKey (PLAN.md 3.49, menu-layout-expectations.json).
        let ids: [MenuLayout.Id] = [
            .recreateGroupKey, .groupPwUnlock, .groupPw, .inviteOffline, .quickShareImportFile, .quickShareScan,
            .importKey, .create, .showKey, .manual, .chatKeyShare,
        ]
        XCTAssertEqual(MenuLayout.order(ids), [
            .chatKeyShare, .manual, .showKey, .create, .importKey, .quickShareImportFile, .quickShareScan,
            .inviteOffline, .groupPw, .groupPwUnlock, .recreateGroupKey,
        ])
    }

    func testMoreSectionsAreViewBackupDanger() {
        let ids: [MenuLayout.Id] = [.resetChat, .status, .transfer, .unpair, .about, .resetChatLocal]
        let sections = MenuLayout.moreSections(ids)
        XCTAssertEqual(sections.map { $0.section }, [.view, .backup, .danger])
        XCTAssertEqual(sections[0].ids, [.status, .about])
        XCTAssertEqual(sections[1].ids, [.transfer])
        // PLAN.md 3.50: `resetChatLocal` (仅在本机) ranks immediately before `resetChat` (双方一起).
        XCTAssertEqual(sections[2].ids, [.unpair, .resetChatLocal, .resetChat])
    }

    func testMoreBackupOrdersTransferThenImportManual() {
        // `importManual` is the expectations table's name for "更多…"'s own `import` occurrence (a private
        // chat's "导入对方密钥…") — callers remap the real "import" id to it before calling `moreSections`.
        XCTAssertEqual(MenuLayout.moreOrder([.importManual, .transfer]), [.transfer, .importManual])
    }

    func testDangerListIsExactlyTheEightIdsPlan349And350Name() {
        // PLAN.md 3.49's original seven, plus `resetChatLocal` (PLAN.md 3.50, 2026-10-03): 「仅在本机重置本聊天的
        // 加密」 joins `resetChat` in the red "更多…/危险" list, private chats only.
        XCTAssertEqual(MenuLayout.dangerIds, [.recreateGroupKey, .groupPwDisable, .unpair, .resetChatLocal, .resetChat, .repair, .repairHere, .due])
        // `rotate` groups with the danger section (it is in `moreOrder`'s `.danger` bucket) but is not red —
        // verified against every state in menu-layout-expectations.json: `rotate` never appears in a state's
        // top-level `danger` list even when it is offered.
        XCTAssertFalse(MenuLayout.isDanger(.rotate))
    }

    func testStableSortKeepsCallerOrderWithinASharedRank() {
        // `quickShareScan`/`quickShareImportFile` share a rank (never both offered for one chat state in the
        // expectations table, but the sort must still be stable rather than relying on it).
        XCTAssertEqual(MenuLayout.order([.quickShareImportFile, .quickShareScan]), [.quickShareImportFile, .quickShareScan])
        XCTAssertEqual(MenuLayout.order([.quickShareScan, .quickShareImportFile]), [.quickShareScan, .quickShareImportFile])
    }
}
