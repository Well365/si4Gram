import XCTest
@testable import SecutgCore

/// PLAN.md 3.22.2 / 3.22.3: the fixed phrase, the additive custom phrase, and whole-message equality.
final class WipePhraseTests: XCTestCase {
    func testBuiltInPhraseIsByteForByteTheAgreedConstant() {
        // Must match Web A `phrase.ts` BUILT_IN_WIPE_PHRASE exactly, or a phrase posted from one
        // client would not fire the wipe on another.
        XCTAssertEqual(WipePhrase.builtInPhrase, "紫色大象飞了紫色大象飞了紫色大象飞了")
        XCTAssertEqual(WipePhrase.builtInPhrase.utf8.count, 54)
    }

    func testMatchesBuiltInExactlyAndTrimmed() {
        XCTAssertTrue(WipePhrase.matches(WipePhrase.builtInPhrase))
        XCTAssertTrue(WipePhrase.matches("  \n\(WipePhrase.builtInPhrase)\t "))
    }

    func testContainsIsNotAMatch() {
        // PLAN.md 3.22.3 rule 1: whole message, not "contains" — a note discussing the feature must
        // not blow itself up.
        XCTAssertFalse(WipePhrase.matches("看这个密语：\(WipePhrase.builtInPhrase)，很长"))
        XCTAssertFalse(WipePhrase.matches("\(WipePhrase.builtInPhrase)!"))
    }

    func testEmptyNeverMatches() {
        XCTAssertFalse(WipePhrase.matches(""))
        XCTAssertFalse(WipePhrase.matches("    "))
    }

    func testCustomPhraseIsAdditiveNotAReplacement() {
        let custom = "my secret twelve plus"
        // Both the built-in and the custom fire when a custom is set (PLAN.md 3.22.2).
        XCTAssertTrue(WipePhrase.matches(WipePhrase.builtInPhrase, customPhrase: custom))
        XCTAssertTrue(WipePhrase.matches(custom, customPhrase: custom))
        XCTAssertTrue(WipePhrase.matches("  \(custom)  ", customPhrase: custom))
        XCTAssertFalse(WipePhrase.matches("something else", customPhrase: custom))
    }

    func testCustomPhraseUnsetFallsBackToBuiltInOnly() {
        XCTAssertTrue(WipePhrase.matches(WipePhrase.builtInPhrase, customPhrase: nil))
        XCTAssertTrue(WipePhrase.matches(WipePhrase.builtInPhrase, customPhrase: ""))
        XCTAssertTrue(WipePhrase.matches(WipePhrase.builtInPhrase, customPhrase: "   "))
    }

    func testValidateRejectsTooShort() {
        XCTAssertEqual(WipePhrase.validateCustomPhrase("short"), .rejected(.tooShort))
        XCTAssertEqual(WipePhrase.validateCustomPhrase("eleven chars"), .accepted("eleven chars")) // 12 chars
        XCTAssertEqual(WipePhrase.validateCustomPhrase("           "), .rejected(.tooShort)) // trims to empty
    }

    func testValidateRejectsSameAsBuiltIn() {
        XCTAssertEqual(WipePhrase.validateCustomPhrase(WipePhrase.builtInPhrase), .rejected(.sameAsBuiltIn))
    }

    func testValidateAcceptsAndTrims() {
        XCTAssertEqual(WipePhrase.validateCustomPhrase("  a valid phrase  "), .accepted("a valid phrase"))
    }
}

/// PLAN.md 3.22.7: what a hand-pressed wipe puts in Saved Messages. Separated from the matching tests
/// because the rule it encodes is about the *sending* side, and getting it wrong is silent — the user
/// found the previous version of this rule by pressing the button and reading what arrived.
final class WipeBroadcastPhraseTests: XCTestCase {
    private let custom = "这是一句只有我自己知道的密语"

    func testWithNoCustomPhraseItIsTheBuiltInOne() {
        XCTAssertEqual(WipePhrase.broadcastPhrase(), WipePhrase.builtInPhrase)
        XCTAssertEqual(WipePhrase.broadcastPhrase(customPhrase: nil), WipePhrase.builtInPhrase)
    }

    /// The bug the user reported: a phrase was set, and the built-in one went out anyway.
    func testWithACustomPhraseItIsTheCustomOne() {
        XCTAssertEqual(WipePhrase.broadcastPhrase(customPhrase: custom), custom)
    }

    /// A blank stored phrase is not a phrase. Broadcasting one would put an empty message in Saved
    /// Messages, which matches on no device at all — a fan-out that silently reaches nobody.
    func testABlankPhraseFallsBackToTheBuiltInOne() {
        XCTAssertEqual(WipePhrase.broadcastPhrase(customPhrase: ""), WipePhrase.builtInPhrase)
        XCTAssertEqual(WipePhrase.broadcastPhrase(customPhrase: "   \n  "), WipePhrase.builtInPhrase)
    }

    func testTheCustomPhraseGoesOutTrimmed() {
        XCTAssertEqual(WipePhrase.broadcastPhrase(customPhrase: "  \(custom)  "), custom)
    }

