import XCTest
@testable import SecutgCore

/// PLAN.md 3.17 rule 6: which bytes the "show ciphertext" dialog is handed, and — the part that matters — which
/// bytes it is never handed. Ported from the Web reference (`src/secutg/ui/ciphertext.test.ts`).
final class MessageCiphertextTests: XCTestCase {
    private static let wire = "E1:aab2.20260913:bm9uY2U:Y2lwaGVy"

    func testAMessageThatNeverOpenedIsItsOwnEnvelope() {
        // PLAN.md 3.17 rule 2: storage kept the ciphertext, only the rendering layer put a sentence in its place
        XCTAssertEqual(MessageCiphertext.resolve(form: .envelopeIsText, storedText: Self.wire, envelope: nil),
                       Self.wire)
    }

    func testAMessageStoredSealedIsItsOwnEnvelopeToo() {
        // PLAN.md 3.19: the words are in memory, the disk holds the envelope, and that is what is offered
        XCTAssertEqual(MessageCiphertext.resolve(form: .envelopeIsText, storedText: Self.wire, envelope: nil),
                       Self.wire)
    }

    func testAMessageThatDidOpenOffersTheEnvelopeItCameOutOf() {
        // carrying a message to another device and checking it are not about whether it opened here
        XCTAssertEqual(
            MessageCiphertext.resolve(form: .wordsWithEnvelope, storedText: "nine, the usual place", envelope: Self.wire),
            Self.wire)
    }

    func testADecryptedMessageWhoseEnvelopeWasNotKeptOffersNothingRatherThanItsWords() {
        // a message stored before the envelope was kept: no bytes, and the entry is simply absent
        XCTAssertNil(MessageCiphertext.resolve(form: .wordsWithEnvelope, storedText: "nine, the usual place", envelope: nil))
    }

    func testTheWordsAreNeverHandedOutAsCiphertextEvenWhenTheyLookLikeAnEnvelope() {
        // somebody quoting a wire in a message: the plaintext begins with `E1:` and is still the plaintext. The
        // form decides which value is read, which is why this cannot become a leak under a label that promises
        // the opposite.
        XCTAssertNil(MessageCiphertext.resolve(form: .wordsWithEnvelope, storedText: Self.wire, envelope: nil))
    }

    func testTheHeadOfAFoldedRunKeepsItsOwnEnvelope() {
        // PLAN.md 3.17 rule 5: the anchor is the real message and its ciphertext is untouched underneath the line
        XCTAssertEqual(MessageCiphertext.resolve(form: .envelopeIsText, storedText: Self.wire, envelope: nil),
                       Self.wire)
    }

    func testAnOrdinaryMessageHasNoEnvelopeAndNeitherHasAControlLine() {
        XCTAssertNil(MessageCiphertext.resolve(form: .none, storedText: "hello", envelope: nil))
        XCTAssertNil(MessageCiphertext.resolve(form: .none, storedText: Self.wire, envelope: Self.wire))
        XCTAssertNil(MessageCiphertext.resolve(form: .envelopeIsText, storedText: nil, envelope: nil))
    }

    func testNothingThatIsNotAnEnvelopeIsEverHandedOutAsOne() {
        // a defensive belt: the only text that reaches the dialog is text that looks like the wire format —
        // a control line is a wire too, but it is never "ciphertext" to look at
        XCTAssertNil(MessageCiphertext.resolve(form: .envelopeIsText, storedText: "P2:whatever", envelope: nil))
        XCTAssertNil(MessageCiphertext.resolve(form: .envelopeIsText, storedText: "G2:whatever", envelope: nil))
        XCTAssertNil(MessageCiphertext.resolve(form: .envelopeIsText, storedText: "", envelope: nil))
        XCTAssertNil(MessageCiphertext.resolve(form: .wordsWithEnvelope, storedText: "hi", envelope: "not an envelope"))
    }

    func testAV2EnvelopeIsOfferedOnTheSameTermsAsAV1One() {
        // PLAN.md 3.44: a v2 row is put away behind `E2:` exactly as a v1 row behind `E1:`, and the dialog that
        // carries a message to another device or checks it for alteration serves both generations
        let v2 = "E2:eyJoZWFkZXIiOnt9fQ"
        XCTAssertEqual(MessageCiphertext.resolve(form: .envelopeIsText, storedText: v2, envelope: nil), v2)
        XCTAssertEqual(MessageCiphertext.resolve(form: .wordsWithEnvelope, storedText: "the words", envelope: v2), v2)
        // and the words are still never handed out as ciphertext, whichever prefix they happen to start with
        XCTAssertNil(MessageCiphertext.resolve(form: .wordsWithEnvelope, storedText: v2, envelope: nil))
    }

    func testAMalformedEnvelopeIsStillOffered() {
        // the strict parser would hand back nothing in exactly the case where somebody needs the bytes most:
        // "this message may have been altered" (rule 1's `auth_failed` line) is settled only by looking at them
        let damaged = "E1:aab2.20260913:bm9uY2U"
        XCTAssertFalse(E1Format.isEncrypted(damaged))
        XCTAssertEqual(MessageCiphertext.resolve(form: .envelopeIsText, storedText: damaged, envelope: nil), damaged)
    }
}
