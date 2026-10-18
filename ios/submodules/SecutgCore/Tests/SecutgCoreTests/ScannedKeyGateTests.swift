import XCTest
@testable import SecutgCore

/// PLAN.md 3.34.4 — the scanned payload must carry the key the notice announced.
final class ScannedKeyGateTests: XCTestCase {
    let announced = [UInt8](repeating: 0x11, count: 32)
    let stranger = [UInt8](repeating: 0x22, count: 32)

    /// The state an accepted `N1` leaves behind: encryption on, a key trusted, no master bound
    func accepts(_ offered: [UInt8]?, announced: [UInt8]? = nil, isEncrypted: Bool = true,
                 hasMaster: Bool = false) -> Bool {
        return ScannedKeyGate.accepts(announcedAdminPk: announced ?? self.announced, isEncrypted: isEncrypted,
                                      hasMaster: hasMaster, payloadAdminPk: offered)
    }

    /// The whole of manual mode's claim: the member was told to go and scan something, so without this check
    /// whoever gets a code in front of them first is accepted.
    func testAWaitingGroupRefusesAnyCodeButTheOneTheNoticeAnnounced() {
        XCTAssertTrue(accepts(announced))
        XCTAssertFalse(accepts(stranger))
    }

    /// A first import has nothing to compare against — refusing there would make it impossible ever to join a
    /// group, since the trusted key arrives with the key itself.
    func testAChatThatTrustsNothingYetAcceptsAnything() {
        XCTAssertTrue(ScannedKeyGate.accepts(announcedAdminPk: nil, isEncrypted: false, hasMaster: false,
                                             payloadAdminPk: stranger))
    }

    /// A chat that still holds its master is not waiting for a replacement: importing a different key there is
    /// a member deliberately re-keying a working chat by hand, which is not this rule's business.
    func testAChatThatIsNotWaitingIsNotThisRulesBusiness() {
        XCTAssertTrue(accepts(stranger, hasMaster: true))
        XCTAssertTrue(accepts(stranger, isEncrypted: false))
    }

    /// Creating a key always writes an `admin_pk`, so a payload without one cannot be the key the notice
    /// announced — and accepting it would leave the member encrypting under a stranger's master while still
    /// trusting the real admin's signing key, which is the worst of both readings. Absent is refused with the
    /// mismatched, not waved through.
    func testAPayloadCarryingNoAdminKeyIsRefusedToo() {
        XCTAssertFalse(accepts(nil))
        // And only while the chat is actually waiting: elsewhere a payload with no admin key is somebody
        // else's rule, not this one's.
        XCTAssertTrue(accepts(nil, hasMaster: true))
        XCTAssertTrue(accepts(nil, isEncrypted: false))
        XCTAssertTrue(ScannedKeyGate.accepts(announcedAdminPk: nil, isEncrypted: true, hasMaster: false,
                                             payloadAdminPk: nil))
    }
}
