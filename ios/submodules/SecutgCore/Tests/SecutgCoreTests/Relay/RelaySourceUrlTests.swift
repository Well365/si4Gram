import XCTest
@testable import SecutgCore

/// PLAN.md 3.48.8: `RelaySourceUrl.validate` must accept only a well-formed `https://` URL.
final class RelaySourceUrlTests: XCTestCase {
    func testNilIsRejected() {
        XCTAssertNil(RelaySourceUrl.validate(nil))
    }

    func testEmptyIsRejected() {
        XCTAssertNil(RelaySourceUrl.validate(""))
        XCTAssertNil(RelaySourceUrl.validate("   "))
    }

    func testHttpIsRejected() {
        XCTAssertNil(RelaySourceUrl.validate("http://github.com/example/secuTG-relay"))
    }

    func testJunkIsRejected() {
        XCTAssertNil(RelaySourceUrl.validate("not a url"))
        XCTAssertNil(RelaySourceUrl.validate("ftp://github.com/example/secuTG-relay"))
        XCTAssertNil(RelaySourceUrl.validate("https://"))
    }

    func testValidHttpsIsAccepted() {
        let url = "https://github.com/example/secuTG-relay"
        XCTAssertEqual(RelaySourceUrl.validate(url), url)
    }
}
