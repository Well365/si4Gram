import Clibsodium
import Foundation
import XCTest
@testable import SecutgCore

/// PLAN.md 3.14.1 shared vectors, `Vectors/vectors-k1q.json` — a byte-for-byte copy of Web A
/// `src/secutg/transfer/vectors-k1q.json`.
///
/// - `open`: the exact plaintext under the fixed code and nonce reproduces the exact `K1Q` text (KDF, AEAD, base64url
///   and the wrapper all agree), and the text decodes to what `expect` says.
/// - `reject`: the refusal reason is the same one Web gives, and `parse` alone catches exactly the syntax errors.
/// - `fit`: the Web text decodes to the current master plus the newest history; and this client's own serialiser,
///   run through `QuickShare.fit` on the same inputs, satisfies the normative rule (≤ max, newest kept, one more
///   would not fit). The kept count is informative only — it depends on the JSON serialiser.
final class QuickShareVectorTests: XCTestCase {
    private var file: [String: Any] { return Vectors.load("vectors-k1q") }
    private var cases: [[String: Any]] { return file["cases"] as? [[String: Any]] ?? [] }
    private func cases(_ kind: String) -> [[String: Any]] { return cases.filter { $0["kind"] as? String == kind } }

    func testFileShape() {
        XCTAssertEqual(file["format"] as? String, "secutg-k1q-vectors/1")
        XCTAssertEqual(file["max_bytes"] as? Int, QuickShare.maxQrBytes)
        XCTAssertGreaterThanOrEqual(cases("open").count, 2)
        XCTAssertGreaterThanOrEqual(cases("reject").count, 10)
        XCTAssertGreaterThanOrEqual(cases("fit").count, 1)
    }

    func testOpenCases() throws {
        for c in cases("open") {
            let name = c["name"] as? String ?? "?"
            let k1q = try XCTUnwrap(c["k1q"] as? String, name)
            if let code = c["code"] as? String, let nonceHex = c["nonce_hex"] as? String, let plaintext = c["plaintext_json"] as? String {
                let bundle = try seal(Array(plaintext.utf8), code: code, nonce: Vectors.hex(nonceHex))
                XCTAssertEqual(QuickShare.compose(code: code, bundle: bundle), k1q, name)
            }
            let input = c["input"] as? String ?? k1q
            guard case let .success(opened) = QuickShare.open(input) else { XCTFail("\(name) did not open"); continue }
            let payload = opened.payload
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            let chatIds = try XCTUnwrap(expect["chat_ids"] as? [String], name)
            let chatId = chatIds[0]
            XCTAssertEqual(payload.v, TransferBundle.version, name)
            XCTAssertEqual(payload.scope.rawValue, expect["scope"] as? String, name)
            XCTAssertEqual(payload.chatIds, chatIds, name)
            XCTAssertEqual(payload.createdAt, (expect["created_at"] as? NSNumber)?.int64Value, name)
            XCTAssertEqual(payload.device, expect["device"] as? String, name)
            XCTAssertEqual(payload.snapshot.chatMasters[chatId], expect["current_master_id"] as? String, name)
            XCTAssertEqual(payload.snapshot.identityEd25519Sk != nil, expect["has_identity"] as? Bool, name)
            let masters = try XCTUnwrap(expect["masters"] as? [[String: Any]], name)
            XCTAssertEqual(payload.snapshot.masters.count, masters.count, name)
            for m in masters {
                let id = try XCTUnwrap(m["master_id"] as? String, name)
                let key = Vectors.hex(try XCTUnwrap(m["master_hex"] as? String, name))
                XCTAssertEqual(payload.snapshot.masters[id], key, name)
                XCTAssertEqual(payload.snapshot.masterCreatedAt[id], (m["created_at"] as? NSNumber)?.int64Value, name)
                XCTAssertEqual(try KeyDerivation.computeMasterId(key), id, name)
            }
            if let label = expect["key_label"] as? String { XCTAssertEqual(payload.snapshot.chatKeyLabels[chatId], label, name) }
            if let mode = expect["key_mode"] as? String { XCTAssertEqual(payload.snapshot.chatKeyModes[chatId]?.rawValue, mode, name) }
            if let adminPk = expect["admin_pk_hex"] as? String { XCTAssertEqual(payload.snapshot.chatAdminPks[chatId], Vectors.hex(adminPk), name) }
            // and the ordinary 3.14 manifest reads it the way the import dialog will show it
            XCTAssertFalse(TransferBundle.summarize(payload, nowSeconds: payload.createdAt).hasIdentity, name)
        }
    }

