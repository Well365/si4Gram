import XCTest
@testable import SecutgCore

final class PairingDialogCatchUpTests: XCTestCase {
    func testDueWhenPairedAndNeverSeen() {
        XCTAssertTrue(PairingDialogCatchUp.isDue(pairingState: "paired", pairedAt: 1000, lastSeenPairedAt: nil, isVerified: false))
    }

    func testNotDueOnceThisEpisodeWasSeen() {
        XCTAssertFalse(PairingDialogCatchUp.isDue(pairingState: "paired", pairedAt: 1000, lastSeenPairedAt: 1000, isVerified: false))
    }

    func testDueAgainAfterARepairChangesPairedAt() {
        // A stale marker from a *previous* pairing episode must not suppress the new one.
        XCTAssertTrue(PairingDialogCatchUp.isDue(pairingState: "paired", pairedAt: 2000, lastSeenPairedAt: 1000, isVerified: false))
    }

    func testNotDueWithoutACompletedPairing() {
        XCTAssertFalse(PairingDialogCatchUp.isDue(pairingState: "invited", pairedAt: nil, lastSeenPairedAt: nil, isVerified: false))
        XCTAssertFalse(PairingDialogCatchUp.isDue(pairingState: nil, pairedAt: nil, lastSeenPairedAt: nil, isVerified: false))
    }

    func testNotDueForKeyChanged() {
        // key_changed has its own separate warning dialog (PLAN.md 3.7 rule 5); this catch-up must not
        // also fire the pairing-done safety-code dialog for it.
        XCTAssertFalse(PairingDialogCatchUp.isDue(pairingState: "key_changed", pairedAt: 1000, lastSeenPairedAt: nil, isVerified: false))
    }

    func testNotDueWithoutAPairedAtEvenIfStateSaysPaired() {
        // Defensive: a malformed/legacy status that claims "paired" but carries no timestamp has
        // nothing to key the seen-marker on, so it must not be treated as due.
        XCTAssertFalse(PairingDialogCatchUp.isDue(pairingState: "paired", pairedAt: nil, lastSeenPairedAt: nil, isVerified: false))
    }

    // MARK: PLAN.md 3.30 rule 7b — a chat whose safety code is already checked is not caught up on

    func testNotDueWhenAlreadyVerified() {
        // The case the rule is about: every chat paired before this mechanism existed has no seen-marker,
        // so without 7b all of them would fire at once on the next open.
        XCTAssertFalse(PairingDialogCatchUp.isDue(pairingState: "paired", pairedAt: 1000, lastSeenPairedAt: nil, isVerified: true))
    }

    func testNotDueWhenVerifiedEvenAfterARepair() {
        // Verified wins over "this episode was never shown": the user has already done what the dialog asks.
        XCTAssertFalse(PairingDialogCatchUp.isDue(pairingState: "paired", pairedAt: 2000, lastSeenPairedAt: 1000, isVerified: true))
    }

    func testStillDueWhenUnverified() {
        // The other half of 7b, and the reason the mechanism exists: an unchecked safety code still asks.
        XCTAssertTrue(PairingDialogCatchUp.isDue(pairingState: "paired", pairedAt: 1000, lastSeenPairedAt: nil, isVerified: false))
        XCTAssertTrue(PairingDialogCatchUp.isDue(pairingState: "paired", pairedAt: 2000, lastSeenPairedAt: 1000, isVerified: false))
    }

    func testVerifiedDoesNotResurrectAnUnpairedChat() {
        // `isVerified` only ever suppresses; it must not make a state that was never due become due.
        XCTAssertFalse(PairingDialogCatchUp.isDue(pairingState: nil, pairedAt: 1000, lastSeenPairedAt: nil, isVerified: true))
        XCTAssertFalse(PairingDialogCatchUp.isDue(pairingState: "key_changed", pairedAt: 1000, lastSeenPairedAt: nil, isVerified: true))
    }
}
