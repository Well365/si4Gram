import XCTest
@testable import SecutgCore

/// PLAN.md 3.38.2: a locked group refuses the user's words but still posts the app's own control messages.
final class GroupPasswordSendGateTests: XCTestCase {
    let group = "-1001234567890"

    func testAnUnlockedGroupRefusesNothing() {
        XCTAssertFalse(GroupPasswordSendGate.refuses(locked: false, text: "hello"))
        XCTAssertFalse(GroupPasswordSendGate.refuses(locked: false, text: ""))
    }

    func testALockedGroupRefusesUserContent() {
        XCTAssertTrue(GroupPasswordSendGate.refuses(locked: true, text: "user words"))
        XCTAssertTrue(GroupPasswordSendGate.refuses(locked: true, text: "GP1: looks like a control message but is not"))
        XCTAssertTrue(GroupPasswordSendGate.refuses(locked: true, text: ""), "media without a caption is still user content")
    }

    func testALockedGroupStillSendsControlMessages() throws {
        let gp1 = try XCTUnwrap(GP1.build(chatId: group, at: 1_789_300_020, payload: .off, publisherId: "7001"))
        XCTAssertTrue(Rekey.isControlMessage(gp1))
        XCTAssertFalse(GroupPasswordSendGate.refuses(locked: true, text: gp1))
    }
}
