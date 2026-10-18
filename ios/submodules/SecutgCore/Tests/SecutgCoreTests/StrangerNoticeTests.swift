import XCTest
@testable import SecutgCore

/// PLAN.md 3.23: the ask → checking → result state machine, and every reason to stay hidden.
final class StrangerNoticeTests: XCTestCase {
    func base(
        isPrivateChat: Bool = true,
        isContact: Bool = false,
        isBot: Bool = false,
        hasRepliedTo: Bool = false,
        decision: StrangerNotice.Decision = .unasked,
        commonChats: Int? = nil
    ) -> StrangerNotice.Input {
        return StrangerNotice.Input(isPrivateChat: isPrivateChat, isContact: isContact, isBot: isBot, hasRepliedTo: hasRepliedTo, decision: decision, commonChats: commonChats)
    }

    func testAskWhenStrangerAndUnasked() {
        XCTAssertEqual(StrangerNotice.evaluate(base()), .ask)
    }

    func testHiddenForNonPrivateChat() {
        XCTAssertEqual(StrangerNotice.evaluate(base(isPrivateChat: false)), .hidden)
    }

    func testHiddenForBot() {
        XCTAssertEqual(StrangerNotice.evaluate(base(isBot: true)), .hidden)
    }

    func testAskWhenContactAndUnasked() {
        // PLAN.md 3.23.3: being in the contacts list is NOT a reason to stay quiet. The section
        // exists to catch impersonation, so "are they in your contacts" is half of what gets
        // reported — gating on it would hide the notice from the very case it is for.
        XCTAssertEqual(StrangerNotice.evaluate(base(isContact: true)), .ask)
    }

    func testHiddenOnceReplied() {
        // Replying is the judgement the notice exists to inform (PLAN.md 3.23.3: reply → whole block vanishes).
        XCTAssertEqual(StrangerNotice.evaluate(base(hasRepliedTo: true)), .hidden)
    }

    func testHiddenOnceRepliedEvenForContact() {
        // The one surviving gate (PLAN.md 3.23.5), and the reason dropping the contacts check does not
        // turn this into wallpaper: an everyday chat with somebody you know has your replies in it.
        XCTAssertEqual(StrangerNotice.evaluate(base(isContact: true, hasRepliedTo: true)), .hidden)
    }

    func testHiddenWhenDeclined() {
        XCTAssertEqual(StrangerNotice.evaluate(base(decision: .declined)), .hidden)
    }

    func testHiddenWhenDeclinedForContact() {
        XCTAssertEqual(StrangerNotice.evaluate(base(isContact: true, decision: .declined)), .hidden)
    }

    func testCheckingWhenCheckedButCountNotYetLoaded() {
        // PLAN.md 3.23.4: never show a zero that only means "not loaded" — show "checking" instead.
        XCTAssertEqual(StrangerNotice.evaluate(base(decision: .checked, commonChats: nil)), .checking)
    }

    func testCheckingForContactToo() {
        XCTAssertEqual(StrangerNotice.evaluate(base(isContact: true, decision: .checked, commonChats: nil)), .checking)
    }

    // The four sentences of the PLAN.md 3.23.4 table, one test each: not a contact / a contact,
    // crossed with no common groups / some. The wording lives in the clients, but which of the four
    // they are told to say is decided here.

    func testResultNonContactNoGroups() {
        XCTAssertEqual(StrangerNotice.evaluate(base(isContact: false, decision: .checked, commonChats: 0)),
                       .result(textKey: "SecutgStrangerUnknownNoGroups", commonChats: 0))
    }

    func testResultNonContactWithGroups() {
        XCTAssertEqual(StrangerNotice.evaluate(base(isContact: false, decision: .checked, commonChats: 3)),
                       .result(textKey: "SecutgStrangerUnknownSomeGroups", commonChats: 3))
    }

    func testResultContactNoGroups() {
        XCTAssertEqual(StrangerNotice.evaluate(base(isContact: true, decision: .checked, commonChats: 0)),
                       .result(textKey: "SecutgStrangerKnownNoGroups", commonChats: 0))
    }

    func testResultContactWithGroups() {
        XCTAssertEqual(StrangerNotice.evaluate(base(isContact: true, decision: .checked, commonChats: 2)),
                       .result(textKey: "SecutgStrangerKnownSomeGroups", commonChats: 2))
    }

    /// A negative count cannot come from Telegram, but "some groups" must never be chosen for one:
    /// the `…SomeGroups` sentences read "you share N groups", and N below zero is not a sentence.
    func testResultTreatsNegativeCountAsNoGroups() {
        XCTAssertEqual(StrangerNotice.ResultWording.key(isContact: false, commonChats: -1), "SecutgStrangerUnknownNoGroups")
        XCTAssertEqual(StrangerNotice.ResultWording.key(isContact: true, commonChats: -1), "SecutgStrangerKnownNoGroups")
    }

    // MARK: the gate itself (PLAN.md 3.23.3) — see `hasEverWritten` on why one signal is not enough

    func testHasEverWrittenFromLoadedMessages() {
        XCTAssertTrue(StrangerNotice.hasEverWritten(hasLoadedOutgoingMessage: true, maxOutgoingReadId: nil))
    }

    func testHasEverWrittenJustRepliedAndPeerHasNotReadYet() {
        // The watermark means "how far the peer has read", so it is still zero in the minutes after you
        // answer. The scan carries this case, and always can: the message you just sent is the newest
        // thing in the chat, so it is necessarily in the loaded window.
        XCTAssertTrue(StrangerNotice.hasEverWritten(hasLoadedOutgoingMessage: true, maxOutgoingReadId: 0))
    }

    func testHasEverWrittenFromReadStateWhenNothingOfMineIsLoaded() {
        // The case the loaded-window scan gets wrong: paged up into old history, or cold-started onto a
        // screenful of the other side talking. The read state does not depend on what is loaded.
        XCTAssertTrue(StrangerNotice.hasEverWritten(hasLoadedOutgoingMessage: false, maxOutgoingReadId: 42))
    }

    func testHasEverWrittenFalseWhenNeitherSignalSaysSo() {
        XCTAssertFalse(StrangerNotice.hasEverWritten(hasLoadedOutgoingMessage: false, maxOutgoingReadId: 0))
    }

    func testMissingWatermarkIsNoEvidenceNotEvidenceOfHavingReplied() {
        // A watermark that could not be read must leave the other half to decide. Treating "unknown" as
        // "has replied" would hide the block from genuine strangers — the one failure direction this
        // section cannot afford.
        XCTAssertFalse(StrangerNotice.hasEverWritten(hasLoadedOutgoingMessage: false, maxOutgoingReadId: nil))
        XCTAssertTrue(StrangerNotice.hasEverWritten(hasLoadedOutgoingMessage: true, maxOutgoingReadId: nil))
    }

    func testRepliedBeatsCheckedResult() {
        // Even after checking, replying hides everything.
        XCTAssertEqual(StrangerNotice.evaluate(base(hasRepliedTo: true, decision: .checked, commonChats: 5)), .hidden)
    }

    func testRepliedBeatsCheckedResultForContact() {
        XCTAssertEqual(StrangerNotice.evaluate(base(isContact: true, hasRepliedTo: true, decision: .checked, commonChats: 5)), .hidden)
    }
}
