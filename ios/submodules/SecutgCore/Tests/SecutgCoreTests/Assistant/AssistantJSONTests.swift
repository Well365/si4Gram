import XCTest
@testable import SecutgCore

/// PLAN.md 3.45.2 framing: one compact, deterministic JSON object per line; bad input is an error, never a crash.
final class AssistantJSONTests: XCTestCase {
    func testEncodingIsCompactSortedAndHasNoRawNewline() {
        let value = AssistantJSON.object(["b": .int(2), "a": .string("x\ny\"z\\"), "c": .array([.bool(true), .null])])
        let line = value.encoded()
        XCTAssertEqual(line, #"{"a":"x\ny\"z\\","b":2,"c":[true,null]}"#)
        XCTAssertFalse(line.contains("\n"))
    }

    func testControlCharactersAndLineSeparatorsAreEscaped() {
        let line = AssistantJSON.string("\u{01}\u{2028}\t").encoded()
        XCTAssertEqual(line, "\"" + "\\u0001" + "\\u2028" + "\\t" + "\"")
    }

    func testNonASCIIIsKeptAsUTF8() {
        XCTAssertEqual(AssistantJSON.string("提及 🔒").encoded(), "\"提及 🔒\"")
    }

    func testRoundTrip() throws {
        let value = AssistantJSON.object([
            "id": .string("a-1"), "n": .int(-9_000_000_000_123), "f": .double(1.5), "t": .bool(false),
            "list": .array([.object(["k": .string("中文\u{0}")])]), "none": .null,
        ])
        XCTAssertEqual(try AssistantJSON.parse(value.encoded()), value)
    }

    func testParsesEscapesAndSurrogatePairs() throws {
        XCTAssertEqual(try AssistantJSON.parse(#""🔒\/中""#), .string("🔒/中"))
        XCTAssertEqual(try AssistantJSON.parse(#""\ud83d""#), .string("\u{FFFD}"))
    }

    func testNumbers() throws {
        XCTAssertEqual(try AssistantJSON.parse("42"), .int(42))
        XCTAssertEqual(try AssistantJSON.parse("-0"), .int(0))
        XCTAssertEqual(try AssistantJSON.parse("5.0").int64Value, 5)
        XCTAssertNil(try AssistantJSON.parse("5.5").int64Value)
        XCTAssertEqual(try AssistantJSON.parse("1e3").int64Value, 1000)
        XCTAssertEqual(try AssistantJSON.parse("99999999999999999999"), .double(1e20))
    }

    func testBooleansAreNotNumbers() throws {
        XCTAssertEqual(try AssistantJSON.parse("true"), .bool(true))
        XCTAssertNil(try AssistantJSON.parse("true").int64Value)
    }

    func testMalformedInputThrows() {
        for bad in ["", "{", "{\"a\":}", "[1,]", "tru", "\"unterminated", "{\"a\":1} x", "01x", "-", "1.", "\"\u{01}\""] {
            XCTAssertThrowsError(try AssistantJSON.parse(bad), bad)
        }
    }

    func testInvalidUTF8Throws() {
        XCTAssertThrowsError(try AssistantJSON.parse(Data([0x22, 0xFF, 0x22])))
    }

    func testNestingIsBounded() {
        let deep = String(repeating: "[", count: AssistantJSON.maxDepth + 1) + String(repeating: "]", count: AssistantJSON.maxDepth + 1)
        XCTAssertThrowsError(try AssistantJSON.parse(deep)) { error in
            XCTAssertEqual(error as? AssistantJSON.ParseError, .tooDeep)
        }
        let ok = String(repeating: "[", count: AssistantJSON.maxDepth) + String(repeating: "]", count: AssistantJSON.maxDepth)
        XCTAssertNoThrow(try AssistantJSON.parse(ok))
    }
}
