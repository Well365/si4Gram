import XCTest
@testable import SecutgCore

/// PLAN.md 3.24: which of the six shapes the encryption guide takes in a private chat, and every
/// reason it stays hidden. Ported case for case from the Web reference (`src/secutg/onboard/card.test.ts`)
/// so the two clients cannot drift apart on a boundary.
final class OnboardCardTests: XCTestCase {
    private static let now: Int64 = 1_800_000_000
    private static let day: Int64 = 86_400

    /// A fresh private chat with nobody's key in it: the plain case the card exists for.
    private func fresh(
        isPrivateChat: Bool = true,
        isBot: Bool = false,
        isServiceAccount: Bool = false,
        hasKey: Bool = false,
        pairingState: KeyRing.Pairing.State? = nil,
        hasPeerKey: Bool = false,
        startedAt: Int64? = nil,
        nowSeconds: Int64 = OnboardCardTests.now,
        memory: OnboardMemory = .count(0),
        isStrangerNoticeVisible: Bool = false,
        isHandoffNoticeVisible: Bool = false
    ) -> OnboardCard.Input {
        return OnboardCard.Input(
            isPrivateChat: isPrivateChat, isBot: isBot, isServiceAccount: isServiceAccount, hasKey: hasKey,
            pairingState: pairingState, hasPeerKey: hasPeerKey, startedAt: startedAt, nowSeconds: nowSeconds,
            memory: memory, isStrangerNoticeVisible: isStrangerNoticeVisible,
            isHandoffNoticeVisible: isHandoffNoticeVisible)
    }

    private func card(_ form: OnboardCard.Form, _ isCompact: Bool = false) -> OnboardCard.Shape {
        return .card(form: form, isCompact: isCompact)
    }

    // MARK: where the card may appear at all (PLAN.md 3.24.1)

    func testPlainUnencryptedPrivateChatGetsTheGuide() {
        XCTAssertEqual(OnboardCard.evaluate(fresh()), card(.offer))
    }

    func testGroupsNeverGetIt() {
        // Their key comes from an admin (PLAN.md 3.13), so there are no two roads to choose between.
        XCTAssertEqual(OnboardCard.evaluate(fresh(isPrivateChat: false)), .hidden)
    }

    func testBotsAndTheServiceAccountAreNotSomebodyToPairWith() {
        XCTAssertEqual(OnboardCard.evaluate(fresh(isBot: true)), .hidden)
        XCTAssertEqual(OnboardCard.evaluate(fresh(isServiceAccount: true)), .hidden)
    }

    // MARK: the six shapes, one per 3.7 state (PLAN.md 3.24.1)

