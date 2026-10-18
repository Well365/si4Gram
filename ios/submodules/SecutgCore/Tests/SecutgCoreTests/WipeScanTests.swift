import XCTest
@testable import SecutgCore

/// PLAN.md 3.22.3 (window + whole-message) and 3.22.5 (consumed marker).
final class WipeScanTests: XCTestCase {
    let now: Int64 = 1_800_000_000
    var day: Int64 { 24 * 60 * 60 }

    func candidate(_ id: Int64, _ text: String, ageDays: Int64 = 0) -> WipeScan.Candidate {
        return WipeScan.Candidate(id: id, text: text, date: now - ageDays * day)
    }

    func options(user: String = "u1", custom: String? = nil, consumed: WipeScan.Consumed? = nil) -> WipeScan.Options {
        return WipeScan.Options(nowSeconds: now, userId: user, customPhrase: custom, consumed: consumed)
    }

    func testFindsTheBuiltInPhraseInsideWindow() {
        let found = WipeScan.findTrigger([
            candidate(1, "hello"),
            candidate(2, WipePhrase.builtInPhrase, ageDays: 3),
        ], options: options())
        XCTAssertEqual(found?.id, 2)
    }

    func testIgnoresMessagesOlderThanThirtyDays() {
        // PLAN.md 3.22.3 rule 3: a phrase left lying around must not wipe a restored-from-backup device.
        let found = WipeScan.findTrigger([
            candidate(1, WipePhrase.builtInPhrase, ageDays: 31),
        ], options: options())
        XCTAssertNil(found)
        // Exactly at the boundary (30 days) still counts.
        let atEdge = WipeScan.findTrigger([
            candidate(1, WipePhrase.builtInPhrase, ageDays: 30),
        ], options: options())
        XCTAssertEqual(atEdge?.id, 1)
    }

    func testPicksNewestWhenSeveralMatch() {
        let found = WipeScan.findTrigger([
            candidate(1, WipePhrase.builtInPhrase, ageDays: 10),
            candidate(2, WipePhrase.builtInPhrase, ageDays: 2),
            candidate(3, WipePhrase.builtInPhrase, ageDays: 5),
        ], options: options())
        XCTAssertEqual(found?.id, 2)
    }

    func testSkipsTheAlreadyConsumedMessage() {
        // PLAN.md 3.22.5: the same message id is skipped so a device does not wipe itself every login.
        let consumed = WipeScan.Consumed(userId: "u1", messageId: 2, triggerDate: now - 2 * day, executedAt: now * 1000)
        let found = WipeScan.findTrigger([
            candidate(2, WipePhrase.builtInPhrase, ageDays: 2),
        ], options: options(consumed: consumed))
        XCTAssertNil(found)
    }

    func testANewPhraseMessageFiresAgainAfterAConsumedOne() {
        let consumed = WipeScan.Consumed(userId: "u1", messageId: 2, triggerDate: now - 5 * day, executedAt: now * 1000)
        let found = WipeScan.findTrigger([
            candidate(2, WipePhrase.builtInPhrase, ageDays: 5),
            candidate(9, WipePhrase.builtInPhrase, ageDays: 1),
        ], options: options(consumed: consumed))
        XCTAssertEqual(found?.id, 9)
    }

    func testConsumedMarkerFromAnotherAccountIsNotOursToSkip() {
        // The marker belongs to the account that wrote it (PLAN.md 3.22.5 / scan.ts comment).
        let consumed = WipeScan.Consumed(userId: "other", messageId: 2, triggerDate: now - 2 * day, executedAt: now * 1000)
        let found = WipeScan.findTrigger([
            candidate(2, WipePhrase.builtInPhrase, ageDays: 2),
        ], options: options(user: "u1", consumed: consumed))
        XCTAssertEqual(found?.id, 2)
    }

    func testTwoPhrasesInsideTheWindowDoNotPingPongTheWipeForever() {
        // 3.22.7 makes every hand wipe post a fresh phrase, so two of them sitting in Saved Messages is
        // the ordinary state, not a freak one. A marker that only remembered "skip id 20" sent the next
        // scan to #10 ("not 20, therefore new"), wipe, remember "skip id 10", back to #20, wipe — once
        // per login and once per five-minute pass, until the older one aged out. Up to thirty days.
        let both = [
            candidate(10, WipePhrase.builtInPhrase, ageDays: 3),
            candidate(20, WipePhrase.builtInPhrase, ageDays: 1),
        ]

        let first = WipeScan.findTrigger(both, options: options())
        XCTAssertEqual(first?.id, 20)

        // what the device stores on its way into the wipe
        let consumed = WipeScan.Consumed(userId: "u1", messageId: first!.id, triggerDate: first!.date,
                                         executedAt: now * 1000)
        XCTAssertNil(WipeScan.findTrigger(both, options: options(consumed: consumed)))
    }

    func testSameSecondPhrasesAreSeparatedByIdNotLeftToPingPong() {
        let tie = [
            candidate(10, WipePhrase.builtInPhrase, ageDays: 2),
            candidate(20, WipePhrase.builtInPhrase, ageDays: 2),
        ]
        let consumed = WipeScan.Consumed(userId: "u1", messageId: 20, triggerDate: now - 2 * day,
                                         executedAt: now * 1000)
        XCTAssertNil(WipeScan.findTrigger(tie, options: options(consumed: consumed)))
    }

    func testAMarkerFromBeforeTriggerDateExistedReArmsOnceInsteadOfGoingDeaf() {
        // An upgraded device reads triggerDate 0: every in-window phrase outranks it, so the newest one
        // fires one more time and that wipe writes a real date, shutting the loop. The opposite default —
        // "assume very new" — would leave the device deaf to a genuine trigger.
        let both = [
            candidate(10, WipePhrase.builtInPhrase, ageDays: 3),
            candidate(20, WipePhrase.builtInPhrase, ageDays: 1),
        ]
        let legacy = WipeScan.Consumed(userId: "u1", messageId: 20, triggerDate: 0, executedAt: now * 1000)

        let again = WipeScan.findTrigger(both, options: options(consumed: legacy))
        XCTAssertEqual(again?.id, 20)

        let repaired = WipeScan.Consumed(userId: "u1", messageId: again!.id, triggerDate: again!.date,
                                         executedAt: now * 1000)
        XCTAssertNil(WipeScan.findTrigger(both, options: options(consumed: repaired)))
    }

    func testCustomPhraseTrigger() {
        let custom = "open sesame twelve"
        let found = WipeScan.findTrigger([
            candidate(1, custom, ageDays: 1),
        ], options: options(custom: custom))
        XCTAssertEqual(found?.id, 1)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(WipeScan.findTrigger([candidate(1, "nothing here")], options: options()))
        XCTAssertNil(WipeScan.findTrigger([], options: options()))
    }
}
