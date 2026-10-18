import XCTest
@testable import SecutgCore

/// PLAN.md 3.34.6 — the pure decisions behind auto mode, ported from Web A's `autoPairing` block.
final class AutoWelcomeRecipientsTests: XCTestCase {
    func input(mode: Rekey.KeyMode = .auto, isGroup: Bool = true, holdsAdminKey: Bool = true, hasKey: Bool = true,
               ownUserId: String? = "1", memberIds: [String] = [], registeredIds: [String] = []) -> AutoPairing.WelcomeInput {
        return AutoPairing.WelcomeInput(mode: mode, isGroup: isGroup, holdsAdminKey: holdsAdminKey, hasKey: hasKey,
                                        ownUserId: ownUserId, memberIds: memberIds, registeredIds: registeredIds)
    }

    /// The intersection IS the security model of auto mode: the two lists are ANDed, never ORed
    func testOnlyPeopleWhoAreBothStillInTheGroupAndRegistered() {
        XCTAssertEqual(AutoPairing.welcomeRecipients(input(memberIds: ["2", "3", "4"], registeredIds: ["3", "4", "5"])),
                       ["3", "4"])
    }

    /// Somebody who left is not in the member list any more, so no copy is sealed for them — that is how one
    /// button does exclusion as well as renewal, with no separate "kick" operation to get wrong.
    func testAStaleRegistrationIsNotALicence() {
        XCTAssertEqual(AutoPairing.welcomeRecipients(input(memberIds: ["2"], registeredIds: ["2", "9"])), ["2"])
    }

    func testOurOwnAccountIsNeverARecipient() {
        XCTAssertEqual(AutoPairing.welcomeRecipients(input(memberIds: ["1", "2"], registeredIds: ["1", "2"])), ["2"])
    }

    /// Manual mode distributes face to face; nothing automatic may send a key there. That is the entire
    /// difference between the two modes, not a detail of one.
    func testManualModeSendsNothingAtAll() {
        XCTAssertTrue(AutoPairing.welcomeRecipients(input(mode: .manual, memberIds: ["2"], registeredIds: ["2"])).isEmpty)
    }

    func testADeviceThatCannotIssueAnR1OrHasNoKeySendsNothing() {
        XCTAssertTrue(AutoPairing.welcomeRecipients(input(holdsAdminKey: false, memberIds: ["2"], registeredIds: ["2"])).isEmpty)
        XCTAssertTrue(AutoPairing.welcomeRecipients(input(hasKey: false, memberIds: ["2"], registeredIds: ["2"])).isEmpty)
        XCTAssertTrue(AutoPairing.welcomeRecipients(input(isGroup: false, memberIds: ["2"], registeredIds: ["2"])).isEmpty)
    }

    /// Sorted and de-duplicated so two co-holding devices computing it independently agree on the answer
    func testTheAnswerIsSortedAndDeDuplicated() {
        let out = AutoPairing.welcomeRecipients(input(memberIds: ["4", "2", "2", "3"], registeredIds: ["2", "3", "4"]))
        XCTAssertEqual(out, ["2", "3", "4"])
    }
}

final class ShouldAnnounceIdentityTests: XCTestCase {
    func input(mode: Rekey.KeyMode = .auto, isGroup: Bool = true, isEncrypted: Bool = true, hasKey: Bool = false,
               announcedAt: Int64? = nil, now: Int64 = 1_789_300_000) -> AutoPairing.AnnounceInput {
        return AutoPairing.AnnounceInput(mode: mode, isGroup: isGroup, isEncrypted: isEncrypted, hasKey: hasKey,
                                        announcedAt: announcedAt, now: now)
    }

    /// "I am in an auto-mode encrypted group and I hold no key" covers both cases this exists for without
    /// distinguishing them: a member who has just been added, and one whose key an `N1` retired a moment ago.
    func testAWaitingMemberAnnouncesItself() {
        XCTAssertTrue(AutoPairing.shouldAnnounceIdentity(input()))
    }

    /// It stops on its own: the welcome that answers binds a master, and the condition is false from then on
    func testHoldingAKeyMeansThereIsNothingToWaitFor() {
        XCTAssertFalse(AutoPairing.shouldAnnounceIdentity(input(hasKey: true)))
    }

