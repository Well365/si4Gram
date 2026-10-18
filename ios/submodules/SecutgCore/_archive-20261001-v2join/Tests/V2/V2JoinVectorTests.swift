import Clibsodium
import Foundation
import XCTest
@testable import SecutgCore

/// PLAN.md 3.39.9's shared vectors, `Vectors/vectors-v2join.json` — a byte-for-byte copy of Web A
/// `src/secutg/v2/vectors-v2join.json` (format `secutg-v2join-vectors/2`, after 3.39.12's compaction).
///
/// - `open`: the exact plaintext under the fixed code and nonce reproduces the exact `V2Q` text (KDF, AEAD, base64url
///   and the wrapper all agree); this client's own serializer reproduces the plaintext byte-for-byte; the text opens to
///   `expect` — derived device ids, positional masters, the new device, and the REBUILT commit wire, byte-identical to
///   the one the scanner must send; the new device opens its own package to the next master.
/// - `reject`: the refusal reason is the one Web gives, under the case's own chat / clock / account when it sets one.
/// - `fit`: the capacity decision on the same roster and history — rebuilt here with the vectors' deterministic keys and
///   sealed boxes, so the chosen text itself is byte-identical too — and the expected text opens to that many masters.
///
/// Skipped, not failed, while the file has not been copied over yet (the coordinator hands out the final one).
final class V2JoinVectorTests: XCTestCase {
    private static let fileName = "vectors-v2join"

