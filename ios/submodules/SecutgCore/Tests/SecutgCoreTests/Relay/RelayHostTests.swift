import XCTest
@testable import SecutgCore

final class RelayHostTests: XCTestCase {
    func testClassifyAcceptsCanonicalHttps() {
        let host = RelayHost.classify("https://relay.example.com")
        XCTAssertEqual(host?.isSecure, true)
        XCTAssertEqual(host?.isLAN, false)
        XCTAssertEqual(host?.host, "relay.example.com")
    }

    func testClassifyAcceptsPort() {
        let host = RelayHost.classify("https://relay.example.com:8443")
        XCTAssertEqual(host?.port, 8443)
        XCTAssertEqual(host?.urlString, "https://relay.example.com:8443")
    }

    func testClassifyRejectsTrailingSlash() {
        XCTAssertNil(RelayHost.classify("https://relay.example.com/"))
    }

    func testClassifyRejectsPath() {
        XCTAssertNil(RelayHost.classify("https://relay.example.com/path"))
    }

    func testClassifyRejectsQueryFragmentUserinfo() {
        XCTAssertNil(RelayHost.classify("https://relay.example.com?x=1"))
        XCTAssertNil(RelayHost.classify("https://relay.example.com#frag"))
        XCTAssertNil(RelayHost.classify("https://user@relay.example.com"))
        XCTAssertNil(RelayHost.classify("https://user:pass@relay.example.com"))
    }

    func testClassifyRejectsUnsupportedScheme() {
        XCTAssertNil(RelayHost.classify("ftp://relay.example.com"))
        XCTAssertNil(RelayHost.classify("relay.example.com"))
    }

    func testClassifyHttpIsInsecure() {
        let host = RelayHost.classify("http://relay.example.com")
        XCTAssertEqual(host?.isSecure, false)
    }

    /// Matches the Web oracle (`host.ts`'s `isValidRelayAddress`) exactly: only the scheme's case is checked
    /// (its grammar is the literal `https?`), never the host's.
    func testClassifyIsCaseSensitiveOnSchemeOnlyNotHost() {
        XCTAssertNil(RelayHost.classify("HTTPS://relay.example.com"))
        XCTAssertNil(RelayHost.classify("Https://relay.example.com"))
        let host = RelayHost.classify("https://Relay.Example.COM")
        XCTAssertEqual(host?.host, "Relay.Example.COM")
        XCTAssertEqual(host?.urlString, "https://Relay.Example.COM")
    }

    func testClassifyRejectsPort0() {
        XCTAssertNil(RelayHost.classify("https://relay.example.com:0"))
    }

    func testLANDetection() {
        XCTAssertEqual(RelayHost.classify("http://localhost:8787")?.isLAN, true)
        XCTAssertEqual(RelayHost.classify("http://myhost.local")?.isLAN, true)
        XCTAssertEqual(RelayHost.classify("http://10.0.0.5")?.isLAN, true)
        XCTAssertEqual(RelayHost.classify("http://192.168.1.1")?.isLAN, true)
        XCTAssertEqual(RelayHost.classify("http://172.16.0.1")?.isLAN, true)
        XCTAssertEqual(RelayHost.classify("http://172.32.0.1")?.isLAN, false)
        XCTAssertEqual(RelayHost.classify("https://relay.example.com")?.isLAN, false)
        XCTAssertEqual(RelayHost.classify("http://169.254.1.1")?.isLAN, true)
        XCTAssertEqual(RelayHost.classify("http://[::1]")?.isLAN, true)
        XCTAssertEqual(RelayHost.classify("http://[::]")?.isLAN, true)
        XCTAssertEqual(RelayHost.classify("http://0.0.0.0")?.isLAN, true)
        XCTAssertEqual(RelayHost.classify("http://[fd12:3456::1]")?.isLAN, true)
    }

    func testNormalizeTrimsAndLowercases() {
        XCTAssertEqual(RelayHost.normalize("  HTTPS://Relay.Example.com/  "), "https://relay.example.com")
        XCTAssertEqual(RelayHost.normalize("https://relay.example.com"), "https://relay.example.com")
        XCTAssertNil(RelayHost.normalize("https://relay.example.com/path"))
        XCTAssertNil(RelayHost.normalize("not a url"))
    }
}
