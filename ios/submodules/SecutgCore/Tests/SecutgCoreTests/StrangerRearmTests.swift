import XCTest
@testable import SecutgCore

/// PLAN.md 3.23.7: the re-arm table, one test per row, plus the two helpers the placement is fed from.
///
/// Columns of the table: prev / next contact state, whether the chat is marked, whether the peer has written
/// after the boundary, whether this account has. `observe` answers the two rows that move the mark on a contact
/// change (1 and 5); `placement` answers the rows that decide what a marked chat draws (2, 3, 4) and the row
/// without a mark (6).
final class StrangerRearmTests: XCTestCase {
    // MARK: row 1 — 是 → 否: clear the decisions, mark, record the boundary

    func testRemovingAContactArms() {
        XCTAssertEqual(StrangerRearm.observe(wasContact: true, isContact: false, isMarked: false), .arm)
    }

    func testRemovingAContactArmsEvenIfAMarkIsSomehowAlreadyThere() {
        // A fresh removal always restarts the mark with a fresh boundary; a stale mark must not keep an old one.
        XCTAssertEqual(StrangerRearm.observe(wasContact: true, isContact: false, isMarked: true), .arm)
    }

    // MARK: row 5 — 否 → 是 with a mark: clear the mark, show nothing

    func testAContactComingBackClearsTheMark() {
        XCTAssertEqual(StrangerRearm.observe(wasContact: false, isContact: true, isMarked: true), .disarm)
    }

    func testAContactComingBackWithoutAMarkIsNotAnEvent() {
        XCTAssertEqual(StrangerRearm.observe(wasContact: false, isContact: true, isMarked: false), .none)
    }

    func testAContactStayingAContactWithAStaleMarkClearsIt() {
        // The person was re-added while this app was not looking; the mark has outlived its reason.
        XCTAssertEqual(StrangerRearm.observe(wasContact: true, isContact: true, isMarked: true), .disarm)
    }

    func testNoChangeIsNoEvent() {
        XCTAssertEqual(StrangerRearm.observe(wasContact: false, isContact: false, isMarked: false), .none)
        XCTAssertEqual(StrangerRearm.observe(wasContact: false, isContact: false, isMarked: true), .none)
        XCTAssertEqual(StrangerRearm.observe(wasContact: true, isContact: true, isMarked: false), .none)
    }

    func testSomebodyNeverSeenAsAContactCannotBeRemoved() {
        // The first observation of a peer only takes note: "false" here means "never recorded", and a removal
        // this client never witnessed must not arm the chat out of nowhere.
        XCTAssertEqual(StrangerRearm.observe(wasContact: false, isContact: false, isMarked: false), .none)
    }

    // MARK: row 2 — marked, the peer has not written after the boundary: nothing (等对方来信)

    func testMarkedChatWaitsForThePeer() {
        XCTAssertEqual(StrangerRearm.placement(boundary: 100, firstIncomingIdAfterBoundary: nil, hasWrittenAfterBoundary: false), .waiting)
    }

    // MARK: row 3 — marked, the peer wrote, this account did not: show, before that message

    func testMarkedChatShowsBeforeThePeersFirstMessageAfterTheBoundary() {
        XCTAssertEqual(StrangerRearm.placement(boundary: 100, firstIncomingIdAfterBoundary: 101, hasWrittenAfterBoundary: false),
                       .beforeMessage(id: 101))
    }

    // MARK: row 4 — marked, both wrote: clear the mark, show nothing

    func testMarkedChatClearsOnceThisAccountWroteAfterTheBoundary() {
        XCTAssertEqual(StrangerRearm.placement(boundary: 100, firstIncomingIdAfterBoundary: 101, hasWrittenAfterBoundary: true), .clearMark)
    }

    func testMarkedChatClearsOnceThisAccountWroteEvenBeforeThePeerDid() {
        // Writing first is still a judgement made; the peer's later message must not bring the block back.
        XCTAssertEqual(StrangerRearm.placement(boundary: 100, firstIncomingIdAfterBoundary: nil, hasWrittenAfterBoundary: true), .clearMark)
    }

    // MARK: row 6 — no mark: 3.23.3's ordinary rule

    func testUnmarkedChatFollowsTheOrdinaryRule() {
        XCTAssertEqual(StrangerRearm.placement(boundary: nil, firstIncomingIdAfterBoundary: 101, hasWrittenAfterBoundary: false), .ordinaryRule)
        XCTAssertEqual(StrangerRearm.placement(boundary: nil, firstIncomingIdAfterBoundary: nil, hasWrittenAfterBoundary: true), .ordinaryRule)
    }

    // MARK: 「本人边界后发过」 — the watermark or a known outgoing id, never a scan read as absence

