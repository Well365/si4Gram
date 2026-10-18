import XCTest
@testable import SecutgCore

/// The comparison contract of an `expect` item (xcheck/README.md, "How an expectation compares").
///
/// Pinned here rather than left to the vectors, because today's `inputs.json` cannot exercise it: every
/// array it marks `"unordered": true` holds nought or one element, so the flag is invisible in a matrix
/// run and a client could drop it again without a single cell turning red. The failure direction is the
/// reason the default is the strict one — a checker that ignores the flag goes red on an ordering
/// difference, never green on one — and both halves of that are asserted below.
final class XCheckExpectTests: XCTestCase {
    private func problems(_ body: (XCheckCase) -> Void) -> Int {
        let results = XCheckResults()
        let check = results.begin(producer: "self", suite: "expect", caseId: "expect.contract")
        body(check)
        check.end()
        return results.failed
    }

    /// Order is information until a field says it is not: `trail` is a sequence, and the same three entries
    /// in a different order are a different line to the user.
    func testArraysCompareInOrderByDefault() {
        XCTAssertEqual(problems { $0.eq("trail", ["invited", "duplicate", "pairing_lost"],
                                        ["invited", "pairing_lost", "duplicate"]) }, 1)
        XCTAssertEqual(problems { $0.eq("trail", ["invited", "duplicate", "pairing_lost"],
                                        ["invited", "duplicate", "pairing_lost"]) }, 0)
    }

    /// `"unordered": true` relaxes that one expectation to a set, for the fields whose order is a client's
    /// own map iteration order and nothing else.
    func testUnorderedRelaxesThatOneExpectation() {
        XCTAssertEqual(problems { $0.eq("peerSeenDeviceIds", ["20224d008069ce99", "bd0f01809bc8b171"],
                                        ["bd0f01809bc8b171", "20224d008069ce99"], unordered: true) }, 0)
        XCTAssertEqual(problems { $0.eq("boundChats", ["-1001234567890", "3003"],
                                        ["3003", "-1001234567890"], unordered: true) }, 0)
    }

    /// Relaxed is not blind: a missing member, a duplicate standing in for one, and a nested difference all
    /// still fail, and the flag on a value that is not an array changes nothing.
    func testUnorderedStillComparesContent() {
        XCTAssertEqual(problems { $0.eq("peerSeenDeviceIds", ["20224d008069ce99", "bd0f01809bc8b171"],
                                        ["20224d008069ce99"], unordered: true) }, 1)
        XCTAssertEqual(problems { $0.eq("peerSeenDeviceIds", ["20224d008069ce99", "bd0f01809bc8b171"],
                                        ["20224d008069ce99", "20224d008069ce99"], unordered: true) }, 1)
        XCTAssertEqual(problems { $0.eq("trail", [["invited"], ["duplicate"]],
                                        [["duplicate"], ["duplicate"]], unordered: true) }, 1)
        XCTAssertEqual(problems { $0.eq("state", "other_device", "invited", unordered: true) }, 1)
        XCTAssertEqual(problems { $0.eq("startedAt", 1789128000, 1789128000, unordered: true) }, 0)
    }

    /// The flag is read off the expectation item, where `inputs.json` writes it; absent is ordered.
    func testTheFlagIsReadFromTheExpectationItem() {
        let marked: [String: Any] = ["path": "/A/peerSeenDeviceIds", "equals": [], "unordered": true]
        let plain: [String: Any] = ["path": "/A/trail", "equals": []]
        XCTAssertTrue(marked.flag("unordered"))
        XCTAssertFalse(plain.flag("unordered"))
        XCTAssertFalse(marked.flag("path"))
    }
}
