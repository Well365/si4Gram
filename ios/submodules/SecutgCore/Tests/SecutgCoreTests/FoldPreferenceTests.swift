import XCTest
@testable import SecutgCore

/// PLAN.md 3.17 rule 5: the folding switch, and the one direction it is allowed to fail in. Ported from the Web
/// reference (`src/secutg/ui/foldPreference.test.ts`).
final class FoldPreferenceTests: XCTestCase {
    func testADeviceNobodyHasSetReadsAsShowEverything() {
        XCTAssertFalse(FoldPreferenceCodec.parse(nil))
    }

    func testBothSettingsSurviveARoundTrip() {
        XCTAssertTrue(FoldPreferenceCodec.parse(FoldPreferenceCodec.serialize(true)))
        XCTAssertFalse(FoldPreferenceCodec.parse(FoldPreferenceCodec.serialize(false)))
        // off is the absence of the record, so a device that never folded carries nothing
        XCTAssertNil(FoldPreferenceCodec.serialize(false))
        XCTAssertEqual(FoldPreferenceCodec.serialize(true), "1")
    }

    func testAnythingWeDidNotWriteReadsAsShowEverything() {
        // hand-edited, half-written, or written by a future build: a record we cannot understand must never be
        // the reason a message is missing from the timeline
        for raw in ["yes", "", "0", "true", "on", " 1", "1 ", "01", "2", "-1"] {
            XCTAssertFalse(FoldPreferenceCodec.parse(raw), "unreadable value \(raw) hid messages")
        }
    }

    func testTheKeyIsPerAccountSoOneLoginCannotFoldAnothersTimeline() {
        XCTAssertNotEqual(FoldPreferenceCodec.storageKey(accountKey: "1"),
                          FoldPreferenceCodec.storageKey(accountKey: "2"))
    }

    func testOneAccountsKeyIsAPrefixOfAnothersSoItMustBeRemovedExactly() {
        // decimal peer ids: account 1's key really is a prefix of account 12's. The wipe therefore removes this
        // one by exact key — a prefix sweep here would take another account's preference with it.
        XCTAssertTrue(FoldPreferenceCodec.storageKey(accountKey: "12")
            .hasPrefix(FoldPreferenceCodec.storageKey(accountKey: "1")))
    }

    func testTheKeyIsNotTheOnboardKeyNorAnyOtherSecutgRecord() {
        XCTAssertEqual(FoldPreferenceCodec.canonicalKey, "secutg:filter:undecryptable")
        XCTAssertEqual(FoldPreferenceCodec.storageKey(accountKey: "7"), "secutg.filter.undecryptable.7")
        XCTAssertFalse(FoldPreferenceCodec.storageKey(accountKey: "7")
            .hasPrefix(OnboardMemoryCodec.accountPrefix(accountKey: "7")))
    }
}
