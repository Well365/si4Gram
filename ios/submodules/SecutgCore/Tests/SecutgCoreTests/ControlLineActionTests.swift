import XCTest
@testable import SecutgCore

final class ControlLineActionTests: XCTestCase {
    // MARK: the two that have to be on the row (PLAN.md 3.30 item 1)

    func testAPeersInviteOffersAccept() {
        // Not answering leaves the other person waiting for a reply that never comes.
        XCTAssertEqual(ControlLineAction.onRow(detail: "peer-key:1001:ok:incoming"), .pairAccept)
    }

    func testACompletedPairingOffersTheSafetyCode() {
        // A safety code nobody was ever asked to compare is the failure the whole pairing design is about.
        XCTAssertEqual(ControlLineAction.onRow(detail: "peer-key:1001:ok:paired:123456789012"), .safetyCode)
        XCTAssertEqual(ControlLineAction.onRow(detail: "peer-key:1001:ok:self_paired:123456789012"), .safetyCode)
    }

    func testATakeoverPairedLineStillOffersTheSafetyCode() {
        // `…:paired:<code>:takeover:<device>:<label>` — a longer tail, the same sentence, the same question.
        XCTAssertEqual(ControlLineAction.onRow(detail: "peer-key:1001:ok:paired:123456789012:takeover:AB12:-"),
                       .safetyCode)
    }

    // MARK: the recovery actions that stay in the menu

    func testAChangedPeerKeyOffersTheSafetyCode() {
        // PLAN.md 3.25.11: the peer's new key is adopted before this line is written, so by the time the row
        // is drawn the chat is back on `paired` and the sentence quotes the NEW safety code. Comparing it is
        // the only thing left to do, so the line carries the same button the paired line carries — the
        // answer Android and Web reach from live state alone, without naming this outcome at all.
        XCTAssertEqual(ControlLineAction.onRow(detail: "peer-key:1001:ok:key_changed:AB12:-:CD34:-"), .safetyCode)
        // A line from a device that never recorded the peer's previous device id carries no device fields at
        // all, and still asks the same question of the reader.
        XCTAssertEqual(ControlLineAction.onRow(detail: "peer-key:1001:ok:key_changed"), .safetyCode)
    }

    func testTheRepairLinesOfferNothingOnTheRow() {
        // PLAN.md 3.30 item 1: 〔Re-pair on this device〕 / 〔Re-pair〕 are recovery, and late is fine. Putting
        // them one tap from the text of a warning invites tapping them to make the warning go away.
        XCTAssertNil(ControlLineAction.onRow(detail: "peer-key:1001:ok:other_device:AB12:-"))
        XCTAssertNil(ControlLineAction.onRow(detail: "peer-key:1001:ok:pairing_lost:AB12:-"))
        XCTAssertNil(ControlLineAction.onRow(detail: "peer-key:1001:ok:pairing_moved:AB12:-"))
    }

    func testTheLinesThatStateAFactOfferNothing() {
        XCTAssertNil(ControlLineAction.onRow(detail: "peer-key:1001:ok:self_invited"))
        XCTAssertNil(ControlLineAction.onRow(detail: "peer-key:1001:ok:already_paired"))
        XCTAssertNil(ControlLineAction.onRow(detail: "peer-key:1001:ok:duplicate"))
    }

    func testTheUnpairNoticeOffersNothingOnTheRow() {
        // PLAN.md 3.31.3's `U1` is a third `detail` kind — `unpair:<ok|own_echo|reason>` — and it is the one
        // shape that has no pairing segment at all while still being about a pairing. Nothing on this line is
        // actionable: the key is already destroyed on both sides by the time it is drawn, and re-pairing is a
        // recovery action, which item 1 keeps in the menu. The `peer-key` gate in `onRow` is what makes that
        // true for free, so this pins it before some later reader "simplifies" the gate to a length check.
        XCTAssertNil(ControlLineAction.onRow(detail: "unpair:ok"))
        XCTAssertNil(ControlLineAction.onRow(detail: "unpair:own_echo"))
        XCTAssertNil(ControlLineAction.onRow(detail: "unpair:stale"))
        XCTAssertNil(ControlLineAction.onRow(detail: "unpair:bad_signature"))
    }

    func testRekeyLinesOfferNothing() {
        // `rekey:<type>:<outcome>` has no pairing segment; a naive "parts[3]" read would go out of bounds or,
        // worse, pick up whatever a longer rekey detail grew later.
        XCTAssertNil(ControlLineAction.onRow(detail: "rekey:rotate:ok"))
        XCTAssertNil(ControlLineAction.onRow(detail: "rekey:ratchet:ok"))
        XCTAssertNil(ControlLineAction.onRow(detail: "rekey:reset:unknown_key"))
    }

