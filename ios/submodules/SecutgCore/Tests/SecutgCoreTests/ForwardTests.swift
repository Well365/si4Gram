import XCTest
@testable import SecutgCore

/// Mirrors Web A `src/secutg/hooks/forward.test.ts` (PLAN.md 3.20).
final class ForwardTests: XCTestCase {
    private struct Msg: Equatable {
        let text: String
        let hasMedia: Bool
    }

    private let text = Msg(text: "hello", hasMedia: false)
    private let photo = Msg(text: "a caption", hasMedia: true)
    private let empty = Msg(text: "", hasMedia: false)

    private func reencryptable(_ m: Msg) -> Bool {
        return SecutgForward.isReencryptable(text: m.text, hasMedia: m.hasMedia)
    }

    func testOnlyAMessageThatIsNothingButTextCanBeResentEncrypted() {
        XCTAssertTrue(SecutgForward.isTextOnly(text: "hello", hasMedia: false))
        // a caption cannot be separated from its photo, and the photo is not ours to encrypt
        XCTAssertFalse(SecutgForward.isTextOnly(text: "a caption", hasMedia: true))
        XCTAssertFalse(SecutgForward.isTextOnly(text: "", hasMedia: false))
    }

    func testCiphertextAndControlMessagesTravelByteForByte() {
        // PLAN.md 3.17: a message this device could not open is stored as its `E1:` payload. An origin line in front
        // of it would stop it parsing, and re-encrypting it under a second key helps nobody.
        let wire = try! E1Codec.encrypt(text: "hello", entities: nil, keyId: "abcdef0123456789.20260914", sessionKey: [UInt8](repeating: 7, count: 32))
        XCTAssertTrue(E1Format.isEncrypted(wire))
        XCTAssertFalse(SecutgForward.isReencryptable(text: wire, hasMedia: false))
        XCTAssertFalse(SecutgForward.isReencryptable(text: "R1:{}", hasMedia: false))
        XCTAssertFalse(SecutgForward.isReencryptable(text: "P1:{}", hasMedia: false))
        XCTAssertTrue(SecutgForward.isReencryptable(text: "hello", hasMedia: false))
    }

    func testAnEncryptedTargetSplitsTheBatchAnOrdinaryOneIsLeftAlone() {
        let split = SecutgForward.split([text, photo, empty], isTargetEncrypted: true, isReencryptable: reencryptable)
        XCTAssertEqual(split.reencrypt, [text])
        XCTAssertEqual(split.forward, [photo, empty])

        let untouched = SecutgForward.split([text, photo], isTargetEncrypted: false, isReencryptable: reencryptable)
        XCTAssertEqual(untouched.reencrypt, [])
        XCTAssertEqual(untouched.forward, [text, photo])
    }

    func testTheOriginTravelsInsideTheCiphertextAndNothingIsAddedWhenThereIsNone() {
        XCTAssertEqual(SecutgForward.withOriginLine(text: "hi", origin: "Alex", originLabel: "Forwarded from Alex"), "Forwarded from Alex\nhi")
        XCTAssertEqual(SecutgForward.withOriginLine(text: "hi", origin: nil, originLabel: "Forwarded from Alex"), "hi")
        XCTAssertEqual(SecutgForward.withOriginLine(text: "hi", origin: "", originLabel: "Forwarded from "), "hi")
    }
}
