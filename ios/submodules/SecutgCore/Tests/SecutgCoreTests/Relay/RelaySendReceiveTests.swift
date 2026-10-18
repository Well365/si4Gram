import XCTest
@testable import SecutgCore

final class RelaySendReceiveTests: XCTestCase {
    func testPrepareUploadPlaintext() throws {
        let plaintext = Data("hello".utf8)
        let prepared = try RelaySend.prepareUpload(plaintext: plaintext, originalMime: "text/plain;charset=utf-8", encrypt: false)
        XCTAssertEqual(prepared.body, plaintext)
        XCTAssertEqual(prepared.uploadMime, "text/plain;charset=utf-8")
        XCTAssertNil(prepared.contentKey)
    }

    func testPrepareUploadEncrypted() throws {
        let plaintext = Data("hello".utf8)
        let prepared = try RelaySend.prepareUpload(plaintext: plaintext, originalMime: "text/plain;charset=utf-8", encrypt: true)
        XCTAssertNotEqual(prepared.body, plaintext)
        XCTAssertEqual(prepared.uploadMime, "application/octet-stream")
        XCTAssertNotNil(prepared.contentKey)
        XCTAssertEqual(RelayCrypto.open(prepared.body, key: prepared.contentKey!), plaintext)
    }

    func testBuildReferenceUsesServerAssignedFields() {
        let upload = RelayUploadResult(id: "server-id", expiresAt: 42, maxReads: 3, deleteToken: "dtok")
        let ref = RelaySend.buildReference(relayURL: "https://relay.example.com", uploadResult: upload, contentType: .text, originalMime: "text/plain;charset=utf-8", sizeBytes: 5, contentKey: [UInt8](repeating: 1, count: 32))
        XCTAssertEqual(ref.id, "server-id")
        XCTAssertEqual(ref.expiresAt, 42)
        XCTAssertEqual(ref.maxReads, 3)
        XCTAssertEqual(ref.contentKey, Base64Url.encode([UInt8](repeating: 1, count: 32)))
    }

    func testExceedsLimitUsesRelayInfoWhenAvailable() {
        let info = RelayInfo(service: "s", version: 1, maxTextBytes: 100, maxImageBytes: 1000, maxTtlSeconds: 10, maxReads: 10, uploadTokenRequired: false)
        XCTAssertFalse(RelaySend.exceedsLimit(sizeBytes: 100, contentType: .text, info: info))
        XCTAssertTrue(RelaySend.exceedsLimit(sizeBytes: 101, contentType: .text, info: info))
        XCTAssertFalse(RelaySend.exceedsLimit(sizeBytes: 1000, contentType: .image, info: info))
    }

    func testExceedsLimitFallsBackToAbsoluteCeiling() {
        XCTAssertFalse(RelaySend.exceedsLimit(sizeBytes: RelayL1.maxBytes, contentType: .text, info: nil))
        XCTAssertTrue(RelaySend.exceedsLimit(sizeBytes: RelayL1.maxBytes + 1, contentType: .text, info: nil))
    }

    func testReceiveOpenPlaintext() {
        let ref = RelayL1Reference(relayURL: "https://r", id: "AAAAAAAAAAAAAAAAAAAAAA", contentType: .text, mime: "text/plain;charset=utf-8", sizeBytes: 5, maxReads: 1, expiresAt: 1, contentKey: nil)
        XCTAssertEqual(RelayReceive.open(ref: ref, fetchedBody: Data("hello".utf8)), Data("hello".utf8))
    }

    func testReceiveOpenEncrypted() throws {
        let key = RelayCrypto.generateKey()
        let sealed = try RelayCrypto.seal(Data("secret".utf8), key: key)
        let ref = RelayL1Reference(relayURL: "https://r", id: "AAAAAAAAAAAAAAAAAAAAAA", contentType: .text, mime: "text/plain;charset=utf-8", sizeBytes: 6, maxReads: 1, expiresAt: 1, contentKey: Base64Url.encode(key))
        XCTAssertEqual(RelayReceive.open(ref: ref, fetchedBody: sealed), Data("secret".utf8))
    }

    func testReceiveOpenFailsWithBadKey() {
        let ref = RelayL1Reference(relayURL: "https://r", id: "AAAAAAAAAAAAAAAAAAAAAA", contentType: .text, mime: "text/plain;charset=utf-8", sizeBytes: 6, maxReads: 1, expiresAt: 1, contentKey: "tooshort")
        XCTAssertNil(RelayReceive.open(ref: ref, fetchedBody: Data("whatever".utf8)))
    }
}
