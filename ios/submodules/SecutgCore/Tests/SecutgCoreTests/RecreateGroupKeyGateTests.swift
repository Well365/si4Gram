import XCTest
@testable import SecutgCore

/// Who gets offered "start this group's key over" (PLAN.md 3.32, amended by 3.33).
///
/// The one thing this file exists to pin is which admin the gate does NOT consult. secuTG's own `isAdmin`
/// means "this device holds the signing key" — true of the creating device and, since 3.33, of any device it
/// handed the key to. After the creating device wipes it is false for everyone left, which is precisely why
/// the group is stuck; gate on it and the way out is closed to exactly the people who need it. So the gate
/// reads the group's own admin list instead, and nothing about signing keys at all — the signature has no
/// parameter for it, which is the point: there is nothing here to consult.
final class RecreateGroupKeyGateTests: XCTestCase {
    func testTelegramAdminHoldingTheKeyIsOffered() {
        XCTAssertTrue(RecreateGroupKeyGate.canRecreateGroupKey(hasKey: true, isTelegramAdmin: true))
    }

    func testOrdinaryMemberIsNotHoweverStuckTheGroupIs() {
        // Group key present, no rights in the group.
        XCTAssertFalse(RecreateGroupKeyGate.canRecreateGroupKey(hasKey: true, isTelegramAdmin: false))
    }

    func testNoKeyHereYetIsTheOrdinaryCreateEntrysJob() {
        // Nothing to invalidate, so no confirmation and no separate entry.
        XCTAssertFalse(RecreateGroupKeyGate.canRecreateGroupKey(hasKey: false, isTelegramAdmin: true))
    }

    func testTheWipedCreatorItselfTakesThatOrdinaryRoad() {
        // SOS leaves the device that triggered it a blank slate: no key, so "create group key" is back.
        XCTAssertFalse(RecreateGroupKeyGate.canRecreateGroupKey(hasKey: false, isTelegramAdmin: true))
    }

    /// 3.33: the device that created the key is offered it too — the gate never asks who signs.
    ///
    /// Under 3.32 alone this was false: the creator had rotate and reset, finer instruments than this one.
    /// With the signing key possibly on several devices, the user decided recreating is open to every
    /// Telegram admin, holders included. Written with the same two arguments as every other case because
    /// there is no third: a signing-key holder and a plain holder are indistinguishable to this gate.
    func testTheDeviceThatCreatedTheKeyIsOfferedItToo() {
        XCTAssertTrue(RecreateGroupKeyGate.canRecreateGroupKey(hasKey: true, isTelegramAdmin: true))
    }

    /// THE DEAD END, and the reason the feature exists.
    ///
    /// Two Telegram admins, A and B. A created the key and then triggered SOS, so B is left holding a key
    /// it cannot change by any other route — rotate, reset and welcome all need a signing key B was never
    /// handed, and "create group key" hides itself because B does have a key. B is a plain holder with
    /// admin rights, and that is all the gate needs to hear.
    func testEverySurvivorOfAWipedCreatorIsAPlainHolder() {
        let bHasKey = true, bIsTelegramAdmin = true
        XCTAssertTrue(RecreateGroupKeyGate.canRecreateGroupKey(hasKey: bHasKey, isTelegramAdmin: bIsTelegramAdmin))
    }

    // PLAN.md 3.34 (2026-09-20 用户定): 「其他的非管理员不要有重建群钥匙的菜单」. The first key goes out
    // through the "设置群密钥" entry, which opens the very same rebuild dialog — so it reads the same gate.

    func testCreateOfferedToTelegramAdminWithNoKey() {
        XCTAssertTrue(RecreateGroupKeyGate.canCreateGroupKey(hasKey: false, isTelegramAdmin: true))
    }

    func testTheGapCreateNotOfferedToOrdinaryMember() {
        XCTAssertFalse(RecreateGroupKeyGate.canCreateGroupKey(hasKey: false, isTelegramAdmin: false))
    }

    func testCreateNotOfferedOnceAKeyIsHere() {
        XCTAssertFalse(RecreateGroupKeyGate.canCreateGroupKey(hasKey: true, isTelegramAdmin: true))
        XCTAssertFalse(RecreateGroupKeyGate.canCreateGroupKey(hasKey: true, isTelegramAdmin: false))
    }

    func testAdminAlwaysSeesExactlyOneOfTheTwo() {
        for hasKey in [true, false] {
            XCTAssertNotEqual(
                RecreateGroupKeyGate.canCreateGroupKey(hasKey: hasKey, isTelegramAdmin: true),
                RecreateGroupKeyGate.canRecreateGroupKey(hasKey: hasKey, isTelegramAdmin: true)
            )
        }
    }

    func testMemberSeesNeither() {
        for hasKey in [true, false] {
            XCTAssertFalse(RecreateGroupKeyGate.canCreateGroupKey(hasKey: hasKey, isTelegramAdmin: false))
            XCTAssertFalse(RecreateGroupKeyGate.canRecreateGroupKey(hasKey: hasKey, isTelegramAdmin: false))
        }
    }
}
