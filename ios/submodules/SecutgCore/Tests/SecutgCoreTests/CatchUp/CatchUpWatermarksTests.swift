import Foundation
import XCTest
@testable import SecutgCore

/// PLAN.md 3.47 points 2 and 5: the per-chat watermark, its first initialisation and its stored form.
final class CatchUpWatermarksTests: XCTestCase {
    func testFirstEnableOwesEveryChatALookBackInsteadOfJumpingToTheTop() {
        let marks = CatchUpWatermarks.firstEnabled([
            CatchUp.ChatTop(chatId: "1", topMessageId: 40),
            CatchUp.ChatTop(chatId: "-7", topMessageId: 12),
            CatchUp.ChatTop(chatId: "1", topMessageId: 30),
            CatchUp.ChatTop(chatId: "9", topMessageId: 0),
        ])
        XCTAssertEqual(marks.marks, [:])
        XCTAssertEqual(marks.lookback, ["1", "-7"])
        XCTAssertTrue(marks.isPendingLookback("1"))
        XCTAssertFalse(marks.isPendingLookback("9"))
        // every chat is due right after it, from 0, with the bounded window
        let due = CatchUp.dueChats([CatchUp.ChatTop(chatId: "1", topMessageId: 40), CatchUp.ChatTop(chatId: "-7", topMessageId: 12)], marks: marks)
        XCTAssertEqual(due, [
            CatchUp.DueChat(chatId: "1", topMessageId: 40, floor: 0, isLookback: true),
            CatchUp.DueChat(chatId: "-7", topMessageId: 12, floor: 0, isLookback: true),
        ])
        XCTAssertEqual(due.map { $0.scanWindow }, [CatchUp.firstEnableLookback, CatchUp.firstEnableLookback])
        XCTAssertEqual(CatchUp.firstEnableLookback, 500)
    }

    func testSettingAChatsMarkEndsItsLookBackAndTheRestStayOwed() {
        let first = CatchUpWatermarks.firstEnabled([CatchUp.ChatTop(chatId: "1", topMessageId: 40), CatchUp.ChatTop(chatId: "2", topMessageId: 9)])
        // the pass ran out of budget after chat 1: chat 2 is still owed its look-back on the next pass
        let next = first.advancing("1", to: 40)
        XCTAssertEqual(next.marks, ["1": 40])
        XCTAssertEqual(next.lookback, ["2"])
        let due = CatchUp.dueChats([CatchUp.ChatTop(chatId: "1", topMessageId: 41), CatchUp.ChatTop(chatId: "2", topMessageId: 9)], marks: next)
        XCTAssertEqual(due, [
            CatchUp.DueChat(chatId: "1", topMessageId: 41, floor: 40),
            CatchUp.DueChat(chatId: "2", topMessageId: 9, floor: 0, isLookback: true),
        ])
        XCTAssertEqual(due.first?.scanWindow, CatchUp.scanWindowPerChat)
        // survives the stored form
        XCTAssertEqual(CatchUpWatermarks.parse(next.serialize()), next)
    }

    func testAChatThatAppearedAfterFirstEnableIsNotALookBack() {
        let marks = CatchUpWatermarks.firstEnabled([CatchUp.ChatTop(chatId: "1", topMessageId: 40)]).advancing("1", to: 40)
        let due = CatchUp.dueChats([CatchUp.ChatTop(chatId: "new", topMessageId: 3)], marks: marks)
        XCTAssertEqual(due, [CatchUp.DueChat(chatId: "new", topMessageId: 3, floor: 0)])
        XCTAssertFalse(due[0].isLookback)
    }

    func testLookBackCodec() {
        let marks = CatchUpWatermarks(marks: ["1": 40], lookback: ["2", "-3", "1", ""])
        XCTAssertEqual(marks.lookback, ["2", "-3"]) // a chat with a mark or an empty id is never owed one
        let text = marks.serialize()
        XCTAssertEqual(text, "{\"lookback\":[\"-3\",\"2\"],\"marks\":{\"1\":40},\"v\":1}")
        XCTAssertEqual(CatchUpWatermarks.parse(text), marks)
        // a record written before the field existed, and one with junk in it
        XCTAssertEqual(CatchUpWatermarks.parse("{\"v\":1,\"marks\":{\"1\":5}}")?.lookback, [])
        XCTAssertEqual(CatchUpWatermarks.parse("{\"v\":1,\"marks\":{},\"lookback\":[\"7\",3,true,null]}")?.lookback, ["7"])
        XCTAssertEqual(CatchUpWatermarks.parse("{\"v\":1,\"marks\":{},\"lookback\":\"7\"}")?.lookback, [])
    }

    func testAdvanceOnlyGoesUp() {
        let marks = CatchUpWatermarks(marks: ["1": 40])
        XCTAssertEqual(marks.advancing("1", to: 50).floor("1"), 50)
        XCTAssertEqual(marks.advancing("1", to: 30).floor("1"), 40)
        XCTAssertEqual(marks.advancing("2", to: 3).floor("2"), 3)
        XCTAssertEqual(marks.advancing("", to: 3), marks)
        XCTAssertEqual(marks.floor("unknown"), 0)
    }

    func testRoundTrip() {
        let marks = CatchUpWatermarks(marks: ["1": 40, "-1000000000123": 2_000_000_000])
        let text = marks.serialize()
        XCTAssertEqual(text, "{\"marks\":{\"-1000000000123\":2000000000,\"1\":40},\"v\":1}")
        XCTAssertEqual(CatchUpWatermarks.parse(text), marks)
        XCTAssertEqual(CatchUpWatermarks.parse(CatchUpWatermarks().serialize()), CatchUpWatermarks())
    }

    func testUnreadableRecordMeansNeverEnabled() {
        for text in [nil, "", "[]", "{}", "{\"v\":2,\"marks\":{}}", "{\"v\":true,\"marks\":{}}", "{\"v\":1}", "{\"v\":1,\"marks\":[]}", "not json"] {
            XCTAssertNil(CatchUpWatermarks.parse(text), text ?? "nil")
        }
    }

    func testBadEntriesAreDroppedOneByOne() {
        let parsed = CatchUpWatermarks.parse("{\"v\":1,\"marks\":{\"1\":5,\"2\":\"x\",\"3\":true,\"4\":1.5,\"5\":-1,\"6\":99999999999,\"7\":0}}")
        XCTAssertEqual(parsed?.marks, ["1": 5])
    }

    func testStorageKeyIsPerAccount() {
        XCTAssertEqual(CatchUpWatermarks.storageKey(accountKey: "42"), "secutg.catchup.watermarks.42")
    }
}