    func testRejectCases() throws {
        for c in cases("reject") {
            let name = c["name"] as? String ?? "?"
            let input = try XCTUnwrap(c["input"] as? String, name)
            let expected = try XCTUnwrap(c["expect_error"] as? String, name)
            switch QuickShare.open(input) {
            case .success: XCTFail("\(name) opened")
            case let .failure(error): XCTAssertEqual(error.rawValue, expected, name)
            }
            // syntax errors are caught without decrypting
            XCTAssertEqual(QuickShare.parse(input) == nil, expected == "malformed", name)
        }
    }

    func testFitCases() throws {
        for c in cases("fit") {
            let name = c["name"] as? String ?? "?"
            let code = try XCTUnwrap(c["code"] as? String, name)
            let chatId = try XCTUnwrap(c["chat_id"] as? String, name)
            let current = try master(try XCTUnwrap(c["current"] as? [String: Any], name))
            let history = try (try XCTUnwrap(c["history_newest_first"] as? [[String: Any]], name)).map(master)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            let webKept = try XCTUnwrap(expect["history_kept"] as? Int, name)
            let webText = try XCTUnwrap(expect["k1q"] as? String, name)

            // the Web text: within capacity, decodes to current + the newest `history_kept`
            XCTAssertEqual(QuickShare.byteCount(webText), expect["bytes"] as? Int, name)
            XCTAssertLessThanOrEqual(QuickShare.byteCount(webText), QuickShare.maxQrBytes, name)
            guard case let .success(opened) = QuickShare.open(webText) else { XCTFail("\(name) did not open"); continue }
            XCTAssertEqual(Set(opened.payload.snapshot.masters.keys),
                           Set([current.masterId] + history.prefix(webKept).map { $0.masterId }), name)

            // this client's own serialiser under the same rule
            var base = KeyRing.Snapshot()
            base.masters[current.masterId] = current.key
            base.masterCreatedAt[current.masterId] = current.createdAt
            base.chatMasters[chatId] = current.masterId
            let render: (KeyRing.Snapshot) throws -> String = { snapshot in
                let payload = TransferPayload(scope: .chat, chatIds: [chatId], createdAt: 1_790_000_000, device: "secuTG Vector", snapshot: snapshot)
                return try XCTUnwrap(QuickShare.compose(code: code, bundle: TransferBundle.build(payload, code: code)))
            }
            let outcome = try QuickShare.fit(chatId: chatId, base: base, historyNewestFirst: history, render: render)
            guard case let .partial(text, count, dropped) = outcome else { XCTFail("\(name): expected partial, got \(outcome)"); continue }
            let kept = count - 1
            XCTAssertEqual(kept + dropped, history.count, name)
            XCTAssertLessThanOrEqual(QuickShare.byteCount(text), QuickShare.maxQrBytes, name)
            XCTAssertGreaterThan(QuickShare.byteCount(try render(QuickShare.adding(history.prefix(kept + 1), to: base))), QuickShare.maxQrBytes, name)
            guard case let .success(mine) = QuickShare.open(text) else { XCTFail("\(name): own text did not open"); continue }
            XCTAssertEqual(Set(mine.payload.snapshot.masters.keys), Set([current.masterId] + history.prefix(kept).map { $0.masterId }), name)
            // informative: how close the two serialisers come
            XCTAssertLessThanOrEqual(abs(kept - webKept), 3, "\(name): kept \(kept), Web kept \(webKept)")
        }
    }

    // MARK: helpers

    private func master(_ raw: [String: Any]) throws -> QuickShare.HistoryMaster {
        let key = Vectors.hex(try XCTUnwrap(raw["master_hex"] as? String))
        return QuickShare.HistoryMaster(
            masterId: try KeyDerivation.computeMasterId(key), key: key, createdAt: (raw["created_at"] as? NSNumber)?.int64Value)
    }

    /// `K1:1:<nonce>:<ct>` of an exact plaintext under a fixed nonce — the 3.14 container, by hand.
    private func seal(_ plaintext: [UInt8], code: String, nonce: [UInt8]) throws -> String {
        let key = try TransferCode.deriveKey(try XCTUnwrap(TransferCode.parse(code)))
        let aad = Array("K1:1".utf8)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count + Int(crypto_aead_xchacha20poly1305_ietf_abytes()))
        var length: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_encrypt(
            &ciphertext, &length, plaintext, UInt64(plaintext.count), aad, UInt64(aad.count), nil, nonce, key)
        XCTAssertEqual(rc, 0)
        return "K1:1:\(Base64Url.encode(nonce)):\(Base64Url.encode(Array(ciphertext.prefix(Int(length)))))"
    }
}