    func testInvitedByUsIsWaiting() {
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .invited, startedAt: Self.now - Self.day)),
                       card(.waiting))
    }

    func testPeerRegisteredAKeyFirstIsIncoming() {
        XCTAssertEqual(OnboardCard.evaluate(fresh(hasPeerKey: true)), card(.incoming))
    }

    func testPairedIsGone() {
        XCTAssertEqual(OnboardCard.evaluate(fresh(hasKey: true, pairingState: .paired)), .hidden)
    }

    func testAKeyFromAnyOtherRoadIsGone() {
        // Manual pairing, an import, or a keyring carried over from another device.
        XCTAssertEqual(OnboardCard.evaluate(fresh(hasKey: true)), .hidden)
    }

    func testKeyChangedShowsNothingEvenThoughThisChatIsNotEncryptingRightNow() {
        // PLAN.md 3.24.1: the key-change warning owns the screen. A warning that an invitation to
        // encrypt is sitting on top of is a warning nobody reads.
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .keyChanged)), .hidden)
        // and it stays hidden however the rest of the state looks — in particular it is judged
        // before `hasKey`, so it is a rule of its own and not a side effect of a leftover key
        XCTAssertEqual(OnboardCard.evaluate(fresh(hasKey: false, pairingState: .keyChanged, hasPeerKey: true)),
                       .hidden)
        XCTAssertEqual(OnboardCard.evaluate(fresh(hasKey: true, pairingState: .keyChanged)), .hidden)
    }

    func testOtherDeviceIsMoved() {
        // PLAN.md 3.24.6 rule 3 / 3.25.5.3: on a client whose take-over notice is an inline block in
        // the message flow, that block wins while it is up and this card takes over afterwards.
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .otherDevice, isHandoffNoticeVisible: true)),
                       .hidden)
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .otherDevice)), card(.moved))
    }

    func testOnThisClientMovedAlwaysRenders() {
        // iOS and macOS show the 3.25.5.3 take-over notice as a dialog (`SecutgHandoffDialogs`),
        // which does not occupy the message flow, so there is no block for `moved` to collide with:
        // the input defaults to false and the card renders. Pinned here because a later change that
        // started setting it would silently delete this shape's only way out.
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .otherDevice)), card(.moved))
    }

    // MARK: an invitation goes stale after seven days, and nothing else changes (PLAN.md 3.24.5 rule 2)

    func testADayOldInvitationStillReadsAsWaiting() {
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .invited, startedAt: Self.now - Self.day)),
                       card(.waiting))
    }

    func testOneSecondBeforeSevenDaysItIsStillWaiting() {
        let startedAt = Self.now - OnboardCard.pairingInviteStaleDays * Self.day + 1
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .invited, startedAt: startedAt)), card(.waiting))
    }

    func testAtSevenDaysTheWordingChanges() {
        let startedAt = Self.now - OnboardCard.pairingInviteStaleDays * Self.day
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .invited, startedAt: startedAt)), card(.stale))
    }

    func testGoingStaleChangesTheWordingOnly() {
        // PLAN.md 3.24.5 rule 2: a P1 arriving on day 30 still completes the pairing (3.7 rule 3).
        // The card has no way to clear `pairing` and must never grow one: `stale` is still the
        // `invited` state, and it still offers withdraw and the offline road, not a restart.
        let old = fresh(pairingState: .invited, startedAt: Self.now - 30 * Self.day)
        XCTAssertEqual(OnboardCard.evaluate(old), card(.stale))
        // the very same input, one day in, is the same state under a gentler name
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .invited, startedAt: Self.now - Self.day)),
                       card(.waiting))
        // the state is still `invited`, so the two buttons `waiting` and `stale` carry are the same
        // pair; nothing in this file can turn `stale` into "no pairing"
        XCTAssertEqual(old.pairingState, .invited)
        // and once that late P1 lands, 3.7 — not this file — moves it on
        XCTAssertEqual(OnboardCard.evaluate(fresh(hasKey: true, pairingState: .paired)), .hidden)
    }

    func testWithoutAStartTimeWeMakeTheWeakerClaim() {
        // "They have not accepted" is a claim about elapsed time we cannot back up here.
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .invited)), card(.waiting))
    }

    // MARK: "not now", twice, retires the card (PLAN.md 3.24.8)

    func testTheFirstNotNowShrinksItToOneLine() {
        XCTAssertEqual(OnboardMemory.count(0).afterNotNow, .count(1))
        XCTAssertEqual(OnboardCard.evaluate(fresh(memory: .count(1))), card(.offer, true))
    }

    func testTheSecondNotNowRetiresItForGood() {
        XCTAssertEqual(OnboardMemory.count(1).afterNotNow, .never)
        XCTAssertEqual(OnboardCard.evaluate(fresh(memory: .never)), .hidden)
    }

    func testNeverIsFinalAndCannotBeWalkedBack() {
        XCTAssertEqual(OnboardMemory.never.afterNotNow, .never)
        XCTAssertEqual(OnboardMemory.never.afterUnpair, .never)
    }

    func testRetiredMeansRetiredInEveryStateNotJustTheGuide() {
        XCTAssertEqual(OnboardCard.evaluate(fresh(hasPeerKey: true, memory: .never)), .hidden)
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .invited, memory: .never)), .hidden)
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .otherDevice, memory: .never)), .hidden)
    }

    func testReplyingToThePeerIsNotWhatRetiresIt() {
        // PLAN.md 3.24.8: encryption does not become less worth having because a chat is old, so
        // there is deliberately no `hasRepliedTo` input to copy over from the 3.23 stranger notice.
        // A chat with plenty of history and no key still gets the full guide.
        XCTAssertEqual(OnboardCard.evaluate(fresh()), card(.offer))
        let mirror = Mirror(reflecting: fresh())
        XCTAssertFalse(mirror.children.contains(where: { $0.label == "hasRepliedTo" }))
    }

    // MARK: unpairing comes back collapsed, not full size (PLAN.md 3.24.5 rule 3 / 3.24.8)

    func testUnpairingCountsAsAlreadyIgnoredOnce() {
        XCTAssertEqual(OnboardMemory.count(0).afterUnpair, .count(1))
        // which is exactly the compact guide, not the full one
        XCTAssertEqual(OnboardCard.evaluate(fresh(memory: OnboardMemory.count(0).afterUnpair)), card(.offer, true))
    }

    func testUnpairingNeverLowersACountThatIsAlreadyHigher() {
        XCTAssertEqual(OnboardMemory.count(1).afterUnpair, .count(1))
        XCTAssertEqual(OnboardMemory.count(3).afterUnpair, .count(3))
    }

    // MARK: sharing the screen with the 3.23 stranger block (PLAN.md 3.24.3)

    func testWhileTheStrangerBlockIsUpTheCardCollapses() {
        // Two expanded blocks push the first message — the thing the user came to read — off screen.
        XCTAssertEqual(OnboardCard.evaluate(fresh(isStrangerNoticeVisible: true)), card(.offer, true))
    }

    func testCollapsingAppliesWhateverTheUnderlyingShapeIs() {
        XCTAssertEqual(OnboardCard.evaluate(fresh(hasPeerKey: true, isStrangerNoticeVisible: true)),
                       card(.incoming, true))
        XCTAssertEqual(OnboardCard.evaluate(fresh(pairingState: .otherDevice, isStrangerNoticeVisible: true)),
                       card(.moved, true))
    }

    func testWhenTheStrangerBlockGoesTheFullCardComesBack() {
        // 3.24.3 rule 3: nothing is remembered about the collapse; it is purely a co-tenancy rule.
        XCTAssertEqual(OnboardCard.evaluate(fresh(isStrangerNoticeVisible: false)), card(.offer, false))
    }

    func testACollapseIsNotADismissal() {
        XCTAssertEqual(OnboardCard.evaluate(fresh(memory: .count(0), isStrangerNoticeVisible: true)),
                       card(.offer, true))
        // still only one "not now" away from compact-by-memory, not from retirement
        XCTAssertEqual(OnboardMemory.count(0).afterNotNow, .count(1))
    }

    /// The same answer 3.23 itself gives, rather than a second derivation of "is 3.23 showing".
    /// PLAN.md 3.24.3 rule 2 only holds if both blocks agree on that, which is why the UI is required
    /// to feed this input from `StrangerNotice.evaluate` and never from its own copy of the rules.
    func testTheStrangerInputIsWhateverStrangerNoticeItselfSays() {
        let stranger = StrangerNotice.Input(isPrivateChat: true, isContact: false, isBot: false,
                                            hasRepliedTo: false, decision: .unasked, commonChats: nil)
        let visible = StrangerNotice.evaluate(stranger) != .hidden
        XCTAssertTrue(visible)
        XCTAssertEqual(OnboardCard.evaluate(fresh(isStrangerNoticeVisible: visible)), card(.offer, true))

        let replied = StrangerNotice.Input(isPrivateChat: true, isContact: false, isBot: false,
                                           hasRepliedTo: true, decision: .unasked, commonChats: nil)
        let goneVisible = StrangerNotice.evaluate(replied) != .hidden
        XCTAssertFalse(goneVisible)
        XCTAssertEqual(OnboardCard.evaluate(fresh(isStrangerNoticeVisible: goneVisible)), card(.offer, false))
    }

    // MARK: no shape is a dead end (PLAN.md 3.24.5 rule 4)

    func testAllSixShapesAreReachable() {
        // The acceptance criterion of 3.24.5 rule 4 is that each of these is clickable in the UI;
        // what can be pinned down here is that each is actually produced, so none is dead code
        // nobody drew.
        let shapes: [(String, OnboardCard.Input)] = [
            ("offer", fresh()),
            ("incoming", fresh(hasPeerKey: true)),
            ("waiting", fresh(pairingState: .invited, startedAt: Self.now - Self.day)),
            ("stale", fresh(pairingState: .invited, startedAt: Self.now - 30 * Self.day)),
            ("moved", fresh(pairingState: .otherDevice)),
            ("compact", fresh(memory: .count(1))),
        ]
        let produced = shapes.map { _, input -> String in
            guard case let .card(form, isCompact) = OnboardCard.evaluate(input) else { return "hidden" }
            return isCompact ? "compact" : form.rawValue
        }
        XCTAssertEqual(produced, ["offer", "incoming", "waiting", "stale", "moved", "compact"])
    }

    func testTheStaleThresholdIsSevenDaysOnEveryClient() {
        XCTAssertEqual(OnboardCard.pairingInviteStaleDays, 7)
    }
}
