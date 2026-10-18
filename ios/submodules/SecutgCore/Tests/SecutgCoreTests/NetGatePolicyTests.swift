import XCTest
@testable import SecutgCore

/// PLAN.md 3.37: the online gate's decision, apart from any UI.
final class NetGatePolicyTests: XCTestCase {
    private func lifted(at t: Double = 0.0) -> NetGatePolicy {
        let p = NetGatePolicy().with(connection: .online, now: t)
        XCTAssertFalse(p.isCovered)
        return p
    }

    func testALoggedInAccountStartsCoveredAndConnecting() {
        let p = NetGatePolicy()
        XCTAssertTrue(p.isCovered)
        XCTAssertEqual(p.phase, .connecting)
        XCTAssertNil(p.recoverDeadline)
    }

    func testOnlineLifts() {
        XCTAssertFalse(NetGatePolicy().with(connection: .online, now: 1.0).isCovered)
    }

    func testOnlyOnlineLiftsNotConnectingNorUpdating() {
        for c in [NetGateConnection.waitingForNetwork, .connecting, .updating] {
            XCTAssertTrue(NetGatePolicy().with(connection: c, now: 100.0).advanced(to: 10_000.0).isCovered, "\(c) lifted the gate")
        }
    }

    func testUpdatingShowsSyncingAndNotConnectedShowsConnecting() {
        XCTAssertEqual(NetGatePolicy().with(connection: .updating, now: 0).phase, .syncing)
        XCTAssertEqual(NetGatePolicy().with(connection: .connecting, now: 0).phase, .connecting)
        XCTAssertEqual(NetGatePolicy().with(connection: .waitingForNetwork, now: 0).phase, .connecting)
        // connecting → updating → online: the text follows, and online lifts
        let p = NetGatePolicy().with(connection: .connecting, now: 0).with(connection: .updating, now: 1)
        XCTAssertTrue(p.isCovered)
        XCTAssertEqual(p.phase, .syncing)
        XCTAssertFalse(p.with(connection: .online, now: 2).isCovered)
    }

    func testADisconnectShorterThanFifteenSecondsDoesNotCover() {
        let p = lifted().with(connection: .connecting, now: 10.0)
        XCTAssertFalse(p.isCovered)
        XCTAssertEqual(p.recoverDeadline, 25.0)
        XCTAssertFalse(p.advanced(to: 24.9).isCovered)
        let back = p.advanced(to: 24.0).with(connection: .online, now: 24.5)
        XCTAssertFalse(back.isCovered)
        XCTAssertNil(back.recoverDeadline)
        // the run restarts after online: another 14 s outage later still does not cover
        let again = back.with(connection: .waitingForNetwork, now: 30.0).advanced(to: 44.0)
        XCTAssertFalse(again.isCovered)
    }

    func testUpdatingWhileLiftedCountsAsNotOnline() {
        let p = lifted().with(connection: .updating, now: 0.0)
        XCTAssertFalse(p.isCovered)
        XCTAssertTrue(p.advanced(to: 15.0).isCovered)
    }

    func testFifteenSecondsOrMoreCovers() {
        let p = lifted().with(connection: .connecting, now: 10.0)
        XCTAssertTrue(p.advanced(to: 25.0).isCovered)
        XCTAssertTrue(p.advanced(to: 500.0).isCovered)
        // a state change arriving late is judged against the start of the run, not its own arrival
        let changed = p.with(connection: .waitingForNetwork, now: 26.0)
        XCTAssertTrue(changed.isCovered)
        XCTAssertEqual(changed.phase, .connecting)
    }

    func testFurtherNonOnlineStatesDoNotRestartTheRun() {
        let p = lifted()
            .with(connection: .connecting, now: 0.0)
            .with(connection: .waitingForNetwork, now: 5.0)
            .with(connection: .updating, now: 10.0)
        XCTAssertEqual(p.recoverDeadline, 15.0)
        XCTAssertTrue(p.advanced(to: 15.0).isCovered)
    }

    func testAfterReCoveringOnlyOnlineLiftsAgain() {
        let covered = lifted().with(connection: .connecting, now: 0.0).advanced(to: 15.0)
        XCTAssertTrue(covered.isCovered)
        XCTAssertNil(covered.recoverDeadline)
        XCTAssertTrue(covered.with(connection: .updating, now: 16.0).isCovered)
        XCTAssertEqual(covered.with(connection: .updating, now: 16.0).phase, .syncing)
        XCTAssertTrue(covered.with(connection: .connecting, now: 100.0).isCovered)
        XCTAssertFalse(covered.with(connection: .online, now: 17.0).isCovered)
    }

    func testAClockThatWentBackwardsCovers() {
        let p = lifted().with(connection: .connecting, now: 100.0)
        XCTAssertTrue(p.advanced(to: 50.0).isCovered)
    }

    func testLoggedOutNeverCovers() {
        let out = NetGatePolicy(isAuthorized: false)
        XCTAssertFalse(out.isCovered)
        for c in [NetGateConnection.waitingForNetwork, .connecting, .updating, .online] {
            XCTAssertFalse(out.with(connection: c, now: 0).advanced(to: 1_000).isCovered)
        }
        XCTAssertNil(out.with(connection: .online, now: 0).with(connection: .connecting, now: 1).recoverDeadline)
        XCTAssertFalse(lifted().with(isAuthorized: false).isCovered)
    }

    func testLoggingBackInStartsCovered() {
        let p = lifted().with(isAuthorized: false).with(isAuthorized: true)
        XCTAssertTrue(p.isCovered)
        XCTAssertEqual(p, NetGatePolicy())
    }
}
