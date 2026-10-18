import XCTest
@testable import SecutgCore

/// Ported from Android's `CrockfordTest.java` — v1.4 section 17: "a 32-byte random carry secret,
/// Crockford Base32 is 52 characters, in 13 groups".
final class V2CrockfordTests: XCTestCase {

    func testA32ByteSecretEncodesTo52SymbolsIn13GroupsOf4() {
        let secret = [UInt8](repeating: 0xab, count: 32)
        let encoded = V2Crockford.encodeCarrySecret(secret)
        XCTAssertNotNil(encoded)
        let groups = encoded!.split(separator: "-", omittingEmptySubsequences: false)
        XCTAssertEqual(groups.count, 13)
        for group in groups { XCTAssertEqual(group.count, 4) }
        XCTAssertEqual(encoded!.replacingOccurrences(of: "-", with: "").count, V2Crockford.carrySecretSymbols)
    }

    func testTheAlphabetNeverContainsILOOrU() {
        var secret = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { secret[i] = UInt8((i * 8) % 256) }
        let encoded = V2Crockford.encodeCarrySecret(secret)!
        XCTAssertNil(encoded.range(of: "[ILOU]", options: .regularExpression))
    }

    func testANon32ByteInputIsRefused() {
        XCTAssertNil(V2Crockford.encodeCarrySecret([UInt8](repeating: 0, count: 16)))
        XCTAssertNil(V2Crockford.encodeCarrySecret([UInt8](repeating: 0, count: 33)))
    }

    func testRoundTripsThroughEncodeForManyRandomIshSecrets() {
        for seed in 0..<20 {
            var secret = [UInt8](repeating: 0, count: 32)
            for i in 0..<32 { secret[i] = UInt8((seed * 37 + i * 91) % 256) }
            let encoded = V2Crockford.encodeCarrySecret(secret)!
            XCTAssertEqual(V2Crockford.decodeCarrySecret(encoded), secret)
        }
    }

    func testDecodingIsCaseInsensitiveAndTolerantOfMissingOrExtraSeparators() {
        let secret = [UInt8](repeating: 0x5a, count: 32)
        let encoded = V2Crockford.encodeCarrySecret(secret)!
        XCTAssertEqual(V2Crockford.decodeCarrySecret(encoded.lowercased()), secret)
        XCTAssertEqual(V2Crockford.decodeCarrySecret(encoded.replacingOccurrences(of: "-", with: "")), secret)
        XCTAssertEqual(V2Crockford.decodeCarrySecret(encoded.replacingOccurrences(of: "-", with: " ")), secret)
    }

    func testCrockfordsOwnForgivingSubstitutionsOToZeroIOrLToOne() {
        let secret = [UInt8](repeating: 0, count: 32) // all-zero bytes encode to an all-'0' string
        let encoded = V2Crockford.encodeCarrySecret(secret)!
        let withO = encoded.replacingOccurrences(of: "0", with: "O")
        XCTAssertEqual(V2Crockford.decodeCarrySecret(withO), secret)
    }

    func testTheWrongLengthOrACharacterOutsideTheAlphabetIsRefused() {
        let secret = [UInt8](repeating: 1, count: 32)
        let encoded = V2Crockford.encodeCarrySecret(secret)!
        XCTAssertNil(V2Crockford.decodeCarrySecret(String(encoded.dropLast()))) // one symbol short
        XCTAssertNil(V2Crockford.decodeCarrySecret(encoded + "0")) // one symbol over
        XCTAssertNil(V2Crockford.decodeCarrySecret("#" + encoded.dropFirst())) // not a Crockford symbol at all
    }
}
