import XCTest
@testable import SecutgCore

/// PLAN.md 3.17 rule 5: what a folded timeline draws as one line, and — far more important — what it must never
/// take off the screen. Ported from the Web reference (`src/secutg/ui/foldUndecryptable.test.ts`), whose
/// client-agnostic half this file's subject is a byte-for-byte port of.
final class UndecryptableFoldTests: XCTestCase {
    private static let day: Int32 = 20_260_101

    /// One unreadable incoming message from `alice`, on `day`, unless told otherwise.
    private func row(_ id: Int32, day: Int32 = UndecryptableFoldTests.day, senderId: String? = "alice",
                     isOutgoing: Bool = false, isFoldable: Bool = true) -> FoldRow {
        return FoldRow(id: id, day: day, senderId: senderId, isOutgoing: isOutgoing, isFoldable: isFoldable)
    }

    private func readable(_ id: Int32, day: Int32 = UndecryptableFoldTests.day, senderId: String? = "alice",
                         isOutgoing: Bool = false) -> FoldRow {
        return row(id, day: day, senderId: senderId, isOutgoing: isOutgoing, isFoldable: false)
    }

    // MARK: what counts as a run

    func testNothingAtAllFoldsNothing() {
        XCTAssertEqual(planUndecryptableFold([]), [])
    }

    func testALoneUnreadableMessageKeepsItsOwnExplanationLine() {
        // "1 message cannot be decrypted" costs the same line and says less than the line it replaces
        XCTAssertEqual(planUndecryptableFold([row(1)]), [])
        XCTAssertEqual(planUndecryptableFold([readable(1), row(2), readable(3)]), [])
    }

    func testTwoInARowAreAlreadyWorthOneLine() {
        XCTAssertEqual(planUndecryptableFold([row(1), row(2)]),
                       [FoldedRun(anchorId: 1, lastId: 2, count: 2, hiddenIds: [2])])
    }

    func testAWholeChatOfUnreadableMessagesIsOneRunNotOneLinePerMessage() {
        let runs = planUndecryptableFold([row(1), row(2), row(3), row(4), row(5)])
        XCTAssertEqual(runs, [FoldedRun(anchorId: 1, lastId: 5, count: 5, hiddenIds: [2, 3, 4, 5])])
    }

    func testAMessageThatOpensEndsTheRunAndDoesNotJoinTheNextOne() {
        let runs = planUndecryptableFold([row(1), row(2), readable(3), row(4), row(5)])
        XCTAssertEqual(runs.map { $0.count }, [2, 2])
        XCTAssertEqual(runs.map { $0.anchorId }, [1, 4])
        // the readable message is in neither run's shadow
        XCTAssertFalse(runs.flatMap { $0.hiddenIds }.contains(3))
    }

    func testTheCountIsTheWholeRunIncludingTheAnchorThatStaysOnScreen() {
        guard let run = planUndecryptableFold([row(1), row(2), row(3)]).first else { return XCTFail("no run") }
        XCTAssertEqual(run.count, 3)
        XCTAssertEqual(run.hiddenIds, [2, 3])
        XCTAssertEqual(run.count, run.hiddenIds.count + 1)
    }

    // MARK: the boundaries a run must not cross

    func testANewDayStartsANewRunSoTheDateSeparatorKeepsBothSides() {
        let rows = [row(1), row(2), row(3, day: Self.day + 1), row(4, day: Self.day + 1)]
        XCTAssertEqual(planUndecryptableFold(rows).map { $0.anchorId }, [1, 3])
    }

    func testADifferentSenderStartsANewRunWhoseMessagesTheseAreIsNotNoise() {
        let rows = [row(1), row(2), row(3, senderId: "bob"), row(4, senderId: "bob")]
        XCTAssertEqual(planUndecryptableFold(rows).map { $0.count }, [2, 2])
    }

    func testAMessageWithNoAuthorGroupsWithTheOtherMessagesWithNoAuthor() {
        // a channel post has no sender; two absences are the same author, as they are on screen
        let rows = [row(1, senderId: nil), row(2, senderId: nil)]
        XCTAssertEqual(planUndecryptableFold(rows).map { $0.count }, [2])
        XCTAssertEqual(planUndecryptableFold([row(1, senderId: nil), row(2)]), [])
    }

    func testOurOwnUnreadableMessagesDoNotMergeWithThePeersOnes() {
        let rows = [row(1), row(2), row(3, isOutgoing: true), row(4, isOutgoing: true)]
        XCTAssertEqual(planUndecryptableFold(rows).map { $0.anchorId }, [1, 3])
    }

    func testTheUnreadDividerIsNeverFoldedAway() {
        let rows = [row(1), row(2), row(3), row(4)]
        let runs = planUndecryptableFold(rows, firstUnreadId: 3)
        XCTAssertEqual(runs.map { $0.anchorId }, [1, 3])
        // message 3 draws the divider, so it must survive as an anchor rather than sit inside a fold
        XCTAssertFalse(runs.flatMap { $0.hiddenIds }.contains(3))
    }