    // MARK: which sentence the row reads (PLAN.md 3.30.1b)

    /// `SecutgPairInviteHint` is `SecutgPairInvite` plus "— 点锁钮选择「同意配对」". Stand-ins here rather than
    /// the real copy: `SecutgCore` holds no string table, and a test that pinned the wording would fail on
    /// every rewording while saying nothing about the decision, which is what these tests are about.
    private let longSentence = "🔐 they invited you — tap the lock button and choose “Accept pairing”"
    private let shortSentence = "🔐 they invited you"

    private func resolve(_ key: String) -> String {
        return key == "SecutgPairInvite" ? shortSentence : "UNEXPECTED KEY: \(key)"
    }

    func testTheInvitationRowDropsTheDirectionsWhenItHasTheButton() {
        // The button *is* the short way round, so the sentence must stop telling the reader to take the long
        // one. The two together read as two different answers to the same question.
        XCTAssertEqual(ControlLineAction.line(summary: longSentence, action: .pairAccept, localized: resolve),
                       shortSentence)
    }

    func testTheInvitationRowKeepsTheDirectionsWithoutTheButton() {
        // The gate did not pass (already answered, a key arrived another way): the directions are then the
        // only working route the reader has, exactly as on Android where the line is frozen at write time.
        XCTAssertEqual(ControlLineAction.line(summary: longSentence, action: nil, localized: resolve),
                       longSentence)
    }

    func testTheOtherRowsKeepWhatControlSummarySaid() {
        // Only the invitation has a shorter twin in the table; the paired line's sentence carries the safety
        // code and the device codes and must survive intact next to its button.
        XCTAssertNil(ControlLineAction.replacementLineKey(.safetyCode))
        XCTAssertEqual(ControlLineAction.line(summary: longSentence, action: .safetyCode, localized: resolve),
                       longSentence)
    }

    func testTheReplacementNamesTheSharedKey() {
        // Pinned by name so a rename cannot silently swap in a different sentence: `SecutgPairInvite` is the
        // one Web A already shows beside its own 〔同意〕.
        XCTAssertEqual(ControlLineAction.replacementLineKey(.pairAccept), "SecutgPairInvite")
    }

    // MARK: malformed and legacy details

    func testAFailedPeerKeyHasNoPairingSegmentAndOffersNothing() {
        XCTAssertNil(ControlLineAction.onRow(detail: "peer-key:1001:auth_failed"))
        XCTAssertNil(ControlLineAction.onRow(detail: "peer-key:1001:ok"))
    }

    func testNilAndJunkOfferNothing() {
        XCTAssertNil(ControlLineAction.onRow(detail: nil))
        XCTAssertNil(ControlLineAction.onRow(detail: ""))
        XCTAssertNil(ControlLineAction.onRow(detail: "incoming"))
        // The pairing word in the wrong position must not be enough — a button on the wrong sentence is worse
        // than no button, because the sentence is what told the reader what the button would do.
        XCTAssertNil(ControlLineAction.onRow(detail: "peer-key:incoming:ok"))
        XCTAssertNil(ControlLineAction.onRow(detail: "rekey:rotate:ok:incoming"))
    }
}

/// PLAN.md 3.34.6: 〔接受新密钥〕 on the group announcement that replaced a registered key.
final class AdoptGroupKeyActionTests: XCTestCase {
    func testTheGroupKeyChangedLineCarriesTheAdoptAction() {
        XCTAssertEqual(ControlLineAction.onRow(detail: "peer-key:9001:ok:group_key_changed"), .adoptGroupKey)
    }

    /// The private chat's `key_changed` is a pairing state with a completely different road out (3.25.3): it
    /// adopts the key by itself (PLAN.md 3.25.11) and asks the reader to compare the new safety code. It must
    /// therefore reach 〔安全码…〕 and never this button — adopting a *group* member's announced key is a
    /// decision nobody has taken yet, and the two must not be able to reach each other's action.
    func testThePrivateChatsKeyChangedDoesNotReachThisButton() {
        XCTAssertEqual(ControlLineAction.onRow(detail: "peer-key:9001:ok:key_changed:a:-:b:-"), .safetyCode)
    }

    /// Nothing is broken here, so the sentence keeps saying what it said — the button is an answer to it, not
    /// a replacement for directions the reader no longer needs
    func testTheSentenceIsNotSwappedOut() {
        XCTAssertNil(ControlLineAction.replacementLineKey(.adoptGroupKey))
        XCTAssertEqual(ControlLineAction.line(summary: "…", action: .adoptGroupKey, localized: { $0 }), "…")
    }
}
