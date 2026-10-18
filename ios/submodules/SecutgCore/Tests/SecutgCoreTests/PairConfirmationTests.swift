import XCTest
@testable import SecutgCore

final class PairConfirmationTests: XCTestCase {
    func testSentByTheSideThatCompletedThePairing() {
        // The one case that posts "🔒 加密已开启": a live `.done` raised on the device that turned the
        // peer's P1 into a finished pairing.
        XCTAssertTrue(PairConfirmation.shouldSend(isPairingDone: true, completedHere: true))
    }

    func testNotSentByTheOtherSide() {
        // The inviting side's own `startPairing` also raises a `.done` once the peer's key is known.
        // If it posted too, one pairing would produce two "🔒 加密已开启" messages in the same chat.
        XCTAssertFalse(PairConfirmation.shouldSend(isPairingDone: true, completedHere: false))
    }

    func testNotSentForAnIncomingInvite() {
        // An invite has encrypted nothing yet — there is no "encryption is on" to announce.
        XCTAssertFalse(PairConfirmation.shouldSend(isPairingDone: false, completedHere: true))
        XCTAssertFalse(PairConfirmation.shouldSend(isPairingDone: false, completedHere: false))
    }

    func testNotSentOnADialogCatchUpReplay() {
        // `PairingDialogCatchUp` replays the "配对完成" dialog for a pairing episode this device missed
        // seeing, and it replays it every time the chat is opened until it is acknowledged. A replay
        // carries `completedHere == false` precisely so it can never re-post the confirmation: the
        // message is a real sent message and a second copy cannot be taken back.
        let replay = PairConfirmation.shouldSend(isPairingDone: true, completedHere: false)
        XCTAssertFalse(replay)
    }
}
