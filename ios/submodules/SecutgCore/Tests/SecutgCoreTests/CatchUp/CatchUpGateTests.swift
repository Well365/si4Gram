import Foundation
import XCTest
@testable import SecutgCore

/// PLAN.md 3.47 point 1: one pass at a time; a trigger during a pass buys exactly one more.
final class CatchUpGateTests: XCTestCase {
    func testSingleFlight() {
        let gate = CatchUpGate()
        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.isRunning)
        XCTAssertFalse(gate.request())
        XCTAssertFalse(gate.request())
        // the two triggers during the pass buy one rerun, not two
        XCTAssertTrue(gate.finish(moreWork: false))
        XCTAssertTrue(gate.isRunning)
        XCTAssertFalse(gate.finish(moreWork: false))
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.request())
    }

    func testNoTriggerNoRerun() {
        let gate = CatchUpGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.finish(moreWork: false))
        XCTAssertFalse(gate.isRunning)
    }

    func testBudgetLeftoversChainABoundedNumberOfPasses() {
        let gate = CatchUpGate(maxChainedPasses: 2)
        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.finish(moreWork: true))
        XCTAssertTrue(gate.finish(moreWork: true))
        XCTAssertFalse(gate.finish(moreWork: true)) // third leftover: wait for the next trigger
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.request()) // a real trigger starts afresh
        XCTAssertTrue(gate.finish(moreWork: true))
    }

    func testATriggerResetsTheChain() {
        let gate = CatchUpGate(maxChainedPasses: 1)
        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.finish(moreWork: true))
        XCTAssertFalse(gate.request())
        XCTAssertTrue(gate.finish(moreWork: true)) // the trigger's rerun
        XCTAssertTrue(gate.finish(moreWork: true)) // and a fresh chain of one
        XCTAssertFalse(gate.finish(moreWork: true))
    }

    func testFinishWithoutAPassIsHarmless() {
        let gate = CatchUpGate()
        XCTAssertFalse(gate.finish(moreWork: true))
        XCTAssertFalse(gate.isRunning)
    }

    func testDefaultChainBound() {
        XCTAssertEqual(CatchUp.maxChainedPasses, 8)
        let gate = CatchUpGate()
        XCTAssertTrue(gate.request())
        var chained = 0
        while gate.finish(moreWork: true) { chained += 1 }
        XCTAssertEqual(chained, 8)
    }
}
