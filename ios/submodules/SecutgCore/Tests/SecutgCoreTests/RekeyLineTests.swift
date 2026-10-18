import XCTest
@testable import SecutgCore

/// `RekeyLine.key` (PLAN.md 3.32 review, batch 1) — the nine cases of Web's `rekeyLine.test.ts`, in its order.
final class RekeyLineTests: XCTestCase {
    func testARotateThatAppliedYouAreOnTheNewKey() {
        XCTAssertEqual(RekeyLine.key(ok: true, type: .rotate, reason: nil, hasKey: true), "SecutgRekeyAppliedRotate")
    }

    func testAResetThatAppliedYouWereOnTheList() {
        XCTAssertEqual(RekeyLine.key(ok: true, type: .reset, reason: nil, hasKey: true), "SecutgRekeyAppliedReset")
    }

    func testAWelcomeSeenByTheNewcomerItWasFor() {
        XCTAssertEqual(RekeyLine.key(ok: true, type: .welcome, reason: nil, hasKey: true), "SecutgRekeyWelcomeYou")
    }

    func testAWelcomeSeenByEveryoneWhoAlreadyHadTheKey() {
        XCTAssertEqual(RekeyLine.key(ok: true, type: .welcome, reason: "already_known", hasKey: true), "SecutgRekeyWelcomeOther")
    }

    func testTheRatchetLineIsUntouched() {
        XCTAssertEqual(RekeyLine.key(ok: true, type: .ratchet, reason: nil, hasKey: true), "SecutgRatchetApplied")
    }

    /// THE SPLIT: left out of a reset, holding the old key.
    func testTheSplitLeftOutOfAResetHoldingTheOldKey() {
        XCTAssertEqual(RekeyLine.key(ok: false, type: .reset, reason: "not_addressed", hasKey: true), "SecutgRekeyNotForYou")
    }

    /// THE SPLIT: the same refusal, but never given a key at all.
    func testTheSplitTheSameRefusalButNeverGivenAKeyAtAll() {
        XCTAssertEqual(RekeyLine.key(ok: false, type: .reset, reason: "not_addressed", hasKey: false), "SecutgRekeyNoKeyYet")
    }

    func testAWelcomeForSomebodyElseSeenBySomeoneWithNoKeyIsAlsoNotInYet() {
        XCTAssertEqual(RekeyLine.key(ok: false, type: .welcome, reason: "not_addressed", hasKey: false), "SecutgRekeyNoKeyYet")
    }

    /// PLAN.md 3.34.7 item 4: parked, not refused. The welcome overtook the notice that makes its signing key
    /// trusted and will be judged again the moment that lands, so the row says nothing at all — the same
    /// silence a parked notice gets. "ignored: pending" would be a reason that stops being true in a moment.
    func testAParkedWelcomeHasNoLineYetJustLikeAParkedNotice() {
        XCTAssertNil(RekeyLine.key(ok: false, type: .welcome, reason: "pending", hasKey: false))
        XCTAssertNil(RekeyLine.key(ok: false, type: .rotate, reason: "pending", hasKey: true))
    }

    func testWireLevelFaultsKeepTheTechnicalLineWhoeverSeesThem() {
        let faults = ["bad_signature", "malformed", "no_admin_key", "bad_label", "master_id_mismatch", "no_old_key"]
        for reason in faults {
            XCTAssertEqual(RekeyLine.key(ok: false, type: .rotate, reason: reason, hasKey: true), "SecutgRekeyRejected", reason)
            XCTAssertEqual(RekeyLine.key(ok: false, type: .rotate, reason: reason, hasKey: false), "SecutgRekeyRejected", reason)
        }
    }
}
