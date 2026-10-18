import Foundation
import XCTest
@testable import SecutgCore

/// PLAN.md 3.39.13's shared vectors, `Vectors/vectors-v2clone.json` — a byte-for-byte copy of Web A
/// `src/secutg/v2/vectors-v2clone.json` (format `secutg-v2clone-vectors/1`).
///
/// - `open`: the exact plaintext under the fixed code and nonce reproduces the exact `V2Q` text; this client's own
///   serializer reproduces the plaintext byte-for-byte, and so does its own build of the case from the fixed actors;
///   the text opens to `expect`, and installs on a fresh device exactly as `expect.install` says.
/// - `own`: the reader's derivation of the handed-over keys (seed → Ed25519 pair, X25519 sk → pk, device id).
/// - `reject` / `accept`: the refusal reason Web gives (first failing check wins) under the case's own chat / clock /
///   "already paired" flag; a payload-level case's input is this client's own AEAD of the plaintext it ships.
/// - `fit`: the capacity decision on the same roster and history (and the synthetic limits of the `rule-*` cases),
///   down to the chosen text itself.
///
/// Skipped, not failed, while the file has not been copied over yet (Web is still finalising it).
final class V2CloneVectorTests: XCTestCase {
    private static let fileName = "vectors-v2clone"

    private func loadFile() throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: V2CloneVectorTests.fileName, withExtension: "json", subdirectory: "Vectors") else {
            throw XCTSkip("Vectors/\(V2CloneVectorTests.fileName).json not copied yet (Web is still finalising it)")
        }
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private struct Actor {
        let signing: V2Suite.KeyPair
        let x25519Sk: [UInt8]
        let x25519Pk: [UInt8]
        var deviceId: String { return Base64Url.encode(V2Suite.sha256(signing.publicKey)) }
        var entry: V2JoinPayload.RosterEntry {
            return V2JoinPayload.RosterEntry(identityPk: Base64Url.encode(signing.publicKey), encapsulationPk: Base64Url.encode(x25519Pk))
        }
        var own: V2JoinPayload.Own {
            return V2JoinPayload.Own(identitySeed: Base64Url.encode(Array(signing.secretKey.prefix(32))), encapsulationSk: Base64Url.encode(x25519Sk))
        }
    }

    private struct Fixed {
        let peerUserId: String
        let chatId: String
        let nowMs: Int64
        let expiresMs: Int64
        let code: String
        let nonce: [UInt8]
        let safetyCode: String
        let bindingId: String
        let actors: [String: Actor]
    }

    private func fixed(_ file: [String: Any]) throws -> Fixed {
        let f = try XCTUnwrap(file["fixed"] as? [String: Any])
        var actors: [String: Actor] = [:]
        for (name, raw) in try XCTUnwrap(f["actors"] as? [String: [String: Any]]) {
            let seed = Vectors.hex(try XCTUnwrap(raw["ed25519_seed_hex"] as? String))
            let sk = Vectors.hex(try XCTUnwrap(raw["x25519_sk_hex"] as? String))
            let actor = Actor(signing: try XCTUnwrap(V2Suite.ed25519KeyPair(seed: seed)), x25519Sk: sk, x25519Pk: try XCTUnwrap(V2Suite.x25519PublicKey(secretKey: sk)))
            XCTAssertEqual(Base64Url.encode(actor.signing.publicKey), raw["ed25519_pk"] as? String, name)
            XCTAssertEqual(Base64Url.encode(actor.x25519Pk), raw["x25519_pk"] as? String, name)
            XCTAssertEqual(actor.deviceId, raw["device_id"] as? String, name)
            actors[name] = actor
        }
        return Fixed(
            peerUserId: try XCTUnwrap(f["peer_user_id"] as? String), chatId: try XCTUnwrap(f["chat_id_on_own_devices"] as? String),
            nowMs: try XCTUnwrap((f["now_ms"] as? NSNumber)?.int64Value), expiresMs: try XCTUnwrap((f["expires_ms"] as? NSNumber)?.int64Value),
            code: try XCTUnwrap(f["transfer_code"] as? String), nonce: Vectors.hex(try XCTUnwrap(f["nonce_hex"] as? String)),
            safetyCode: try XCTUnwrap(f["safety_code"] as? String), bindingId: try XCTUnwrap(f["binding_id"] as? String), actors: actors
        )
    }

    private func cases(_ file: [String: Any], _ kind: String) -> [[String: Any]] {
        return (file["cases"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == kind }
    }

    /// "master of epoch e = byte(0x40+e)*32"
    private func master(epoch: Int) -> String {
        return Base64Url.encode([UInt8](repeating: UInt8(0x40 + epoch), count: 32))
    }

    /// The payload a case describes, as the showing device `o` builds it: roster sorted by device id, the current master
    /// and `historyKept` history masters newest first, `o`'s own keys.
    private func payload(_ f: Fixed, rosterNames: [String], epoch: Int, historyKept: Int) throws -> V2JoinPayload.Payload {
        let members = try rosterNames.map { try XCTUnwrap(f.actors[$0], $0) }.sorted { $0.deviceId < $1.deviceId }
        let o = try XCTUnwrap(f.actors["o"])
        let history = Array(stride(from: epoch - 1, through: 1, by: -1).prefix(historyKept)).map { master(epoch: $0) }
        return V2JoinPayload.Payload(peerUserId: f.peerUserId, bindingId: f.bindingId, epoch: epoch, safetyCode: f.safetyCode,
                                     roster: members.map { $0.entry }, masters: [master(epoch: epoch)] + history, own: o.own, expiresMs: f.expiresMs)
    }

    private func context(_ f: Fixed, _ c: [String: Any]) -> V2Join.OpenContext {
        return V2Join.OpenContext(chatId: c["chat_id"] as? String ?? f.chatId, nowMs: (c["now_ms"] as? NSNumber)?.int64Value ?? f.nowMs,
                                  hasCurrentBinding: c["has_current_binding"] as? Bool ?? false)
    }

    func testFileShape() throws {
        let file = try loadFile()
        XCTAssertEqual(file["format"] as? String, "secutg-v2clone-vectors/1")
        let maxBytes = try XCTUnwrap(file["max_bytes"] as? [String: Int])
        XCTAssertEqual(maxBytes["M"], V2JoinCapacity.maxBytes[.m])
        XCTAssertEqual(maxBytes["L"], V2JoinCapacity.maxBytes[.l])
        XCTAssertEqual((file["expiry_grace_ms"] as? NSNumber)?.int64Value, V2JoinText.expiryGraceMs)
        XCTAssertGreaterThanOrEqual(cases(file, "open").count, 1)
        XCTAssertGreaterThanOrEqual(cases(file, "reject").count, 10)
        XCTAssertGreaterThanOrEqual(cases(file, "fit").count, 1)
    }

    func testOwnCases() throws {
        let file = try loadFile()
        for c in cases(file, "own") {
            let name = c["name"] as? String ?? "?"
            let own = V2JoinPayload.Own(identitySeed: try XCTUnwrap(c["identity_seed"] as? String, name), encapsulationSk: try XCTUnwrap(c["encapsulation_sk"] as? String, name))
            let keys = try XCTUnwrap(own.keys(), name)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            XCTAssertEqual(Base64Url.encode(keys.identityPk), expect["identity_pk"] as? String, name)
            XCTAssertEqual(keys.identitySk, Vectors.hex(try XCTUnwrap(expect["identity_sk_hex"] as? String, name)), name)
            XCTAssertEqual(Base64Url.encode(keys.encapsulationPk), expect["encapsulation_pk"] as? String, name)
            XCTAssertEqual(keys.deviceId, expect["device_id"] as? String, name)
        }
    }

    func testOpenCases() throws {
        let file = try loadFile()
        let f = try fixed(file)
        for c in cases(file, "open") {
            let name = c["name"] as? String ?? "?"
            let v2q = try XCTUnwrap(c["v2q"] as? String, name)
            let plaintext = try XCTUnwrap(c["plaintext_json"] as? String, name)
            guard case let .ok(parsed) = V2JoinPayload.parse(plaintext) else { XCTFail("\(name): plaintext did not parse"); continue }
            XCTAssertEqual(V2JoinPayload.serialize(parsed), plaintext, "\(name): this client's serializer must reproduce the plaintext byte for byte")
            XCTAssertEqual(V2Join.build(parsed, code: f.code, nonce: f.nonce), v2q, name)
            XCTAssertEqual(V2JoinCapacity.byteLength(v2q), (c["bytes"] as? NSNumber)?.intValue, name)
            if let ecc = c["ecc"] as? String { XCTAssertLessThanOrEqual(V2JoinCapacity.byteLength(v2q), V2JoinCapacity.maxBytes[ecc == "M" ? .m : .l] ?? 0, name) }
            guard case let .success(opened) = V2Join.open(v2q, context: context(f, c)) else { XCTFail("\(name) did not open"); continue }
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            let p = opened.payload
            XCTAssertEqual(p.peerUserId, expect["peer_user_id"] as? String, name)
            XCTAssertEqual(p.bindingId, expect["binding_id"] as? String, name)
            XCTAssertEqual(p.epoch, (expect["epoch"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(p.safetyCode, expect["safety_code"] as? String, name)
            XCTAssertEqual(p.roster.map { $0.deviceId }, expect["roster_device_ids"] as? [String], name)
            let masters = try XCTUnwrap(expect["masters"] as? [[String: Any]], name)
            XCTAssertEqual(p.masters.count, masters.count, name)
            for (index, m) in masters.enumerated() where index < p.masters.count {
                XCTAssertEqual(p.epochOfMaster(at: index), (m["epoch"] as? NSNumber)?.intValue, name)
                XCTAssertEqual(Base64Url.decode(p.masters[index]), Vectors.hex(try XCTUnwrap(m["master_hex"] as? String)), name)
            }
            let own = try XCTUnwrap(p.own.keys(), name)
            XCTAssertEqual(own.deviceId, expect["own_device_id"] as? String, name)
            XCTAssertEqual(Base64Url.encode(own.identityPk), expect["own_identity_pk"] as? String, name)
            if let sk = expect["own_identity_sk_hex"] as? String { XCTAssertEqual(own.identitySk, Vectors.hex(sk), name) }
            XCTAssertEqual(Base64Url.encode(own.encapsulationPk), expect["own_encapsulation_pk"] as? String, name)
            XCTAssertEqual(p.expiresMs, (expect["expires_ms"] as? NSNumber)?.int64Value, name)
            // this client's own build of the same case from the fixed actors is the same plaintext
            if let rosterNames = c["roster"] as? [String], let epoch = (c["epoch"] as? NSNumber)?.intValue {
                XCTAssertEqual(V2JoinPayload.serialize(try payload(f, rosterNames: rosterNames, epoch: epoch, historyKept: p.masters.count - 1)), plaintext, "\(name): built from the fixed keys")
            }
            if let install = expect["install"] as? [String: Any] { try checkInstall(f, v2q: v2q, install: install, name: name) }
        }
    }

    /// `expect.install`: what a fresh scanning device holds after installing the code in the chat it names.
    private func checkInstall(_ f: Fixed, v2q: String, install: [String: Any], name: String) throws {
        let ed = V2Suite.generateEd25519(), x = V2Suite.generateX25519()
        let identity = V2Identity(userId: "100", publicKey: ed.publicKey, secretKey: ed.secretKey, encapsulationPk: x.publicKey, encapsulationSk: x.secretKey)
        let nowMs = f.nowMs
        let runtime = V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: V2MemoryStorage()), now: { nowMs })
        let chatId = try XCTUnwrap(install["chat_id"] as? String, name)
        XCTAssertEqual(runtime.join.install(v2q, chatId: chatId), .ok(bindingId: f.bindingId), name)
        let binding = try XCTUnwrap(runtime.pairing.bindingStore.current(chatId), name)
        XCTAssertEqual(binding.txnId, install["txn_id"] as? String, name)
        XCTAssertEqual(binding.ownIdentity?.deviceId, install["own_identity_device_id"] as? String, name)
        XCTAssertEqual(runtime.pairing.canSend(chatId), install["can_send"] as? Bool, name)
        XCTAssertFalse(binding.verified, name)
    }

    func testRejectAndAcceptCases() throws {
        let file = try loadFile()
        let f = try fixed(file)
        for c in cases(file, "reject") {
            let name = c["name"] as? String ?? "?"
            let input = try XCTUnwrap(c["input"] as? String, name)
            let expected = try XCTUnwrap(c["expect_error"] as? String, name)
            switch V2Join.open(input, context: context(f, c)) {
            case .success: XCTFail("\(name) opened")
            case let .failure(error): XCTAssertEqual(error.rawValue, expected, name)
            }
            // a payload-level case ships the plaintext it sealed: this client's AEAD under the fixed code and nonce — the
            // clone AAD, or the retired one for a legacy code — reproduces the very input
            if let plaintext = c["plaintext_json"] as? String {
                let sealed = [V2JoinText.aad, V2JoinText.legacyAad].compactMap { V2Join.seal(plaintext, code: f.code, nonce: f.nonce, aad: $0) }
                XCTAssertTrue(sealed.contains(input), "\(name): sealed here to the same text")
            }
        }
        for c in cases(file, "accept") {
            let name = c["name"] as? String ?? "?"
            guard case .success = V2Join.open(try XCTUnwrap(c["input"] as? String, name), context: context(f, c)) else { XCTFail("\(name) refused"); continue }
        }
    }

    func testFitCases() throws {
        let file = try loadFile()
        let f = try fixed(file)
        for c in cases(file, "fit") {
            let name = c["name"] as? String ?? "?"
            let rosterNames = try XCTUnwrap(c["roster"] as? [String], name)
            let epoch = try XCTUnwrap((c["epoch"] as? NSNumber)?.intValue, name)
            let history = try XCTUnwrap(c["history_epochs_newest_first"] as? [Int], name)
            XCTAssertEqual(history, Array(stride(from: epoch - 1, through: 1, by: -1).prefix(history.count)), "\(name): contiguous below the current generation")
            let render: ([Int]) throws -> String = { kept in
                try XCTUnwrap(V2Join.build(try self.payload(f, rosterNames: rosterNames, epoch: epoch, historyKept: kept.count), code: f.code, nonce: f.nonce))
            }
            XCTAssertEqual(V2JoinCapacity.byteLength(try render([])), (c["bytes_with_no_history"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(V2JoinCapacity.byteLength(try render(history)), (c["bytes_with_all_history"] as? NSNumber)?.intValue, name)
            var limits = V2JoinCapacity.maxBytes
            if let override = c["max_bytes_override"] as? [String: Int] {
                limits = [.m: override["M"] ?? 0, .l: override["L"] ?? 0]
            }
            let fit = try V2JoinCapacity.fit(historyNewestFirst: history, maxBytes: limits, render: render)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            if let ecc = expect["ecc"] as? String {
                guard case let .fits(text, gotEcc, bytes, kept, dropped) = fit else { XCTFail("\(name): expected a fit, got \(fit)"); continue }
                XCTAssertEqual(gotEcc.rawValue, ecc, name)
                XCTAssertEqual(kept, (expect["history_kept"] as? NSNumber)?.intValue, name)
                XCTAssertEqual(dropped, (expect["history_dropped"] as? NSNumber)?.intValue, name)
                XCTAssertEqual(bytes, (expect["bytes"] as? NSNumber)?.intValue, name)
                if let webText = expect["v2q"] as? String { XCTAssertEqual(text, webText, "\(name): the chosen text itself") }
            } else {
                XCTAssertEqual(fit, .tooLarge, name)
                XCTAssertEqual(expect["too_large"] as? Bool, true, name)
            }
        }
    }
}
