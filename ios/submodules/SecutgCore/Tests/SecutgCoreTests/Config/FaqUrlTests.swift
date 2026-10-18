import XCTest
@testable import SecutgCore

/// PLAN.md 3.53: `FaqUrl.validate` must accept only a well-formed `https://` URL, and `distribution.faq` must come
/// from the bundled secutg.json only (same built-in-only rule as every other `distribution` field).
final class FaqUrlTests: XCTestCase {
    func testMissingOrEmptyIsRejected() {
        XCTAssertNil(FaqUrl.validate(nil))
        XCTAssertNil(FaqUrl.validate(""))
        XCTAssertNil(FaqUrl.validate("   "))
    }

    func testNonHttpsIsRejected() {
        XCTAssertNil(FaqUrl.validate("http://telegram.org/faq"))
        XCTAssertNil(FaqUrl.validate("ftp://telegram.org/faq"))
        XCTAssertNil(FaqUrl.validate("not a url"))
        XCTAssertNil(FaqUrl.validate("https://"))
    }

    func testValidHttpsIsAccepted() {
        let url = "https://telegram.org/faq"
        XCTAssertEqual(FaqUrl.validate(url), url)
        XCTAssertEqual(FaqUrl.validate("  \(url)  "), url)
    }

    /// Same built-in-only rule as every other `distribution` field: a user file cannot swap the link.
    func testFaqComesFromTheBuiltInFileOnly() throws {
        let bundled = #"{"api_id": 1, "api_hash": "0123456789abcdef0123456789abcdef", "app_name": "x", "crypto": {"epoch_days": 1, "epoch_tolerance": 1, "rekey_reminder_days": 7, "max_plaintext_chars": 3000}, "distribution": {"faq": "https://telegram.org/faq"}}"#.data(using: .utf8)!
        let user = #"{"api_id": 222, "distribution": {"faq": "https://evil.example/faq"}}"#.data(using: .utf8)!
        let c = try SecutgConfigLoader.resolve(userFileJSON: user, builtInJSON: bundled)
        XCTAssertEqual(c.distribution?.faq, "https://telegram.org/faq")
        XCTAssertNil(c.distribution?.relaySource)
    }
}