    func testADividerThatLandsOnTheFirstMessageChangesNothing() {
        XCTAssertEqual(planUndecryptableFold([row(1), row(2), row(3)], firstUnreadId: 1),
                       [FoldedRun(anchorId: 1, lastId: 3, count: 3, hiddenIds: [2, 3])])
    }

    func testADividerOnAMessageThisChatDoesNotHoldChangesNothing() {
        XCTAssertEqual(planUndecryptableFold([row(1), row(2), row(3)], firstUnreadId: 99),
                       [FoldedRun(anchorId: 1, lastId: 3, count: 3, hiddenIds: [2, 3])])
    }

    func testABoundaryThatLeavesOnlyOneMessageOnASideFoldsNeither() {
        // 1 alone, then 2 alone: two runs of one, so the timeline is unchanged
        XCTAssertEqual(planUndecryptableFold([row(1), row(2, senderId: "bob")]), [])
        XCTAssertEqual(planUndecryptableFold([row(1), row(2, day: Self.day + 1)]), [])
        XCTAssertEqual(planUndecryptableFold([row(1), row(2, isOutgoing: true)]), [])
        XCTAssertEqual(planUndecryptableFold([row(1), row(2)], firstUnreadId: 2), [])
    }

    func testABoundaryThatLeavesOneOnOneSideStillFoldsTheOther() {
        // the short side keeps its explanation line, the long side folds: neither is lost
        let runs = planUndecryptableFold([row(1), row(2, senderId: "bob"), row(3, senderId: "bob")])
        XCTAssertEqual(runs, [FoldedRun(anchorId: 2, lastId: 3, count: 2, hiddenIds: [3])])
    }

    func testAGapInTimeIsDeliberatelyNotABoundary() {
        // breaking every ten minutes would cut one stretch into a pile of one- and two-message fragments and
        // give the reader more lines than the explanations they replaced
        let rows = (1...6).map { row(Int32($0)) }
        XCTAssertEqual(planUndecryptableFold(rows).map { $0.count }, [6])
    }

    // MARK: first and last

    func testARunAtTheVeryTopOfTheListFolds() {
        XCTAssertEqual(planUndecryptableFold([row(1), row(2), readable(3)]),
                       [FoldedRun(anchorId: 1, lastId: 2, count: 2, hiddenIds: [2])])
    }

    func testARunAtTheVeryBottomFoldsAndReportsTheNewestIdItCovers() {
        let runs = planUndecryptableFold([readable(1), row(2), row(3)])
        XCTAssertEqual(runs, [FoldedRun(anchorId: 2, lastId: 3, count: 2, hiddenIds: [3])])
    }

    func testLastIdIsTheLargestIdOfTheRunNotMerelyTheLastRow() {
        // service notifications and scheduled messages carry local ids, so render order is not id order, and
        // this value is a read watermark: only the largest id of the run is ever safe to report
        let runs = planUndecryptableFold([row(9), row(4)])
        XCTAssertEqual(runs.first?.anchorId, 9)
        XCTAssertEqual(runs.first?.lastId, 9)
    }

    func testEveryRunCoversItsWholeSpanSoNothingIsLeftUnread() {
        // the anchor plus the hidden ids are exactly the run, and `lastId` is the largest of them
        let runs = planUndecryptableFold([row(4), row(7), row(5), readable(8), row(11), row(10)])
        for run in runs {
            XCTAssertEqual(run.count, run.hiddenIds.count + 1)
            XCTAssertEqual(run.lastId, ([run.anchorId] + run.hiddenIds).max())
        }
        XCTAssertEqual(runs.map { $0.lastId }, [7, 11])
    }

    // MARK: opening a run, and closing it again

    private var mixedRows: [FoldRow] {
        return [row(1), row(2), row(3), readable(4), row(5), row(6)]
    }

    func testAnOpenedRunIsPlannedAwayEntirelyLeavingEveryMessageToItsOwnLine() {
        let runs = planUndecryptableFold(mixedRows, expandedAnchorIds: [1])
        XCTAssertEqual(runs.map { $0.anchorId }, [5])
    }

    func testOpeningOneRunLeavesTheOthersFolded() {
        let runs = planUndecryptableFold(mixedRows, expandedAnchorIds: [5])
        XCTAssertEqual(runs.map { $0.anchorId }, [1])
    }

    func testFoldingAgainIsTheSamePlanAsBeforeItWasOpened() {
        XCTAssertEqual(planUndecryptableFold(mixedRows, expandedAnchorIds: [1, 5]), [])
        XCTAssertEqual(planUndecryptableFold(mixedRows, expandedAnchorIds: []), planUndecryptableFold(mixedRows))
    }

    func testAnExpandedIdThatIsNotAnAnchorChangesNothing() {
        // the reader opened a run, then a key arrived and the runs were re-planned around it: a stale anchor
        // must not be able to unfold some other run that happens to be there now
        XCTAssertEqual(planUndecryptableFold(mixedRows, expandedAnchorIds: [2, 3, 99]),
                       planUndecryptableFold(mixedRows))
    }

    func testMinFoldRunIsTwo() {
        XCTAssertEqual(secutgMinFoldRun, 2)
    }
}