    func testWrittenAfterBoundaryFromTheReadWatermark() {
        XCTAssertTrue(StrangerRearm.hasWrittenAfterBoundary(boundary: 100, maxOutgoingReadId: 105, maxKnownOutgoingId: nil))
    }

    func testWrittenAfterBoundaryFromAKnownOutgoingId() {
        // Just replied, peer has not read yet: the watermark still lags, the send itself is the evidence.
        XCTAssertTrue(StrangerRearm.hasWrittenAfterBoundary(boundary: 100, maxOutgoingReadId: 40, maxKnownOutgoingId: 102))
    }

    func testWritingBeforeTheBoundaryDoesNotCount() {
        // A three-year-old conversation has plenty of this account's messages below the boundary; that is the
        // whole reason the boundary exists.
        XCTAssertFalse(StrangerRearm.hasWrittenAfterBoundary(boundary: 100, maxOutgoingReadId: 100, maxKnownOutgoingId: 99))
    }

    func testNoEvidenceIsNotWritten() {
        XCTAssertFalse(StrangerRearm.hasWrittenAfterBoundary(boundary: 100, maxOutgoingReadId: nil, maxKnownOutgoingId: nil))
    }

    // MARK: reading the loaded window

    func testFirstIncomingAfterBoundaryIsTheSmallestSuchId() {
        let messages = [
            StrangerRearm.Message(id: 99, isIncoming: true),   // before the boundary: the historical first message
            StrangerRearm.Message(id: 101, isIncoming: false), // this account's own, not the peer's
            StrangerRearm.Message(id: 104, isIncoming: true),
            StrangerRearm.Message(id: 102, isIncoming: true),
        ]
        XCTAssertEqual(StrangerRearm.firstIncomingId(afterBoundary: 100, in: messages), 102)
        XCTAssertNil(StrangerRearm.firstIncomingId(afterBoundary: 104, in: messages))
        XCTAssertNil(StrangerRearm.firstIncomingId(afterBoundary: 0, in: []))
    }

    func testMaxOutgoingIdIsPositiveEvidenceOnly() {
        let messages = [
            StrangerRearm.Message(id: 101, isIncoming: false),
            StrangerRearm.Message(id: 107, isIncoming: false),
            StrangerRearm.Message(id: 110, isIncoming: true),
        ]
        XCTAssertEqual(StrangerRearm.maxOutgoingId(in: messages), 107)
        // Nothing of this account's loaded is nil — no evidence — never zero, which would read as "before any boundary".
        XCTAssertNil(StrangerRearm.maxOutgoingId(in: [StrangerRearm.Message(id: 110, isIncoming: true)]))
    }

    /// The whole row 3 → row 4 sequence as the clients run it: removed, the peer writes, the block shows before
    /// that message; this account replies, the mark clears.
    func testTheSequenceAsAClientRunsIt() {
        XCTAssertEqual(StrangerRearm.observe(wasContact: true, isContact: false, isMarked: false), .arm)
        let boundary: Int32 = 500
        var loaded = [StrangerRearm.Message(id: 480, isIncoming: false), StrangerRearm.Message(id: 500, isIncoming: true)]
        XCTAssertEqual(StrangerRearm.placement(
            boundary: boundary,
            firstIncomingIdAfterBoundary: StrangerRearm.firstIncomingId(afterBoundary: boundary, in: loaded),
            hasWrittenAfterBoundary: StrangerRearm.hasWrittenAfterBoundary(boundary: boundary, maxOutgoingReadId: 480, maxKnownOutgoingId: StrangerRearm.maxOutgoingId(in: loaded))
        ), .waiting)
        loaded.append(StrangerRearm.Message(id: 501, isIncoming: true))
        XCTAssertEqual(StrangerRearm.placement(
            boundary: boundary,
            firstIncomingIdAfterBoundary: StrangerRearm.firstIncomingId(afterBoundary: boundary, in: loaded),
            hasWrittenAfterBoundary: StrangerRearm.hasWrittenAfterBoundary(boundary: boundary, maxOutgoingReadId: 480, maxKnownOutgoingId: StrangerRearm.maxOutgoingId(in: loaded))
        ), .beforeMessage(id: 501))
        loaded.append(StrangerRearm.Message(id: 502, isIncoming: false))
        XCTAssertEqual(StrangerRearm.placement(
            boundary: boundary,
            firstIncomingIdAfterBoundary: StrangerRearm.firstIncomingId(afterBoundary: boundary, in: loaded),
            hasWrittenAfterBoundary: StrangerRearm.hasWrittenAfterBoundary(boundary: boundary, maxOutgoingReadId: 480, maxKnownOutgoingId: StrangerRearm.maxOutgoingId(in: loaded))
        ), .clearMark)
    }
}
