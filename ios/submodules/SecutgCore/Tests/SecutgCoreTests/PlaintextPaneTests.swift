import XCTest
@testable import SecutgCore

final class PlaintextPaneTests: XCTestCase {
    private func peerPlaintext(_ count: Int) -> [PlaintextPane.Message] {
        return Array(repeating: PlaintextPane.Message(isIncoming: true, hasText: true, meta: nil), count: count)
    }

    private let peerEncrypted = PlaintextPane.Message(isIncoming: true, hasText: true, meta: .decrypted)
    private let ownPlaintext = PlaintextPane.Message(isIncoming: false, hasText: true, meta: nil)
    private let peerNoText = PlaintextPane.Message(isIncoming: true, hasText: false, meta: nil)

    // MARK: what counts as "came through secuTG"

    func testTheNotEncryptedMarkerIsNotItselfASecutgOrigin() {
        // The trap this whole predicate exists for, and the one Web A fell into. `plaintext` is the state
        // behind the per-message "⚠️ this message is not encrypted" marker, attached to plain text from the
        // peer *while this chat encrypts* — i.e. to exactly the messages this pane counts. Reading it as
        // "has a secuTG attribute, therefore was encrypted" makes the pane unable to fire in the only
        // situation it exists for, and the failure is silent: a pane that never shows looks just like a
        // peer who never stopped encrypting.
        XCTAssertFalse(PlaintextPane.carriesSecutgMeta(.plaintext))
        XCTAssertFalse(PlaintextPane.carriesSecutgMeta(nil))

        let marked = Array(repeating: PlaintextPane.Message(isIncoming: true, hasText: true, meta: .plaintext),
                           count: PlaintextPane.threshold)
        XCTAssertTrue(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false, recent: marked))
    }

    func testAnEnvelopeCountsEvenWhenThisDeviceCannotOpenIt() {
        // `undecryptable` is an `E1:` the peer did encrypt and our key cannot open — a missing key here,
        // not plaintext there. Counting it as plaintext would accuse them of something they did not do.
        XCTAssertTrue(PlaintextPane.carriesSecutgMeta(.undecryptable))
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false,
                                           recent: peerPlaintext(2)
                                               + [PlaintextPane.Message(isIncoming: true, hasText: true, meta: .undecryptable)]))
    }

    func testTheOtherSecutgOriginsCount() {
        // `control` is an `R1:` / `P1:` — how the peer sets encryption *up*, the opposite of abandoning it.
        XCTAssertTrue(PlaintextPane.carriesSecutgMeta(.control))
        XCTAssertTrue(PlaintextPane.carriesSecutgMeta(.decrypted))
        XCTAssertTrue(PlaintextPane.carriesSecutgMeta(.groupInvite))
        XCTAssertTrue(PlaintextPane.carriesSecutgMeta(.sealed))

        for meta in [PlaintextPane.Meta.control, .decrypted, .groupInvite, .sealed] {
            XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false,
                                               recent: peerPlaintext(2)
                                                   + [PlaintextPane.Message(isIncoming: true, hasText: true, meta: meta)]),
                           "\(meta) must break the plaintext run")
        }
    }

    // MARK: the judgement itself

    func testShownWhenTheLastThreeFromThePeerAreAllPlaintext() {
        XCTAssertTrue(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false, recent: peerPlaintext(3)))
    }

    func testHiddenWhenOneOfTheThreeWasEncrypted() {
        // The newest one encrypting is enough: the peer is not stuck in plaintext.
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false,
                                           recent: peerPlaintext(2) + [peerEncrypted]))
        // …and so is the oldest of the three, which is what makes this "three in a row" rather than
        // "three at some point".
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false,
                                           recent: [peerEncrypted] + peerPlaintext(2)))
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false,
                                           recent: peerPlaintext(1) + [peerEncrypted] + peerPlaintext(1)))
    }

    func testHiddenWithFewerThanThreeMessagesFromThePeer() {
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false, recent: []))
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false, recent: peerPlaintext(1)))
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false, recent: peerPlaintext(2)))
    }

    func testOurOwnMessagesDoNotCount() {
        // Neither as evidence…
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false,
                                           recent: peerPlaintext(2) + [ownPlaintext]))
        // …nor as a break in the peer's run: replying in between changes nothing about what they sent.
        XCTAssertTrue(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false,
                                          recent: [peerPlaintext(1), [ownPlaintext], peerPlaintext(1),
                                                   [ownPlaintext], peerPlaintext(1)].flatMap { $0 }))
    }

    func testMessagesWithoutTextDoNotCount() {
        // Only text is ever encrypted, so a photo from the peer is not evidence either way.
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false,
                                           recent: peerPlaintext(2) + [peerNoText]))
        XCTAssertTrue(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false,
                                          recent: peerPlaintext(1) + [peerNoText] + peerPlaintext(2)))
    }

    // MARK: the window of 20

    func testOnlyTheLastTwentyListedMessagesAreLookedAt() {
        // Three plaintext messages from the peer, then twenty of our own: the evidence has scrolled out
        // of the window, and "lately" is what the pane is about.
        let recent = peerPlaintext(3) + Array(repeating: ownPlaintext, count: PlaintextPane.recentWindow)
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false, recent: recent))
    }

    func testTheWindowIsCutBeforeFilteringNotAfter() {
        // Exactly twenty messages back, the three from the peer are still inside the window.
        let recent = peerPlaintext(3) + Array(repeating: ownPlaintext, count: PlaintextPane.recentWindow - 3)
        XCTAssertEqual(recent.count, PlaintextPane.recentWindow)
        XCTAssertTrue(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false, recent: recent))
    }

    func testOlderEncryptedMessagesOutsideTheLastThreeDoNotMatter() {
        // The chat used to be encrypted and is not any more — which is precisely the situation to warn about.
        let recent = Array(repeating: peerEncrypted, count: 10) + peerPlaintext(3)
        XCTAssertTrue(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: false, recent: recent))
    }

    // MARK: the two preconditions

    func testHiddenWhenThisChatDoesNotEncrypt() {
        // Both ends sending plaintext is not a disagreement; there is nothing to report.
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: false, isDismissed: false, recent: peerPlaintext(3)))
    }

    func testHiddenOnceDismissedInThisSession() {
        XCTAssertFalse(PlaintextPane.isDue(isChatEncrypted: true, isDismissed: true, recent: peerPlaintext(3)))
    }

    // MARK: the message half on its own

    func testIsPeerPlaintextIgnoresTheChatStateAndTheDismissal() {
        // What the client caches from the message list; `isDue` adds the two live facts on top.
        XCTAssertTrue(PlaintextPane.isPeerPlaintext(recent: peerPlaintext(3)))
        XCTAssertFalse(PlaintextPane.isPeerPlaintext(recent: peerPlaintext(2)))
    }
}
