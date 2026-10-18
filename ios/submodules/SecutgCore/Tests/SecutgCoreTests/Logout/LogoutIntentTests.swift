import Foundation
import XCTest
@testable import SecutgCore

/// PLAN.md 3.46.2 §1: the pure classification (forced vs. user-initiated logout) and its thread-safe wrapper.
final class LogoutIntentTests: XCTestCase {
    func testConsumingAMarkedAccountReportsTrueAndRemovesIt() {
        let (wasRegistered, remaining) = LogoutIntent.consuming(["1", "2"], accountKey: "1")
        XCTAssertTrue(wasRegistered)
        XCTAssertEqual(remaining, ["2"])
    }

    func testConsumingAnUnmarkedAccountReportsFalseAndLeavesTheSetAlone() {
        let (wasRegistered, remaining) = LogoutIntent.consuming(["2"], accountKey: "1")
        XCTAssertFalse(wasRegistered)
        XCTAssertEqual(remaining, ["2"])
    }

    func testConsumingTwiceOnlyReportsTrueOnce() {
        let first = LogoutIntent.consuming(["1"], accountKey: "1")
        XCTAssertTrue(first.wasRegistered)
        let second = LogoutIntent.consuming(first.remaining, accountKey: "1")
        XCTAssertFalse(second.wasRegistered)
    }

    func testRegistryMarkAndConsume() {
        let registry = LogoutIntentRegistry()
        XCTAssertFalse(registry.consumeUserInitiated(accountKey: "42"))
        registry.markUserInitiated(accountKey: "42")
        XCTAssertTrue(registry.consumeUserInitiated(accountKey: "42"))
        // Consumed: a second, later forced logout of the same account is not mistaken for user-initiated.
        XCTAssertFalse(registry.consumeUserInitiated(accountKey: "42"))
    }

    func testRegistryKeepsAccountsSeparate() {
        let registry = LogoutIntentRegistry()
        registry.markUserInitiated(accountKey: "1")
        XCTAssertFalse(registry.consumeUserInitiated(accountKey: "2"))
        XCTAssertTrue(registry.consumeUserInitiated(accountKey: "1"))
    }

    func testRegistryIsThreadSafeUnderConcurrentMarkAndConsume() {
        let registry = LogoutIntentRegistry()
        let iterations = 500
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let key = "\(i % 10)"
            registry.markUserInitiated(accountKey: key)
            _ = registry.consumeUserInitiated(accountKey: key)
        }
        // No crash, no corruption: every key ends up consumable or already consumed, never "stuck".
        for i in 0..<10 {
            _ = registry.consumeUserInitiated(accountKey: "\(i)")
        }
    }
}