    func testManualModeAndChatsThatAreNotEncryptedGroupsNeverAnnounce() {
        XCTAssertFalse(AutoPairing.shouldAnnounceIdentity(input(mode: .manual)))
        XCTAssertFalse(AutoPairing.shouldAnnounceIdentity(input(isGroup: false)))
        XCTAssertFalse(AutoPairing.shouldAnnounceIdentity(input(isEncrypted: false)))
    }

    /// The cooldown is only for the case where nobody answers — an admin offline for a week should not collect
    /// one announcement per app start
    func testTheCooldownHoldsItBackAndThenLetsItThrough() {
        let now: Int64 = 1_789_300_000
        XCTAssertFalse(AutoPairing.shouldAnnounceIdentity(input(announcedAt: now - 60, now: now)))
        XCTAssertTrue(AutoPairing.shouldAnnounceIdentity(
            input(announcedAt: now - AutoPairing.announceCooldownSeconds, now: now)))
    }
}

/// PLAN.md 3.34.6: which co-holding device answers a public-key announcement.
final class WelcomeTurnTests: XCTestCase {
    func turn(own: String?, admins: [String]?, count: Int) -> AutoPairing.TurnInput {
        return AutoPairing.TurnInput(ownUserId: own, adminIds: admins, announceCount: count)
    }

    /// The lowest-ranked holder answers the first announcement; the next one answers the second, and so on. A
    /// member stops announcing the moment a key arrives, so "there was a second announcement" already means the
    /// first holder did not answer.
    func testRankDecidesWhichAnnouncementEachHolderAnswers() {
        let admins = ["85", "1000", "77"]
        XCTAssertEqual(AutoPairing.welcomeRank(turn(own: "77", admins: admins, count: 1)), 0)
        XCTAssertEqual(AutoPairing.welcomeRank(turn(own: "85", admins: admins, count: 1)), 1)
        XCTAssertEqual(AutoPairing.welcomeRank(turn(own: "1000", admins: admins, count: 1)), 2)

        XCTAssertTrue(AutoPairing.isOurTurnToWelcome(turn(own: "77", admins: admins, count: 1)))
        XCTAssertFalse(AutoPairing.isOurTurnToWelcome(turn(own: "85", admins: admins, count: 1)))
        XCTAssertTrue(AutoPairing.isOurTurnToWelcome(turn(own: "85", admins: admins, count: 2)))
        XCTAssertTrue(AutoPairing.isOurTurnToWelcome(turn(own: "1000", admins: admins, count: 3)))
    }

    /// Ordered as numbers written down, not as strings: `'1000'` before `'85'` would make two holders compute
    /// different orders, and then either both answer or neither does.
    func testUserIdsAreOrderedAsNumbersNotAsStrings() {
        XCTAssertEqual(AutoPairing.welcomeRank(turn(own: "1000", admins: ["1000", "85"], count: 1)), 1)
        XCTAssertEqual(AutoPairing.welcomeRank(turn(own: "9", admins: ["10", "9"], count: 1)), 0)
    }

    /// Both unknowns resolve towards acting. A duplicate welcome costs one control line and opens the same
    /// master; silence costs somebody their key.
    func testUnknownsRankZeroSoTheDeviceActs() {
        XCTAssertEqual(AutoPairing.welcomeRank(turn(own: "77", admins: nil, count: 1)), 0)
        XCTAssertEqual(AutoPairing.welcomeRank(turn(own: nil, admins: ["85"], count: 1)), 0)
        // Not in the admin list at all — rank 0 rather than "never"
        XCTAssertEqual(AutoPairing.welcomeRank(turn(own: "77", admins: ["85", "1000"], count: 1)), 0)
        XCTAssertTrue(AutoPairing.isOurTurnToWelcome(turn(own: "77", admins: nil, count: 1)))
    }

    /// A member who has not announced yet is owed nothing, whatever this device's rank is
    func testNoAnnouncementMeansNoTurn() {
        XCTAssertFalse(AutoPairing.isOurTurnToWelcome(turn(own: "77", admins: ["77"], count: 0)))
    }
}
