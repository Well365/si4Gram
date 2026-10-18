import XCTest
@testable import SecutgCore

final class SecutgSettingsSubtitlesTests: XCTestCase {
    func testWipeSettingsAllOffIsEmpty() {
        XCTAssertEqual(SecutgSettingsSubtitles.wipeSettingsActiveLabelKeys(
            needsConfirmation: false, listensToPhrase: false, resetsAuthorizations: false, hasCustomPhrase: false), [])
    }

    func testWipeSettingsAllOnIsInFixedOrder() {
        XCTAssertEqual(SecutgSettingsSubtitles.wipeSettingsActiveLabelKeys(
            needsConfirmation: true, listensToPhrase: true, resetsAuthorizations: true, hasCustomPhrase: true),
            ["SecutgWipeSettingsShortConfirm", "SecutgWipeSettingsShortListen", "SecutgWipeSettingsShortResetAuth", "SecutgWipeSettingsShortPhrase"])
    }

    func testWipeSettingsPartialCombinations() {
        XCTAssertEqual(SecutgSettingsSubtitles.wipeSettingsActiveLabelKeys(
            needsConfirmation: true, listensToPhrase: false, resetsAuthorizations: false, hasCustomPhrase: true),
            ["SecutgWipeSettingsShortConfirm", "SecutgWipeSettingsShortPhrase"])
        XCTAssertEqual(SecutgSettingsSubtitles.wipeSettingsActiveLabelKeys(
            needsConfirmation: false, listensToPhrase: true, resetsAuthorizations: true, hasCustomPhrase: false),
            ["SecutgWipeSettingsShortListen", "SecutgWipeSettingsShortResetAuth"])
    }

    func testApiIdentitySubtitleKeyForEachSource() {
        XCTAssertEqual(SecutgSettingsSubtitles.apiIdentitySubtitleKey(source: .user), "SecutgSettingsApiUsingOwn")
        XCTAssertEqual(SecutgSettingsSubtitles.apiIdentitySubtitleKey(source: .bundled), "SecutgSettingsApiUsingShared")
        XCTAssertEqual(SecutgSettingsSubtitles.apiIdentitySubtitleKey(source: .env), "SecutgSettingsApiUsingEnv")
        XCTAssertNil(SecutgSettingsSubtitles.apiIdentitySubtitleKey(source: .none))
    }
}
