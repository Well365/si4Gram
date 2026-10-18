import XCTest
@testable import SecutgCore

/// PLAN.md 3.51 补充 (2026-10-05 用户：「三端一起做」): loading-time app-name rewrite.
final class AppNameRewriteTests: XCTestCase {
    func testListedKeyIsReplaced() {
        let dict = ["Settings.FAQ": "Telegram FAQ"]
        let result = AppNameRewrite.apply(dict)
        XCTAssertEqual(result["Settings.FAQ"], "Si4Gram FAQ")
    }

    func testUnlistedKeyIsUntouched() {
        let dict = ["Settings.Premium": "Telegram Premium"]
        let result = AppNameRewrite.apply(dict)
        XCTAssertEqual(result["Settings.Premium"], "Telegram Premium")
    }

    func testOtherUnrelatedKeysArePassedThroughUnchanged() {
        let dict = ["Some.OtherKey": "Nothing to see here"]
        let result = AppNameRewrite.apply(dict)
        XCTAssertEqual(result, dict)
    }

    func testLocalizedSpellingIsReplaced() {
        // Arabic spelling listed in AppNameKeys.localizedNames (PLAN.md 3.51 补充).
        let dict = ["Settings.FAQ": "تيليجرام FAQ"]
        let result = AppNameRewrite.apply(dict)
        XCTAssertEqual(result["Settings.FAQ"], "Si4Gram FAQ")
    }

    func testWholeWordOnly_glueDoesNotMatch() {
        // "TelegramDesktop" is not a whole-word occurrence of "Telegram" and must be left alone,
        // even though the key is listed.
        let dict = ["Settings.FAQ": "Open TelegramDesktop to continue"]
        let result = AppNameRewrite.apply(dict)
        XCTAssertEqual(result["Settings.FAQ"], "Open TelegramDesktop to continue")
    }

    func testPlaceholdersAndMarkdownArePreserved() {
        let dict = ["Login.PhoneGenericEmailSubject": "**Telegram** %@ iOS error: %1$@"]
        let result = AppNameRewrite.apply(dict)
        XCTAssertEqual(result["Login.PhoneGenericEmailSubject"], "**Si4Gram** %@ iOS error: %1$@")
    }

    func testPluralVariantsOfAListedKeyAreCovered() {
        // AccessDenied.Contacts is listed; its plural siblings must be rewritten too even though
        // none of the suffixed forms are spelled out in AppNameKeys.keys.
        let dict = [
            "AccessDenied.Contacts_zero": "Telegram contacts: zero",
            "AccessDenied.Contacts_1": "Telegram contacts: one",
            "AccessDenied.Contacts_2": "Telegram contacts: two",
            "AccessDenied.Contacts_3_10": "Telegram contacts: few",
            "AccessDenied.Contacts_many": "Telegram contacts: many",
            "AccessDenied.Contacts_any": "Telegram contacts: any",
            "AccessDenied.Contacts_0": "Telegram contacts: explicit zero",
        ]
        let result = AppNameRewrite.apply(dict)
        for (key, _) in dict {
            XCTAssertEqual(result[key]?.hasPrefix("Si4Gram contacts:"), true, "\(key) was not rewritten")
        }
    }

    func testMixedKeyIsNotListedAndIsLeftUntouched() {
        // Premium.AboutText mixes both senses in one string (see AppNameKeys.swift comment) and is
        // intentionally not in the auto-replace list.
        XCTAssertFalse(AppNameKeys.keys.contains("Premium.AboutText"))
    }

    func testEmptyDictionaryIsReturnedAsIs() {
        XCTAssertEqual(AppNameRewrite.apply([:]), [:])
    }

    // MARK: - Caller-supplied key set (PLAN.md 3.51 补充 2026-10-05 用户：「三端一起做」)

    func testCallerSuppliedKeysOverloadRewritesOnlyItsOwnList() {
        let dict = ["Mac.Only.Key": "Telegram needs access", "Settings.FAQ": "Telegram FAQ"]
        let result = AppNameRewrite.apply(dict, keys: ["Mac.Only.Key"])
        XCTAssertEqual(result["Mac.Only.Key"], "Si4Gram needs access")
        // Not in the caller-supplied set, and not in AppNameKeys.keys either when using this overload.
        XCTAssertEqual(result["Settings.FAQ"], "Telegram FAQ")
    }

    func testCallerSuppliedPluralSuffixesAreHonored() {
        // macOS's own plural suffixes differ from iOS's; a base key "Mac.Base" with mac-style
        // suffixes must be covered without needing the iOS suffix list.
        let dict = ["Mac.Base_other": "Telegram cache"]
        let result = AppNameRewrite.apply(dict, keys: ["Mac.Base"], pluralSuffixes: ["_zero", "_one", "_two", "_few", "_many", "_other"])
        XCTAssertEqual(result["Mac.Base_other"], "Si4Gram cache")
    }

    func testIsListedKeyHelperMatchesBaseAndPluralSiblings() {
        XCTAssertTrue(AppNameRewrite.isListedKey("Mac.Base", in: ["Mac.Base"]))
        XCTAssertTrue(AppNameRewrite.isListedKey("Mac.Base_other", in: ["Mac.Base"], pluralSuffixes: ["_other"]))
        XCTAssertFalse(AppNameRewrite.isListedKey("Mac.Other", in: ["Mac.Base"]))
    }

    /// 2026-10-07 fix: Chinese writes Latin names with no space; Korean attaches particles.
    func testScriptAwareBoundaries() {
        let key = "Update.UpdateApp"
        XCTAssertEqual(AppNameRewrite.apply([key: "关于Telegram"])[key], "关于Si4Gram")
        XCTAssertEqual(AppNameRewrite.apply([key: "退出Telegram吗"])[key], "退出Si4Gram吗")
        XCTAssertEqual(AppNameRewrite.apply([key: "텔레그램을 업데이트"])[key], "Si4Gram을 업데이트")
        XCTAssertEqual(AppNameRewrite.apply([key: "TelegramDesktop"])[key], "TelegramDesktop")
        XCTAssertEqual(AppNameRewrite.apply([key: "Telegram_X"])[key], "Telegram_X")
    }
}
