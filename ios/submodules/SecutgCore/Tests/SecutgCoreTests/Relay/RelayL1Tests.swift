import XCTest
@testable import SecutgCore

final class RelayL1Tests: XCTestCase {
    private func sampleRef(k: String? = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") -> RelayL1Reference {
        return RelayL1Reference(
            relayURL: "https://relay.example.com",
            id: "AAAAAAAAAAAAAAAAAAAAAA",
            contentType: .text,
            mime: "text/plain;charset=utf-8",
            sizeBytes: 12,
            maxReads: 1,
            expiresAt: 1_789_128_000,
            contentKey: k)
    }

    func testIsReferenceIsPrefixOnly() {
        XCTAssertTrue(RelayL1.isReference("L1:anything"))
        XCTAssertFalse(RelayL1.isReference("L0:anything"))
        XCTAssertFalse(RelayL1.isReference("hello L1: not at start"))
        XCTAssertFalse(RelayL1.isReference(""))
    }

    func testEncodeFixedKeyOrderNoWhitespace() {
        let wire = RelayL1.encode(sampleRef())
        XCTAssertTrue(wire.hasPrefix("L1:"))
        let decoded = Base64Url.decode(String(wire.dropFirst(3)))!
        let json = String(decoding: decoded, as: UTF8.self)
        XCTAssertFalse(json.contains(" "))
        // Fixed order: v,u,id,t,m,n,r,e,k
        let order = ["\"v\":", "\"u\":", "\"id\":", "\"t\":", "\"m\":", "\"n\":", "\"r\":", "\"e\":", "\"k\":"]
        var lastIndex = json.startIndex
        for key in order {
            guard let range = json.range(of: key, range: lastIndex..<json.endIndex) else {
                XCTFail("missing \(key) in \(json)")
                return
            }
            lastIndex = range.upperBound
        }
    }

    func testEncodeOmitsKWhenAbsent() {
        let wire = RelayL1.encode(sampleRef(k: nil))
        let decoded = Base64Url.decode(String(wire.dropFirst(3)))!
        let json = String(decoding: decoded, as: UTF8.self)
        XCTAssertFalse(json.contains("\"k\""))
    }

    func testRoundTrip() {
        for k in [nil, RelayL1.newContentKey()] {
            let ref = sampleRef(k: k)
            let wire = RelayL1.encode(ref)
            switch RelayL1.parse(wire) {
            case .success(let parsed): XCTAssertEqual(parsed, ref)
            case .failure(let error): XCTFail("unexpected failure \(error)")
            }
        }
    }

    func testParseAcceptsAnyKeyOrder() {
        let json = "{\"k\":null,\"e\":1789128000,\"r\":1,\"n\":12,\"m\":\"text/plain;charset=utf-8\",\"t\":\"text\",\"id\":\"AAAAAAAAAAAAAAAAAAAAAA\",\"u\":\"https://relay.example.com\",\"v\":1}"
        let wire = "L1:" + Base64Url.encode([UInt8](json.utf8))
        switch RelayL1.parse(wire) {
        case .success(let ref):
            XCTAssertEqual(ref.relayURL, "https://relay.example.com")
            XCTAssertNil(ref.contentKey)
        case .failure(let error): XCTFail("unexpected failure \(error)")
        }
    }

    // MARK: - Reason codes

    func testReasonPrefix() {
        assertFailure("X1:abc", .prefix)
        assertFailure("", .prefix)
    }

    func testReasonBase64() {
        assertFailure("L1:not base64!!", .base64)
    }

    func testReasonJson() {
        let notJson = Base64Url.encode([UInt8]("not json".utf8))
        assertFailure("L1:" + notJson, .json)
    }

    func testReasonVersion() {
        let json = "{\"v\":2,\"u\":\"https://relay.example.com\",\"id\":\"AAAAAAAAAAAAAAAAAAAAAA\",\"t\":\"text\",\"m\":\"text/plain;charset=utf-8\",\"n\":1,\"r\":1,\"e\":1}"
        assertFailure("L1:" + Base64Url.encode([UInt8](json.utf8)), .version)

        let missingV = "{\"u\":\"https://relay.example.com\",\"id\":\"AAAAAAAAAAAAAAAAAAAAAA\",\"t\":\"text\",\"m\":\"text/plain;charset=utf-8\",\"n\":1,\"r\":1,\"e\":1}"
        assertFailure("L1:" + Base64Url.encode([UInt8](missingV.utf8)), .version)
    }

