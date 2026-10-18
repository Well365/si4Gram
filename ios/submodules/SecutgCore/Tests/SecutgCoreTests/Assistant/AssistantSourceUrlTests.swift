import XCTest
@testable import SecutgCore

/// PLAN.md 3.52: `AssistantSourceUrl.validate` must accept only a well-formed `https://` URL.
final class AssistantSourceUrlTests: XCTestCase {
    func testMissingOrEmptyIsRejected() {
        XCTAssertNil(AssistantSourceUrl.validate(nil))
        XCTAssertNil(AssistantSourceUrl.validate(""))
        XCTAssertNil(AssistantSourceUrl.validate("   "))
    }

    func testNonHttpsIsRejected() {
        XCTAssertNil(AssistantSourceUrl.validate("http://github.com/example/secuTG-smart-mate"))
        XCTAssertNil(AssistantSourceUrl.validate("ftp://github.com/example/secuTG-smart-mate"))
        XCTAssertNil(AssistantSourceUrl.validate("not a url"))
        XCTAssertNil(AssistantSourceUrl.validate("https://"))
    }

    func testValidHttpsIsAccepted() {
        let url = "https://github.com/example/secuTG-smart-mate"
        XCTAssertEqual(AssistantSourceUrl.validate(url), url)
        XCTAssertEqual(AssistantSourceUrl.validate("  \(url)  "), url)
    }

    /// Same built-in-only rule as every other `distribution` field: a user file cannot swap the link.
    func testAssistantSourceComesFromTheBuiltInFileOnly() throws {
        let bundled = #"{"api_id": 1, "api_hash": "0123456789abcdef0123456789abcdef", "app_name": "x", "crypto": {"epoch_days": 1, "epoch_tolerance": 1, "rekey_reminder_days": 7, "max_plaintext_chars": 3000}, "distribution": {"assistant_source": "https://github.com/example/secuTG-smart-mate"}}"#.data(using: .utf8)!
        let user = #"{"api_id": 222, "distribution": {"assistant_source": "https://evil.example/mate"}}"#.data(using: .utf8)!
        let c = try SecutgConfigLoader.resolve(userFileJSON: user, builtInJSON: bundled)
        XCTAssertEqual(c.distribution?.assistantSource, "https://github.com/example/secuTG-smart-mate")
        XCTAssertNil(c.distribution?.relaySource)
    }
}
