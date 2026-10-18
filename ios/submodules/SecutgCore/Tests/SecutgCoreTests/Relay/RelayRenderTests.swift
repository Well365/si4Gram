import XCTest
@testable import SecutgCore

final class RelayRenderTests: XCTestCase {
    private func ref(key: String? = nil) -> RelayL1Reference {
        return RelayL1Reference(relayURL: "https://relay.example.com", id: "AAAAAAAAAAAAAAAAAAAAAA", contentType: .text, mime: "text/plain;charset=utf-8", sizeBytes: 5, maxReads: 1, expiresAt: 9_999_999_999, contentKey: key)
    }

    func testNonL1TextIsNilRegardlessOfSettings() {
        XCTAssertNil(RelayRender.classify(text: "hello world", localCopy: nil, showCards: false, askUnknownRelay: true, allowInsecureOrLAN: false, isTrusted: { _ in false }))
        XCTAssertNil(RelayRender.classify(text: "", localCopy: nil, showCards: true, askUnknownRelay: true, allowInsecureOrLAN: true, isTrusted: { _ in true }))
    }

    func testLocalCopyWinsOverEverything() {
        let copy = RelayLocalCopy(chatId: "1", messageId: 2, contentType: .text, mime: "text/plain;charset=utf-8", text: "hi", imageData: nil, savedAtMs: 0, direction: .received)
        let wire = RelayL1.encode(ref())
        let state = RelayRender.classify(text: wire, localCopy: copy, showCards: false, askUnknownRelay: true, allowInsecureOrLAN: false, isTrusted: { _ in false })
        XCTAssertEqual(state, .localCopy(copy))
    }

    func testInvalidWire() {
        let state = RelayRender.classify(text: "L1:not valid", localCopy: nil, showCards: true, askUnknownRelay: false, allowInsecureOrLAN: true, isTrusted: { _ in true })
        if case .invalid = state {} else { XCTFail("expected invalid, got \(String(describing: state))") }
    }

    func testReceivingOff() {
        let wire = RelayL1.encode(ref())
        let state = RelayRender.classify(text: wire, localCopy: nil, showCards: false, askUnknownRelay: false, allowInsecureOrLAN: true, isTrusted: { _ in true })
        XCTAssertEqual(state, .receivingOff)
    }

    func testInsecureOrLANBlockedBeforeTrustCheck() {
        let insecureRef = RelayL1Reference(relayURL: "http://relay.example.com", id: "AAAAAAAAAAAAAAAAAAAAAA", contentType: .text, mime: "text/plain;charset=utf-8", sizeBytes: 5, maxReads: 1, expiresAt: 9_999_999_999, contentKey: nil)
        let wire = RelayL1.encode(insecureRef)
        let state = RelayRender.classify(text: wire, localCopy: nil, showCards: true, askUnknownRelay: false, allowInsecureOrLAN: false, isTrusted: { _ in true })
        if case .insecureOrLAN = state {} else { XCTFail("expected insecureOrLAN, got \(String(describing: state))") }
    }

    func testUnknownRelayAsksWhenNotTrusted() {
        let wire = RelayL1.encode(ref())
        let state = RelayRender.classify(text: wire, localCopy: nil, showCards: true, askUnknownRelay: true, allowInsecureOrLAN: false, isTrusted: { _ in false })
        if case .unknownRelay = state {} else { XCTFail("expected unknownRelay, got \(String(describing: state))") }
    }

    func testReadyWhenTrustedAndSecure() {
        let wire = RelayL1.encode(ref())
        let state = RelayRender.classify(text: wire, localCopy: nil, showCards: true, askUnknownRelay: true, allowInsecureOrLAN: false, isTrusted: { _ in true })
        if case .ready = state {} else { XCTFail("expected ready, got \(String(describing: state))") }
    }
}
