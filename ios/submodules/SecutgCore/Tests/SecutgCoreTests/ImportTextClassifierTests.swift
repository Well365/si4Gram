import XCTest

@testable import SecutgCore

/// PLAN.md 3.6 vs 3.14: which of the two import dialogs a pasted string belongs to. Asymmetric on
/// purpose — see `ImportText` — and the cross-client `classify` cases of the `k1` vector pin the same
/// answers on all five clients.
final class ImportTextClassifierTests: XCTestCase {
    func testRecognisesAnOfflineKeyOnlyWhenItReallyParses() {
        let payload = KeyPayload.build(masterKey: [UInt8](repeating: 0x42, count: 32), adminPk: nil)
        XCTAssertEqual(ImportText.classify(payload), .keyPayload)
        XCTAssertEqual(ImportText.classify("  \(payload)\n"), .keyPayload)
        // a broken payload stays in the dialog it was pasted into: there is nowhere better for it
        XCTAssertEqual(ImportText.classify("secutg://key?tooshort"), .unknown)
    }

    func testRecognisesATransferFileByItsPrefixAloneDamagedOrNot() {
        // the user still has to be sent to the transfer dialog; telling them the text is meaningless
        // is exactly the unhelpful answer this type exists to replace
        XCTAssertEqual(ImportText.classify("K1:1:AAAA:BBBB"), .k1)
        XCTAssertEqual(ImportText.classify("   K1:1:aa:bb"), .k1)
        XCTAssertEqual(ImportText.classify("K1:"), .k1)
    }

    func testRefusesToGuess() {
        XCTAssertEqual(ImportText.classify(""), .unknown)
        XCTAssertEqual(ImportText.classify("here is the key I promised"), .unknown)
        XCTAssertEqual(ImportText.classify("E1:0123456789abcdef.20260911:AAAA:BBBB"), .unknown)
        XCTAssertEqual(ImportText.classify("K1"), .unknown)        // a word, not a container
        XCTAssertEqual(ImportText.classify("k1:1:AA:BB"), .unknown) // the prefix is case sensitive
    }

    func testNamesTheKindsTheWayTheVectorsDo() {
        XCTAssertEqual(ImportTextKind.unknown.rawValue, "unknown")
        XCTAssertEqual(ImportTextKind.keyPayload.rawValue, "keyPayload")
        XCTAssertEqual(ImportTextKind.k1.rawValue, "k1")
    }
}
