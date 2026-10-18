import XCTest
@testable import SecutgCore

/// PLAN.md 3.24.8: remembering "not now", per chat, per account — and what an unreadable memory is
/// allowed to do (nothing). Ported from the Web reference (`src/secutg/onboard/memory.test.ts`).
final class OnboardMemoryTests: XCTestCase {
    func testAChatNobodyWasAskedAboutReadsAsZero() {
        XCTAssertEqual(OnboardMemoryCodec.parse(nil), .count(0))
    }

    func testACountAndANeverBothSurviveARoundTrip() {
        XCTAssertEqual(OnboardMemoryCodec.parse(OnboardMemoryCodec.serialize(.count(0))), .count(0))
        XCTAssertEqual(OnboardMemoryCodec.parse(OnboardMemoryCodec.serialize(.count(1))), .count(1))
        XCTAssertEqual(OnboardMemoryCodec.parse(OnboardMemoryCodec.serialize(.never)), .never)
    }

    func testTheThreeSpellingsAreTheOnesEveryClientWrites() {
        // PLAN.md 3.24.8: "0" | "1" | "never", so a keyring transfer or a support log reads the same
        // on all five clients.
        XCTAssertEqual(OnboardMemoryCodec.serialize(.count(0)), "0")
        XCTAssertEqual(OnboardMemoryCodec.serialize(.count(1)), "1")
        XCTAssertEqual(OnboardMemoryCodec.serialize(.never), "never")
    }

    func testAValueWeCannotReadMeansUnaskedNeverSilenced() {
        // Hand-edited, half-written, or written by a build that stored something else: a memory we
        // do not understand must not be able to switch the card off for good.
        for raw in ["yes", "", "-4", "1.5", "NEVER", " never", "never ", "0x1", "9999999999999999999999"] {
            XCTAssertEqual(OnboardMemoryCodec.parse(raw), .count(0), "unreadable value \(raw) silenced the card")
        }
    }

    func testTheKeyIsPerChatSoOneChatCannotSilenceAnother() {
        XCTAssertNotEqual(OnboardMemoryCodec.storageKey(accountKey: "a", chatId: "42"),
                          OnboardMemoryCodec.storageKey(accountKey: "a", chatId: "99"))
    }

    func testTheKeyIsPerAccountSoOneAccountCannotSilenceAnother() {
        // One device, two logins: a "never" said as one account must not reach the other's chat of
        // the same id. The 3.23 decisions are scoped the same way.
        XCTAssertNotEqual(OnboardMemoryCodec.storageKey(accountKey: "a", chatId: "42"),
                          OnboardMemoryCodec.storageKey(accountKey: "b", chatId: "42"))
    }

    func testTheKeyShapeIsTheOnePlanNames() {
        XCTAssertEqual(OnboardMemoryCodec.storageKey(accountKey: "7", chatId: "42"), "secutg.onboard.7.42")
    }

    func testTheWipePrefixCoversEveryKeyOfThatAccountAndNoOther() {
        // PLAN.md 3.24.8 / 3.16: the emergency wipe drops these along with the 3.23 decisions. It
        // enumerates by prefix, so the prefix has to match this account's keys and nothing else —
        // including no other account whose key merely starts with the same characters.
        let prefix = OnboardMemoryCodec.accountPrefix(accountKey: "7")
        XCTAssertTrue(OnboardMemoryCodec.storageKey(accountKey: "7", chatId: "42").hasPrefix(prefix))
        XCTAssertTrue(OnboardMemoryCodec.storageKey(accountKey: "7", chatId: "-1001").hasPrefix(prefix))
        XCTAssertFalse(OnboardMemoryCodec.storageKey(accountKey: "77", chatId: "42").hasPrefix(prefix))
        XCTAssertFalse(OnboardMemoryCodec.storageKey(accountKey: "8", chatId: "42").hasPrefix(prefix))
    }
}
