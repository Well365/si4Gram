import XCTest
@testable import SecutgCore

/// Ported from Android's `SJTest.java` / the Web reference's `sj.test.ts`. Cases about "a JSON number
/// or boolean is refused" and "the null sentinel is not language-null" do not need porting here: this
/// Swift port's `V2SJValue` enum makes constructing a number or boolean a compile error, and `.null`
/// is its own case, structurally distinct from `Optional.none` — the invariant those Java/TS tests
/// check at runtime, this port's type system enforces at compile time instead.
final class V2SJTests: XCTestCase {

    func testKeysSortByByteOrderNotInsertionOrder() {
        let value: V2SJValue = .object(["b": "2", "a": "1", "c": "3"])
        XCTAssertEqual(V2SJ.serialize(value), "{\"a\":\"1\",\"b\":\"2\",\"c\":\"3\"}")
    }

    func testNullAndNestedStructures() {
        let value: V2SJValue = .object([
            "x": .null,
            "y": .array([.string("a"), .null, .object(["z": "1"])]),
        ])
        XCTAssertEqual(V2SJ.serialize(value), "{\"x\":null,\"y\":[\"a\",null,{\"z\":\"1\"}]}")
    }

    func testStringsEscapeOnlyQuoteBackslashAndControlBytesBelow0x20() {
        let value = V2SJValue.string("a\"b\\c\u{0001}d")
        XCTAssertEqual(V2SJ.serialize(value), "\"a\\\"b\\\\c\\u0001d\"")
    }

    func testAnObjectKeyOutsideAllowedCharsIsRefused() {
        let value: V2SJValue = .object(["bad-key": "1"])
        XCTAssertNil(V2SJ.serialize(value))
    }

    func testOutputHasNoWhitespaceAnywhere() {
        let value: V2SJValue = .object(["a": .array(["1", "2"])])
        let serialized = V2SJ.serialize(value)!
        XCTAssertFalse(serialized.contains(" "))
        XCTAssertFalse(serialized.contains("\n"))
        XCTAssertFalse(serialized.contains("\t"))
    }

    func testRoundTripsEverythingSerializeCanProduce() {
        let value: V2SJValue = .object([
            "a": "1",
            "b": .null,
            "c": .array(["x", "y"]),
            "d": .object(["nested": "value"]),
        ])
        let serialized = V2SJ.serialize(value)!
        XCTAssertEqual(V2SJ.parse(serialized), value)
    }

    func testAUEscapeDecodesBackToTheLiteralControlCharacter() {
        let parsed = V2SJ.parse("\"\\u0001\"")
        XCTAssertEqual(parsed, .string("\u{0001}"))
    }

    func testADuplicateKeyIsRefusedEvenThoughItIsUnambiguousWhichOneWouldWin() {
        XCTAssertNil(V2SJ.parse("{\"a\":\"1\",\"a\":\"2\"}"))
    }

    func testAnOutOfOrderKeyIsRefused() {
        XCTAssertNil(V2SJ.parse("{\"b\":\"1\",\"a\":\"2\"}"))
    }

    func testALiteralControlByteInsideAStringIsRefusedOnlyTheEscapedFormIsAccepted() {
        XCTAssertNil(V2SJ.parse("\"a\u{0001}b\""))
        XCTAssertEqual(V2SJ.parse("\"a\\u0001b\""), .string("a\u{0001}b"))
    }

    func testTrailingBytesAfterACompleteValueAreRefusedNotSilentlyIgnored() {
        XCTAssertNil(V2SJ.parse("\"a\"trailing"))
    }

    func testMalformedInputIsRefusedRatherThanThrowing() {
        XCTAssertNil(V2SJ.parse(""))
        XCTAssertNil(V2SJ.parse("{"))
        XCTAssertNil(V2SJ.parse("[1,2]"))
        XCTAssertNil(V2SJ.parse("not json at all"))
    }
}
