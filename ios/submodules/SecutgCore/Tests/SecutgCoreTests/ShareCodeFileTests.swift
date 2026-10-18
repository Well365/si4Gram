import XCTest
@testable import SecutgCore

/// PLAN.md 3.39.14: the V2Q / K1Q code as a file — name, sanitising, and what the reader hands to the import.
final class ShareCodeFileTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-02 09:05 UTC
    let date = Date(timeIntervalSince1970: 1_790_931_900)

    func testKindByPrefix() {
        XCTAssertEqual(ShareCodeFile.kind(of: "V2Q:ABC:def:ghi"), .v2q)
        XCTAssertEqual(ShareCodeFile.kind(of: "  K1Q:ABC:K1:1:x:y\n"), .k1q)
        XCTAssertNil(ShareCodeFile.kind(of: "K1:1:abc:def"))
        XCTAssertNil(ShareCodeFile.kind(of: "tg://login?token=x"))
        XCTAssertNil(ShareCodeFile.kind(of: ""))
    }

    func testFileNameShape() {
        XCTAssertEqual(ShareCodeFile.fileName(kind: .v2q, chatName: "Alice", fallback: "123", date: date, timeZone: utc),
                       "secuTG-分享码-Alice-20261002-0905.secutg-v2q")
        XCTAssertEqual(ShareCodeFile.fileName(kind: .k1q, chatName: "工作群", fallback: "-100", date: date, timeZone: utc),
                       "secuTG-分享码-工作群-20261002-0905.secutg-k1q")
    }

    func testSanitizeDropsForbiddenAndControlCollapsesWhitespace() {
        XCTAssertEqual(ShareCodeFile.sanitizeChatName("  a/b\\c:d*e?f\"g<h>i|j  ", fallback: "x"), "abcdefghij")
        XCTAssertEqual(ShareCodeFile.sanitizeChatName("Bob \t\n  Smith\u{0007}", fallback: "x"), "Bob Smith")
        XCTAssertEqual(ShareCodeFile.sanitizeChatName("/:*?", fallback: "777"), "777")
        XCTAssertEqual(ShareCodeFile.sanitizeChatName("   ", fallback: "777"), "777")
    }

    func testSanitizeCapsAt40Characters() {
        let long = String(repeating: "名", count: 60)
        XCTAssertEqual(ShareCodeFile.sanitizeChatName(long, fallback: "x").count, 40)
        // a cap landing right after a space leaves no trailing space
        let spaced = String(repeating: "a", count: 39) + " bcd"
        XCTAssertEqual(ShareCodeFile.sanitizeChatName(spaced, fallback: "x"), String(repeating: "a", count: 39))
    }

    func testContentsIsTheTrimmedTextWithoutNewline() {
        let data = ShareCodeFile.contents(" V2Q:A:b:c\n")
        XCTAssertEqual(String(data: data, encoding: .utf8), "V2Q:A:b:c")
    }

    func testReadTextRoundTripsAndStripsBom() {
        XCTAssertEqual(ShareCodeFile.readText(ShareCodeFile.contents("K1Q:X:K1:1:a:b")), "K1Q:X:K1:1:a:b")
        XCTAssertEqual(ShareCodeFile.readText(Data("\u{FEFF}V2Q:A:b:c\r\n".utf8)), "V2Q:A:b:c")
    }

    func testReadTextRefusesTooBigOrNotUtf8() {
        XCTAssertNil(ShareCodeFile.readText(Data(repeating: 0x41, count: ShareCodeFile.maxFileBytes + 1)))
        XCTAssertNotNil(ShareCodeFile.readText(Data(repeating: 0x41, count: ShareCodeFile.maxFileBytes)))
        XCTAssertNil(ShareCodeFile.readText(Data([0xFF, 0xFE, 0xFD])))
    }
}