    private func loadFile() throws -> [String: Any] {
        guard let url = Bundle.module.url(forResource: V2JoinVectorTests.fileName, withExtension: "json", subdirectory: "Vectors") else {
            throw XCTSkip("Vectors/\(V2JoinVectorTests.fileName).json not copied yet (Web is still finalising it)")
        }
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private struct Fixed {
        let ownUserId: String
        let peerUserId: String
        let chatId: String
        let nowMs: Int64
        let expiresMs: Int64
        let label: String
        let code: String
        let nonce: [UInt8]
        let safetyCode: String
        let bindingId: String
        let commitEventId: String
        let commitCreatedMs: String
        let commitExpiresMs: String
        let actors: [String: Actor]
    }

    private struct Actor {
        let name: String
        let signing: V2Suite.KeyPair
        let x25519Sk: [UInt8]
        let x25519Pk: [UInt8]
        var deviceId: String { return Base64Url.encode(V2Suite.sha256(signing.publicKey)) }
        var identityPkB64: String { return Base64Url.encode(signing.publicKey) }
        var encapsulationPkB64: String { return Base64Url.encode(x25519Pk) }
    }

    private func fixed(_ file: [String: Any]) throws -> Fixed {
        let f = try XCTUnwrap(file["fixed"] as? [String: Any])
        var actors: [String: Actor] = [:]
        for (name, raw) in try XCTUnwrap(f["actors"] as? [String: [String: Any]]) {
            let seed = Vectors.hex(try XCTUnwrap(raw["ed25519_seed_hex"] as? String))
            let sk = Vectors.hex(try XCTUnwrap(raw["x25519_sk_hex"] as? String))
            let actor = Actor(name: name, signing: try XCTUnwrap(V2Suite.ed25519KeyPair(seed: seed)), x25519Sk: sk, x25519Pk: try XCTUnwrap(V2Suite.x25519PublicKey(secretKey: sk)))
            // the vectors spell the derived values out: this client derives the same ones
            XCTAssertEqual(actor.identityPkB64, raw["ed25519_pk"] as? String, name)
            XCTAssertEqual(actor.encapsulationPkB64, raw["x25519_pk"] as? String, name)
            XCTAssertEqual(actor.deviceId, raw["device_id"] as? String, name)
            actors[name] = actor
        }
        return Fixed(
            ownUserId: try XCTUnwrap(f["own_user_id"] as? String), peerUserId: try XCTUnwrap(f["peer_user_id"] as? String),
            chatId: try XCTUnwrap(f["chat_id_on_own_devices"] as? String),
            nowMs: try XCTUnwrap((f["now_ms"] as? NSNumber)?.int64Value), expiresMs: try XCTUnwrap((f["expires_ms"] as? NSNumber)?.int64Value),
            label: try XCTUnwrap(f["label"] as? String), code: try XCTUnwrap(f["transfer_code"] as? String),
            nonce: Vectors.hex(try XCTUnwrap(f["nonce_hex"] as? String)), safetyCode: try XCTUnwrap(f["safety_code"] as? String),
            bindingId: try XCTUnwrap(f["binding_id"] as? String), commitEventId: try XCTUnwrap(f["commit_event_id"] as? String),
            commitCreatedMs: try XCTUnwrap(f["commit_created_ms"] as? String), commitExpiresMs: try XCTUnwrap(f["commit_expires_ms"] as? String),
            actors: actors
        )
    }

    private func cases(_ file: [String: Any], _ kind: String) -> [[String: Any]] {
        return (file["cases"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == kind }
    }

    /// "master of epoch e = byte(0x40+e)*32"
    private func master(epoch: Int) -> [UInt8] {
        return [UInt8](repeating: UInt8(0x40 + epoch), count: 32)
    }

    /// The vectors' deterministic sealed box: `crypto_box_seal` built by hand with the ephemeral secret
    /// `byte(0x80+i)*32` for package i — libsodium's own construction (epk || box_easy, nonce = blake2b-24(epk||rpk)).
    private func seal(_ bytes: [UInt8], to recipientPk: [UInt8], index: Int) -> [UInt8] {
        let esk = [UInt8](repeating: UInt8(0x80 + index), count: 32)
        var epk = [UInt8](repeating: 0, count: 32)
        XCTAssertEqual(crypto_scalarmult_base(&epk, esk), 0)
        var nonce = [UInt8](repeating: 0, count: 24)
        let nonceInput = epk + recipientPk
        XCTAssertEqual(crypto_generichash(&nonce, 24, nonceInput, UInt64(nonceInput.count), nil, 0), 0)
        var boxed = [UInt8](repeating: 0, count: bytes.count + Int(crypto_box_macbytes()))
        XCTAssertEqual(crypto_box_easy(&boxed, bytes, UInt64(bytes.count), nonce, recipientPk, esk), 0)
        return epk + boxed
    }

    /// The payload a case describes (roster names, epoch, how much history), signed by O exactly as the showing device
    /// would — so `V2Join.build` under the fixed code and nonce yields the vectors' own text.
    private func payload(_ f: Fixed, rosterNames: [String], epoch: Int, historyKept: Int) throws -> V2JoinPayload.Payload {
        let members = try rosterNames.map { try XCTUnwrap(f.actors[$0], $0) }.sorted { $0.deviceId < $1.deviceId }
        let o = try XCTUnwrap(f.actors["o"])
        let n = try XCTUnwrap(f.actors["n"])
        let rosterIds = members.map { $0.deviceId }
        let deviceRoster = V2JoinPayload.commitDeviceRoster(rosterIds: rosterIds, newDeviceId: n.deviceId)
        let nextMaster = master(epoch: epoch + 1)
        // "the sealed box for device_roster[i] (the COMMIT's sorted order) ... ephemeral secret byte(0x80+i)*32"
        var packageOf: [String: String] = [:]
        for (index, deviceId) in deviceRoster.enumerated() {
            let actor = try XCTUnwrap((members + [n]).first { $0.deviceId == deviceId })
            packageOf[deviceId] = Base64Url.encode(seal(nextMaster, to: actor.x25519Pk, index: index))
        }
        // sign the wire the way V2Roster.prepareAddDevice does (same envelope params, same body)
        let body = V2Messages.RosterCommitBody(
            reason: "add_device", bindingId: f.bindingId, epoch: String(epoch + 1), deviceRoster: deviceRoster,
            packages: deviceRoster.map { V2Messages.DevicePackage(deviceId: $0, pkg: packageOf[$0] ?? "") },
            newDevice: V2Messages.NewDevice(deviceId: n.deviceId, identityPk: n.identityPkB64, encapsulationPk: n.encapsulationPkB64))
        let wire = try XCTUnwrap(V2Messages.buildRosterCommit(V2Messages.EnvelopeParams(
            eventId: f.commitEventId, txnId: nil, chatId: f.peerUserId, actorUser: f.ownUserId, actorIdentityPk: o.signing.publicKey,
            actorIdentitySk: o.signing.secretKey, parentBinding: nil, createdMs: f.commitCreatedMs, expiresMs: f.commitExpiresMs), body))
        let commit = try XCTUnwrap(V2JoinPayload.compactCommitFromWire(wire, expected: V2JoinPayload.CompactCommitInput(
            bindingId: f.bindingId, epoch: epoch, peerUserId: f.peerUserId, rosterIds: rosterIds, newDeviceId: n.deviceId)))
        var masters = [Base64Url.encode(master(epoch: epoch))]
        for e in stride(from: epoch - 1, through: 1, by: -1).prefix(historyKept) { masters.append(Base64Url.encode(master(epoch: e))) }
        return V2JoinPayload.Payload(
            peerUserId: f.peerUserId, bindingId: f.bindingId, epoch: epoch, safetyCode: f.safetyCode,
            roster: members.map { V2JoinPayload.RosterEntry(identityPk: $0.identityPkB64, encapsulationPk: $0.encapsulationPkB64) },
            masters: masters,
            newDevice: V2JoinPayload.NewDevice(label: f.label, identitySeed: Base64Url.encode(Array(n.signing.secretKey.prefix(32))), encapsulationSk: Base64Url.encode(n.x25519Sk)),
            commit: commit, expiresMs: f.expiresMs)
    }

    private func context(_ f: Fixed, chatId: String? = nil, nowMs: Int64? = nil, ownUserId: String? = nil) -> V2Join.OpenContext {
        return V2Join.OpenContext(chatId: chatId ?? f.chatId, ownUserId: ownUserId ?? f.ownUserId, nowMs: nowMs ?? f.nowMs)
    }

    func testFileShape() throws {
        let file = try loadFile()
        XCTAssertTrue((file["format"] as? String ?? "").hasPrefix("secutg-v2join-vectors/"), file["format"] as? String ?? "")
        let maxBytes = try XCTUnwrap(file["max_bytes"] as? [String: Int])
        XCTAssertEqual(maxBytes["M"], V2JoinCapacity.maxBytes[.m])
        XCTAssertEqual(maxBytes["L"], V2JoinCapacity.maxBytes[.l])
        XCTAssertGreaterThanOrEqual(cases(file, "open").count, 1)
        XCTAssertGreaterThanOrEqual(cases(file, "reject").count, 10)
        XCTAssertGreaterThanOrEqual(cases(file, "fit").count, 1)
    }

    func testOpenCases() throws {
        let file = try loadFile()
        let f = try fixed(file)
        for c in cases(file, "open") {
            let name = c["name"] as? String ?? "?"
            let v2q = try XCTUnwrap(c["v2q"] as? String, name)
            let plaintext = try XCTUnwrap(c["plaintext_json"] as? String, name)
            // the KDF, AEAD, base64url and the wrapper: the exact plaintext under the fixed code and nonce is the exact text
            let parsedPlain = try XCTUnwrap(V2JoinPayload.parse(plaintext), name)
            XCTAssertEqual(V2JoinPayload.serialize(parsedPlain), plaintext, "\(name): this client's serializer must reproduce the plaintext byte for byte")
            XCTAssertEqual(V2Join.build(parsedPlain, code: f.code, nonce: f.nonce), v2q, name)
            XCTAssertEqual(V2JoinCapacity.byteLength(v2q), (c["bytes"] as? NSNumber)?.intValue, name)
            if let ecc = c["ecc"] as? String { XCTAssertLessThanOrEqual(V2JoinCapacity.byteLength(v2q), V2JoinCapacity.maxBytes[ecc == "M" ? .m : .l] ?? 0, name) }
            // and, the normative part, it opens to expect
            guard case let .success(opened) = V2Join.open(v2q, context: context(f)) else { XCTFail("\(name) did not open"); continue }
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
            let newKeys = try XCTUnwrap(p.newDevice.keys(), name)
            XCTAssertEqual(newKeys.deviceId, expect["new_device_id"] as? String, name)
            if let pk = expect["new_device_identity_pk"] as? String { XCTAssertEqual(Base64Url.encode(newKeys.identityPk), pk, name) }
            if let pk = expect["new_device_encapsulation_pk"] as? String { XCTAssertEqual(Base64Url.encode(newKeys.encapsulationPk), pk, name) }
            XCTAssertEqual(p.newDevice.label, expect["new_device_label"] as? String, name)
            if let actorIndex = (expect["commit_actor_index"] as? NSNumber)?.intValue { XCTAssertEqual(p.commit.actor, actorIndex, name) }
            if let actorDevice = expect["commit_actor_device"] as? String { XCTAssertEqual(p.actorEntry?.deviceId, actorDevice, name) }
            XCTAssertEqual(opened.commitWire, expect["commit_wire"] as? String, "\(name): the rebuilt wire is the very text the scanner sends")
            let commit = try XCTUnwrap(V2Messages.parseRosterCommit(opened.commitWire), name)
            XCTAssertEqual(commit.body.deviceRoster, expect["commit_device_roster"] as? [String], name)
            XCTAssertEqual(commit.body.epoch, String((expect["commit_epoch"] as? NSNumber)?.intValue ?? -1), name)
            // the new device opens its own package to the next generation's master
            let ownPackage = try XCTUnwrap(commit.body.packages.first { $0.deviceId == newKeys.deviceId }, name)
            let sealed = try XCTUnwrap(Base64Url.decode(ownPackage.pkg), name)
            let openedMaster = V2Suite.openSealed(recipientPk: newKeys.encapsulationPk, recipientSk: newKeys.encapsulationSk, sealed: sealed)
            XCTAssertEqual(openedMaster, Vectors.hex(try XCTUnwrap(expect["packages_open_to_master_hex"] as? String)), name)
            XCTAssertEqual(p.expiresMs, (expect["expires_ms"] as? NSNumber)?.int64Value, name)
            // and this client's own build of the same case, from the fixed keys, is the same text
            if let rosterNames = c["roster"] as? [String], let epoch = (c["epoch"] as? NSNumber)?.intValue {
                let mine = try payload(f, rosterNames: rosterNames, epoch: epoch, historyKept: p.masters.count - 1)
                XCTAssertEqual(V2JoinPayload.serialize(mine), plaintext, "\(name): built from the fixed keys")
            }
        }
    }

    func testRejectCases() throws {
        let file = try loadFile()
        let f = try fixed(file)
        for c in cases(file, "reject") {
            let name = c["name"] as? String ?? "?"
            let input = try XCTUnwrap(c["input"] as? String, name)
            let expected = try XCTUnwrap(c["expect_error"] as? String, name)
            let ctx = context(f, chatId: c["chat_id"] as? String, nowMs: (c["now_ms"] as? NSNumber)?.int64Value, ownUserId: c["own_user_id"] as? String)
            switch V2Join.open(input, context: ctx) {
            case .success: XCTFail("\(name) opened")
            case let .failure(error): XCTAssertEqual(error.rawValue, expected, name)
            }
            // a payload-level case ships the plaintext it encrypted: this client's AEAD under the fixed code and nonce
            // reproduces the very input (so the refusal is about the payload, not about how it was sealed)
            if let plaintext = c["plaintext_json"] as? String {
                let key = try XCTUnwrap(V2Join.keyFor(code: f.code), name)
                let ciphertext = V2Suite.aeadEncrypt(key: key, nonce: f.nonce, plaintext: V2Suite.utf8(plaintext), aad: V2Suite.utf8(V2JoinText.aad))
                XCTAssertEqual(V2JoinText.build(code: f.code, nonceB64: Base64Url.encode(f.nonce), ciphertextB64: Base64Url.encode(ciphertext)), input, name)
            }
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
            let expect = try XCTUnwrap(c["expect"] as? [String: Any], name)
            // the same decision, on the same inputs, with the same deterministic keys and sealed boxes
            let render: ([Int]) throws -> String = { kept in
                try XCTUnwrap(V2Join.build(try self.payload(f, rosterNames: rosterNames, epoch: epoch, historyKept: kept.count), code: f.code, nonce: f.nonce))
            }
            XCTAssertEqual(V2JoinCapacity.byteLength(try render([])), (c["bytes_with_no_history"] as? NSNumber)?.intValue, name)
            XCTAssertEqual(V2JoinCapacity.byteLength(try render(history)), (c["bytes_with_all_history"] as? NSNumber)?.intValue, name)
            let fit = try V2JoinCapacity.fit(historyNewestFirst: history, render: render)
            if let ecc = expect["ecc"] as? String {
                guard case let .fits(text, gotEcc, bytes, kept, dropped) = fit else { XCTFail("\(name): expected a fit, got \(fit)"); continue }
                XCTAssertEqual(gotEcc.rawValue, ecc, name)
                XCTAssertEqual(kept, (expect["history_kept"] as? NSNumber)?.intValue, name)
                XCTAssertEqual(dropped, (expect["history_dropped"] as? NSNumber)?.intValue, name)
                XCTAssertEqual(bytes, (expect["bytes"] as? NSNumber)?.intValue, name)
                if let webText = expect["v2q"] as? String {
                    XCTAssertEqual(text, webText, "\(name): the chosen text itself")
                    guard case let .success(opened) = V2Join.open(webText, context: context(f)) else { XCTFail("\(name): Web text did not open"); continue }
                    XCTAssertEqual(opened.payload.masters.count, 1 + kept, name)
                }
            } else {
                XCTAssertEqual(fit, .tooLarge, name)
                XCTAssertEqual(expect["too_large"] as? Bool ?? (expect["error"] as? String == "too_large"), true, name)
            }
        }
    }
}