    func testReasonFieldForEachField() {
        let base: [String: Any] = [
            "v": 1, "u": "https://relay.example.com", "id": "AAAAAAAAAAAAAAAAAAAAAA",
            "t": "text", "m": "text/plain;charset=utf-8", "n": 1, "r": 1, "e": 1,
        ]
        func wire(overriding key: String, with value: Any?) -> String {
            var object = base
            if let value = value { object[key] = value } else { object.removeValue(forKey: key) }
            let data = try! JSONSerialization.data(withJSONObject: object)
            return "L1:" + Base64Url.encode([UInt8](data))
        }
        assertFailure(wire(overriding: "u", with: "ftp://bad"), .field("u"))
        assertFailure(wire(overriding: "u", with: "https://relay.example.com/path"), .field("u"))
        assertFailure(wire(overriding: "id", with: "tooshort"), .field("id"))
        assertFailure(wire(overriding: "t", with: "video"), .field("t"))
        assertFailure(wire(overriding: "m", with: "application/json"), .field("m"))
        assertFailure(wire(overriding: "n", with: 20 * 1024 * 1024 + 1), .field("n"))
        assertFailure(wire(overriding: "n", with: -1), .field("n"))
        assertFailure(wire(overriding: "r", with: 1001), .field("r"))
        assertFailure(wire(overriding: "e", with: nil), .field("e"))
    }

    /// `m` is validated against the fixed MIME list only, independent of `t` — matching the Web oracle's
    /// `parseL1` exactly (it never cross-checks the two). `e == 0` is likewise accepted, matching the oracle's
    /// `isNonNegativeInt`: an already-expired reference is not a malformed one.
    func testFieldsNotCrossValidated() {
        let base: [String: Any] = [
            "v": 1, "u": "https://relay.example.com", "id": "AAAAAAAAAAAAAAAAAAAAAA",
            "t": "text", "m": "text/plain;charset=utf-8", "n": 1, "r": 1, "e": 1,
        ]
        func wire(overriding key: String, with value: Any) -> String {
            var object = base
            object[key] = value
            let data = try! JSONSerialization.data(withJSONObject: object)
            return "L1:" + Base64Url.encode([UInt8](data))
        }
        switch RelayL1.parse(wire(overriding: "m", with: "image/png")) {
        case .success(let ref): XCTAssertEqual(ref.mime, "image/png")
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
        switch RelayL1.parse(wire(overriding: "e", with: 0)) {
        case .success(let ref): XCTAssertEqual(ref.expiresAt, 0)
        case .failure(let error): XCTFail("expected success, got \(error)")
        }
    }

    func testReasonFieldK() {
        let json = "{\"v\":1,\"u\":\"https://relay.example.com\",\"id\":\"AAAAAAAAAAAAAAAAAAAAAA\",\"t\":\"text\",\"m\":\"text/plain;charset=utf-8\",\"n\":1,\"r\":1,\"e\":1,\"k\":\"tooshort\"}"
        assertFailure("L1:" + Base64Url.encode([UInt8](json.utf8)), .field("k"))
    }

    func testReasonCodeStrings() {
        XCTAssertEqual(RelayL1ParseError.prefix.reasonCode, "prefix")
        XCTAssertEqual(RelayL1ParseError.base64.reasonCode, "base64")
        XCTAssertEqual(RelayL1ParseError.json.reasonCode, "json")
        XCTAssertEqual(RelayL1ParseError.version.reasonCode, "version")
        XCTAssertEqual(RelayL1ParseError.field("u").reasonCode, "field:u")
    }

    private func assertFailure(_ wire: String, _ expected: RelayL1ParseError, file: StaticString = #filePath, line: UInt = #line) {
        switch RelayL1.parse(wire) {
        case .success: XCTFail("expected failure \(expected)", file: file, line: line)
        case .failure(let error): XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}
