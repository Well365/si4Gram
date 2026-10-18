import XCTest
@testable import SecutgCore

/// PLAN.md 3.48.0 rule 3 / 3.48.6: with the master switch off and no `L1:` message in play, behaviour must be
/// byte-for-byte what it was before 3.48 — no network call, no storage write. These tests pin the three
/// decision points the app layer's hooks lean on (`RelayRender.classify`, `RelayPolicy.isEnabled`,
/// `RelayDeletion.plan`) so a future change to any of them cannot silently reintroduce a side effect on
/// ordinary, non-relay traffic.
final class RelayIndependenceTests: XCTestCase {
    func testOrdinaryTextNeverClassifiesAsAnyRelayState() {
        let neverCalled = { (_: String) -> Bool in
            XCTFail("trust lookup must not run for non-L1 text")
            return false
        }
        for text in ["", "hello", "E1:abc:def:ghi", "L", "L1", "l1:lowercase-prefix-does-not-count"] {
            let state = RelayRender.classify(text: text, localCopy: nil, showCards: true, askUnknownRelay: true, allowInsecureOrLAN: false, isTrusted: neverCalled)
            XCTAssertNil(state, "unexpected relay classification for \(text)")
        }
    }

    func testDisabledGlobalSettingsLeavesFollowGlobalChatsOff() {
        XCTAssertFalse(RelayPolicy.isEnabled(global: .default, chat: .default))
    }

    func testManualOnlyDefaultNeverAutoRoutesAnything() {
        XCTAssertFalse(RelayPolicy.shouldAutoRelay(trigger: RelaySettings.default.trigger, textLength: Int.max, isImage: true))
    }

    func testNonRelayMessageDeletionPlanIsEntirelyInert() {
        XCTAssertEqual(RelayDeletion.plan(text: "just chatting", sentItem: nil), .none)
    }

    func testFreshAppConfigHasNoRelaysNoTrustNoRows() {
        let config = RelayAppConfig.empty
        XCTAssertTrue(config.relays.isEmpty)
        XCTAssertTrue(config.trustedHosts.isEmpty)
        XCTAssertFalse(config.settings.enabled)
    }

    func testFreshAccountStateMakesNoKeychainOrFileAccessUntilMutated() {
        // RelayMemoryAccountStore never touches disk; a state built on it with no mutation calls stays empty,
        // demonstrating the manager performs no writes on its own at init time.
        let backing = RelayMemoryAccountStore()
        _ = RelayAccountState(store: backing)
        XCTAssertNil(backing.saved, "constructing the state must not itself persist anything")
    }
}