    /// The fan-out reaches a device set to the SAME phrase, and the built-in broadcast reaches every
    /// device however it is configured.
    func testTheFanOutReachesDevicesSetToTheSamePhrase() {
        XCTAssertTrue(WipePhrase.matches(WipePhrase.broadcastPhrase(customPhrase: custom), customPhrase: custom))
        XCTAssertTrue(WipePhrase.matches(WipePhrase.broadcastPhrase(), customPhrase: nil))
        XCTAssertTrue(WipePhrase.matches(WipePhrase.broadcastPhrase(), customPhrase: "另一台设备的自定义密语"))
    }

    /// The cost of the 2026-09-19 reversal, pinned here so that nobody "fixes" it by quietly going back
    /// to always broadcasting the built-in phrase. A device the user did not configure identically does
    /// NOT wipe. The settings copy is what tells them to set the same phrase everywhere.
    func testADeviceOnADifferentPhraseIsNotReached() {
        let sent = WipePhrase.broadcastPhrase(customPhrase: custom)
        XCTAssertFalse(WipePhrase.matches(sent, customPhrase: nil))
        XCTAssertFalse(WipePhrase.matches(sent, customPhrase: "另一台设备的自定义密语"))
    }
}

/// PLAN.md 3.22.7: the plaintext exemption on the SENDING side, ported from Android
/// `WipePhraseTest.isWipePhraseToSelf`. This is the rule that lets a phrase leave an encrypted Saved
/// Messages in the clear, so every test here is also a test that the hole stays small: another chat,
/// another text, or an unknown own-id must all close it.
final class WipePhraseToSelfTests: XCTestCase {
    private let own = "424242"

    func testBuiltInPhraseToSavedMessagesIsExempt() {
        XCTAssertTrue(WipePhrase.isWipePhraseToSelf(chatId: own, ownUserId: own, text: WipePhrase.builtInPhrase))
    }

    /// The broadcast the wipe button sends is the same message by the same road — one rule covers both.
    func testBroadcastPhraseIsExempt() {
        XCTAssertTrue(WipePhrase.isWipePhraseToSelf(chatId: own, ownUserId: own, text: WipePhrase.broadcastPhrase()))
    }

    /// PLAN.md 3.22.2: typing your own phrase into Saved Messages by hand is a supported trigger, so it
    /// has to go out in the clear too — an `E1:` envelope of it matches on no other device.
    func testCustomPhraseToSavedMessagesIsExempt() {
        let custom = "这是我自己的密语短句"
        XCTAssertTrue(WipePhrase.isWipePhraseToSelf(chatId: own, ownUserId: own, text: custom, customPhrase: custom))
        XCTAssertTrue(WipePhrase.isWipePhraseToSelf(chatId: own, ownUserId: own, text: "  \(custom) ", customPhrase: custom))
    }

    /// A phrase this device does not know is not a phrase: it encrypts like any other sentence.
    func testUnknownCustomPhraseIsNotExempt() {
        XCTAssertFalse(WipePhrase.isWipePhraseToSelf(chatId: own, ownUserId: own, text: "这是我自己的密语短句"))
    }

    func testOrdinaryTextToSavedMessagesIsNotExempt() {
        XCTAssertFalse(WipePhrase.isWipePhraseToSelf(chatId: own, ownUserId: own, text: "买牛奶"))
        XCTAssertFalse(WipePhrase.isWipePhraseToSelf(chatId: own, ownUserId: own, text: ""))
    }

    /// PLAN.md 3.22.3 rule 1 again, on the send side: a message *about* the phrase stays encrypted.
    func testMentionOfThePhraseIsNotExempt() {
        XCTAssertFalse(WipePhrase.isWipePhraseToSelf(
            chatId: own, ownUserId: own, text: "密语是 \(WipePhrase.builtInPhrase)"))
    }

    /// The phrase means nothing anywhere but Saved Messages, so nowhere else gets the exemption —
    /// including a private chat with someone else and a group.
    func testPhraseToAnotherChatIsNotExempt() {
        XCTAssertFalse(WipePhrase.isWipePhraseToSelf(chatId: "999", ownUserId: own, text: WipePhrase.builtInPhrase))
        XCTAssertFalse(WipePhrase.isWipePhraseToSelf(chatId: "-999", ownUserId: own, text: WipePhrase.builtInPhrase))
        XCTAssertFalse(WipePhrase.isWipePhraseToSelf(
            chatId: "-1000000000999", ownUserId: own, text: WipePhrase.builtInPhrase))
    }

    /// An own-id we do not actually know must never be allowed to collide its way into an exemption
    /// (mirrors Android's `ownUserId == 0` guard).
    func testUnknownOwnUserIdIsNeverExempt() {
        XCTAssertFalse(WipePhrase.isWipePhraseToSelf(chatId: "", ownUserId: "", text: WipePhrase.builtInPhrase))
        XCTAssertFalse(WipePhrase.isWipePhraseToSelf(chatId: "0", ownUserId: "0", text: WipePhrase.builtInPhrase))
    }
}
