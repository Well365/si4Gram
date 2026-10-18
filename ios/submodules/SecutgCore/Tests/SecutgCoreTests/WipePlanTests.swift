import XCTest
@testable import SecutgCore

/// PLAN.md 3.22.2 / 3.22.4 / 3.22.7. Each of these pins a mistake that has actually been made, not a
/// hypothetical: the wrong gate on the broadcast, the wrong phrase in the broadcast, and a remotely
/// wiped device echoing the trigger back at the account.
final class WipePlanTests: XCTestCase {
    func testLocalWipeBroadcastsRegardlessOfWhetherThisDeviceListens() {
        // The bug this exists for: gating the broadcast on `wipeListensToPhrase`. It reads plausible
        // and it silently turns the fan-out off for every user who ticked that box.
        for listens in [true, false] {
            let plan = WipePlan.make(isRemote: false, listensToPhrase: listens, resetsAuthorizations: true)
            XCTAssertTrue(plan.broadcastsPhrase, "a hand-fired wipe must tell the other devices (listens=\(listens))")
        }
    }

    func testRemoteWipeNeitherBroadcastsNorEndsSessions() {
        for resets in [true, false] {
            let plan = WipePlan.make(isRemote: true, listensToPhrase: true, resetsAuthorizations: resets)
            XCTAssertFalse(plan.broadcastsPhrase, "a triggered device re-broadcasting would echo round the account")
            XCTAssertFalse(plan.resetsAuthorizations, "ending sessions belongs to the device that fired the wipe")
        }
    }

    func testResetAuthorizationsFollowsThePreferenceOnALocalWipe() {
        XCTAssertTrue(WipePlan.make(isRemote: false, listensToPhrase: true, resetsAuthorizations: true).resetsAuthorizations)
        XCTAssertFalse(WipePlan.make(isRemote: false, listensToPhrase: true, resetsAuthorizations: false).resetsAuthorizations)
    }

    func testBroadcastIsThisDevicesOwnPhrase() {
        XCTAssertEqual(WipePhrase.broadcastPhrase(), WipePhrase.builtInPhrase)

        // A phrase the user actually set is what goes out (3.22.7, reversed 2026-09-19). It is still
        // recognised locally too — listening stays additive, only the sending side changed.
        let custom = "这是一句只有我自己知道的密语"
        guard case .accepted(let stored) = WipePhrase.validateCustomPhrase(custom) else {
            return XCTFail("the custom phrase fixture must be valid")
        }
        XCTAssertTrue(WipePhrase.matches(stored, customPhrase: stored))
        XCTAssertEqual(WipePhrase.broadcastPhrase(customPhrase: stored), stored)
    }

    /// The broadcast has to be readable by a device that has never had this keyring, which is why it
    /// goes out in clear (3.22.7) — an envelope would be unreadable to exactly the devices it targets.
    func testBroadcastPhraseIsNotAnEnvelope() {
        XCTAssertFalse(E1Format.isEncrypted(WipePhrase.broadcastPhrase()))
    }
}
