import XCTest
@testable import SecutgCore

/// PLAN.md review HIGH-2: pure-function coverage for the byte caps `RelayClient` enforces against a relay
/// response, independent of any actual networking.
final class RelayCapTests: XCTestCase {
    func testEnvelopeOverheadIsNonceTagSum() {
        XCTAssertEqual(RelayCap.envelopeOverheadBytes, 40)
    }

    func testAbsoluteItemCeilingIs20MiBPlus40() {
        XCTAssertEqual(RelayCap.absoluteItemCeilingBytes, 20 * 1024 * 1024 + 40)
    }

    func testMetadataCapIs16KiB() {
        XCTAssertEqual(RelayCap.metadataCapBytes, 16 * 1024)
    }

    func testExpectedItemBytesUnencryptedEqualsPlaintextSize() {
        XCTAssertEqual(RelayCap.expectedItemBytes(plaintextSize: 100, isEncrypted: false), 100)
    }

    func testExpectedItemBytesEncryptedAddsEnvelopeOverhead() {
        XCTAssertEqual(RelayCap.expectedItemBytes(plaintextSize: 100, isEncrypted: true), 140)
    }

    func testExpectedItemBytesZeroPlaintext() {
        XCTAssertEqual(RelayCap.expectedItemBytes(plaintextSize: 0, isEncrypted: false), 0)
        XCTAssertEqual(RelayCap.expectedItemBytes(plaintextSize: 0, isEncrypted: true), 40)
    }

    func testItemCapMatchesExpectedBytesWhenUnderCeiling() {
        XCTAssertEqual(RelayCap.itemCap(plaintextSize: 100, isEncrypted: true), 140)
    }

    func testItemCapClampsToAbsoluteCeiling() {
        // A reference should never legitimately claim more than `RelayL1.maxBytes`, but the cap must not trust
        // that blindly — it clamps to the absolute ceiling regardless of what `plaintextSize` says.
        let huge = RelayL1.maxBytes + 1_000_000
        XCTAssertEqual(RelayCap.itemCap(plaintextSize: huge, isEncrypted: true), RelayCap.absoluteItemCeilingBytes)
    }

    func testIsAcceptableClaimedLengthUnknownAlwaysPasses() {
        XCTAssertTrue(RelayCap.isAcceptableClaimedLength(-1, cap: 10))
    }

    func testIsAcceptableClaimedLengthAtCapPasses() {
        XCTAssertTrue(RelayCap.isAcceptableClaimedLength(10, cap: 10))
    }

    func testIsAcceptableClaimedLengthOverCapFails() {
        XCTAssertFalse(RelayCap.isAcceptableClaimedLength(11, cap: 10))
    }

    func testExceedsCapSoFarAtCapIsFalse() {
        XCTAssertFalse(RelayCap.exceedsCapSoFar(receivedBytes: 10, cap: 10))
    }

    func testExceedsCapSoFarOneOverCapIsTrue() {
        XCTAssertTrue(RelayCap.exceedsCapSoFar(receivedBytes: 11, cap: 10))
    }

    func testExceedsCapSoFarWellUnderCapIsFalse() {
        XCTAssertFalse(RelayCap.exceedsCapSoFar(receivedBytes: 0, cap: 10))
    }

    func testIsExactLengthMatchingPasses() {
        XCTAssertTrue(RelayCap.isExactLength(5, expectedBytes: 5))
    }

    func testIsExactLengthShortFails() {
        XCTAssertFalse(RelayCap.isExactLength(4, expectedBytes: 5))
    }

    func testIsExactLengthLongFails() {
        XCTAssertFalse(RelayCap.isExactLength(6, expectedBytes: 5))
    }
}
