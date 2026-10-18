import XCTest
@testable import SecutgCore

final class RelayDeletionTests: XCTestCase {
    func testNonRelayTextPlansNothing() {
        XCTAssertEqual(RelayDeletion.plan(text: "ordinary message", sentItem: nil), .none)
    }

    func testReceivedRelayMessageRemovesLocalCopyOnly() {
        let wire = "L1:anything"
        let plan = RelayDeletion.plan(text: wire, sentItem: nil)
        XCTAssertTrue(plan.removeLocalCopy)
        XCTAssertNil(plan.revoke)
    }

    func testOwnSentRelayMessageRevokesWithToken() {
        let item = RelaySentItem(id: "i1", chatId: "c1", messageId: 1, relayURL: "https://r", deleteToken: "dtok", contentType: .text, keepPolicy: .default, createdAtMs: 0)
        let plan = RelayDeletion.plan(text: "L1:anything", sentItem: item)
        XCTAssertTrue(plan.removeLocalCopy)
        XCTAssertEqual(plan.revoke?.itemId, "i1")
        XCTAssertEqual(plan.revoke?.deleteToken, "dtok")
        XCTAssertEqual(plan.revoke?.relayURL, "https://r")
    }

    func testAlreadyRevokedDoesNotRevokeAgain() {
        let item = RelaySentItem(id: "i1", chatId: "c1", messageId: 1, relayURL: "https://r", deleteToken: "dtok", contentType: .text, keepPolicy: .default, createdAtMs: 0, revoked: true)
        let plan = RelayDeletion.plan(text: "L1:anything", sentItem: item)
        XCTAssertTrue(plan.removeLocalCopy)
        XCTAssertNil(plan.revoke)
    }

    func testNoDeleteTokenDoesNotRevoke() {
        let item = RelaySentItem(id: "i1", chatId: "c1", messageId: 1, relayURL: "https://r", deleteToken: nil, contentType: .text, keepPolicy: .default, createdAtMs: 0)
        let plan = RelayDeletion.plan(text: "L1:anything", sentItem: item)
        XCTAssertTrue(plan.removeLocalCopy)
        XCTAssertNil(plan.revoke)
    }
}
