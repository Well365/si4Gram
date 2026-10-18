import XCTest
@testable import SecutgCore

final class RelayClientTests: XCTestCase {
    private struct Stub {
        var status: Int
        var body: Data
    }

    private func makeClient(_ handler: @escaping (URLRequest) -> Stub) -> RelayClient {
        return makeClient { request, _ in handler(request) }
    }

    /// Variant that also hands the test the `maxBytes` cap `RelayClient` computed for this request, so a test
    /// can assert on it without needing a real streaming transport.
    private func makeClient(_ handler: @escaping (URLRequest, Int) -> Stub) -> RelayClient {
        let transport: RelayTransport = { request, maxBytes, completion in
            let stub = handler(request, maxBytes)
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)
            completion(stub.body, response, nil)
        }
        return RelayClient(transport: transport)
    }

    func testInfoParsesSuccessBody() {
        let json = """
        {"service":"secutg-relay","version":1,"max_text_bytes":1000,"max_image_bytes":2000,"max_ttl_seconds":3000,"max_reads":100,"upload_token_required":false}
        """
        var capturedRequest: URLRequest?
        let client = makeClient { request in
            capturedRequest = request
            return Stub(status: 200, body: Data(json.utf8))
        }
        let expectation = expectation(description: "info")
        client.info(baseURL: "https://relay.example.com") { result in
            switch result {
            case .success(let info):
                XCTAssertEqual(info.service, "secutg-relay")
                XCTAssertEqual(info.maxTextBytes, 1000)
                XCTAssertEqual(info.uploadTokenRequired, false)
            case .failure(let error): XCTFail("\(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(capturedRequest?.url?.absoluteString, "https://relay.example.com/v1/info")
        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
    }

    func testUploadSendsHeadersAndBody() {
        var capturedRequest: URLRequest?
        let client = makeClient { request in
            capturedRequest = request
            return Stub(status: 201, body: Data("""
            {"id":"abc","expires_at":123,"max_reads":1,"delete_token":"tok"}
            """.utf8))
        }
        let expectation = expectation(description: "upload")
        client.upload(baseURL: "https://relay.example.com", token: "mytoken", contentType: .text, mime: "text/plain;charset=utf-8", maxReads: 1, ttlSeconds: 60, body: Data("hello".utf8)) { result in
            switch result {
            case .success(let upload):
                XCTAssertEqual(upload.id, "abc")
                XCTAssertEqual(upload.deleteToken, "tok")
            case .failure(let error): XCTFail("\(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-Relay-Type"), "text")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-Relay-Mime"), "text/plain;charset=utf-8")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-Relay-Max-Reads"), "1")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-Relay-TTL"), "60")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer mytoken")
        XCTAssertEqual(capturedRequest?.httpBody, Data("hello".utf8))
    }

    func testGetMapsGoneTo404Http() {
        let client = makeClient { _ in Stub(status: 404, body: Data("""
        {"error":{"code":"gone","message":"gone"}}
        """.utf8)) }
        let expectation = expectation(description: "get")
        client.get(baseURL: "https://relay.example.com", id: "abc", expectedPlaintextBytes: 5, isEncrypted: false) { result in
            switch result {
            case .success: XCTFail("expected failure")
            case .failure(let error):
                XCTAssertEqual(error, .http(status: 404, code: "gone", message: "gone"))
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testGetAcceptsExactLengthUnencrypted() {
        let client = makeClient { _ in Stub(status: 200, body: Data("hello".utf8)) }
        let expectation = expectation(description: "get exact")
        client.get(baseURL: "https://relay.example.com", id: "abc", expectedPlaintextBytes: 5, isEncrypted: false) { result in
            switch result {
            case .success(let data): XCTAssertEqual(data, Data("hello".utf8))
            case .failure(let error): XCTFail("\(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testGetRejectsShortBodyAsDecode() {
        // Truncated relative to the `L1:` reference's own `n` — must not be silently accepted for unencrypted
        // content (PLAN.md review HIGH-2 "reject a final content length != n").
        let client = makeClient { _ in Stub(status: 200, body: Data("hell".utf8)) }
        let expectation = expectation(description: "get short")
        client.get(baseURL: "https://relay.example.com", id: "abc", expectedPlaintextBytes: 5, isEncrypted: false) { result in
            switch result {
            case .success: XCTFail("expected failure")
            case .failure(let error): XCTAssertEqual(error, .decode)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testGetRejectsLongBodyAsDecode() {
        let client = makeClient { _ in Stub(status: 200, body: Data("hello!".utf8)) }
        let expectation = expectation(description: "get long")
        client.get(baseURL: "https://relay.example.com", id: "abc", expectedPlaintextBytes: 5, isEncrypted: false) { result in
            switch result {
            case .success: XCTFail("expected failure")
            case .failure(let error): XCTAssertEqual(error, .decode)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testGetRequiresEnvelopeOverheadWhenEncrypted() {
        let plaintext = 5
        let ciphertextLength = plaintext + RelayCap.envelopeOverheadBytes
        let client = makeClient { _ in Stub(status: 200, body: Data(repeating: 0, count: ciphertextLength)) }
        let expectation = expectation(description: "get encrypted exact")
        client.get(baseURL: "https://relay.example.com", id: "abc", expectedPlaintextBytes: plaintext, isEncrypted: true) { result in
            switch result {
            case .success(let data): XCTAssertEqual(data.count, ciphertextLength)
            case .failure(let error): XCTFail("\(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testGetPassesItemCapAsMaxBytes() {
        var capturedMaxBytes: Int?
        let client = makeClient { _, maxBytes in
            capturedMaxBytes = maxBytes
            return Stub(status: 200, body: Data("hello".utf8))
        }
        let expectation = expectation(description: "get cap")
        client.get(baseURL: "https://relay.example.com", id: "abc", expectedPlaintextBytes: 5, isEncrypted: false) { _ in
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(capturedMaxBytes, 5)
    }

    func testMetaAndInfoPassMetadataCapAsMaxBytes() {
        var metaCap: Int?
        let metaClient = makeClient { _, maxBytes in
            metaCap = maxBytes
            return Stub(status: 200, body: Data("""
            {"type":"text","mime":"text/plain;charset=utf-8","size":5,"reads_left":null,"expires_at":123}
            """.utf8))
        }
        let metaExpectation = expectation(description: "meta cap")
        metaClient.meta(baseURL: "https://relay.example.com", id: "abc") { _ in metaExpectation.fulfill() }
        wait(for: [metaExpectation], timeout: 1)
        XCTAssertEqual(metaCap, RelayCap.metadataCapBytes)

        var infoCap: Int?
        let infoClient = makeClient { _, maxBytes in
            infoCap = maxBytes
            return Stub(status: 200, body: Data("""
            {"service":"secutg-relay","version":1,"max_text_bytes":1,"max_image_bytes":1,"max_ttl_seconds":1,"max_reads":1,"upload_token_required":false}
            """.utf8))
        }
        let infoExpectation = expectation(description: "info cap")
        infoClient.info(baseURL: "https://relay.example.com") { _ in infoExpectation.fulfill() }
        wait(for: [infoExpectation], timeout: 1)
        XCTAssertEqual(infoCap, RelayCap.metadataCapBytes)
    }

    func testDeleteSendsDeleteTokenHeader() {
        var capturedRequest: URLRequest?
        let client = makeClient { request in
            capturedRequest = request
            return Stub(status: 204, body: Data())
        }
        let expectation = expectation(description: "delete")
        client.delete(baseURL: "https://relay.example.com", id: "abc", deleteToken: "dtok") { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(capturedRequest?.httpMethod, "DELETE")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-Delete-Token"), "dtok")
    }

    /// Matches the Web oracle's `deleteRelayItem`: a 404 on delete means the content is already gone, which is
    /// the state the caller wanted — not a failure to retry.
    func testDelete404IsTreatedAsSuccess() {
        let client = makeClient { _ in Stub(status: 404, body: Data("""
        {"error":{"code":"gone","message":"gone"}}
        """.utf8)) }
        let expectation = expectation(description: "delete 404")
        client.delete(baseURL: "https://relay.example.com", id: "abc", deleteToken: "dtok") { result in
            if case .failure(let error) = result { XCTFail("expected 404 to be treated as success, got \(error)") }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testMetaParsesUnlimitedReadsAsNil() {
        let client = makeClient { _ in Stub(status: 200, body: Data("""
        {"type":"text","mime":"text/plain;charset=utf-8","size":5,"reads_left":null,"expires_at":123}
        """.utf8)) }
        let expectation = expectation(description: "meta")
        client.meta(baseURL: "https://relay.example.com", id: "abc") { result in
            switch result {
            case .success(let meta): XCTAssertNil(meta.readsLeft)
            case .failure(let error): XCTFail("\(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}
