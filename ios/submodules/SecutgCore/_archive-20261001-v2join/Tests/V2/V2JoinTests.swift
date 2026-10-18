import XCTest
@testable import SecutgCore

/// PLAN.md 3.39.2 / 3.39.9 / 3.39.12: the pure halves of the V2Q — text syntax, the ordered JSON, the payload's fixed
/// (compact) shape, the envelope's four refusal reasons, the capacity rule and the pending store. The flows are
/// `V2JoinFlowTests`.
final class V2JoinTests: XCTestCase {
    private let code = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private let nonce: [UInt8] = Array(0..<24)
    private let ownUser = "100"
    private let peerUser = "200"

    private func makeIdentity(_ userId: String) -> V2Identity {
        let ed = V2Suite.generateEd25519()
        let enc = V2Suite.generateX25519()
        return V2Identity(userId: userId, publicKey: ed.publicKey, secretKey: ed.secretKey, encapsulationPk: enc.publicKey, encapsulationSk: enc.secretKey)
    }

    private func deviceId(_ identity: V2Identity) -> String {
        return Base64Url.encode(V2Suite.sha256(identity.publicKey))
    }

    /// O (user 100) and P (user 200) already bound at epoch `epoch`, on O's stores; O's name for the chat is P's id.
    private struct Fixture {
        let o: V2Identity
        let p: V2Identity
        let bindingStore = V2Binding.BindingStore()
        let tombstoneStore = V2Binding.TombstoneStore()
        let keyStore = V2KeyStore.BindingKeyStore()
        let bindingId: String
        let masters: [Int: [UInt8]]
        let roster: V2Roster.RosterProcessor
        let chat: String

        init(o: V2Identity, p: V2Identity, chat: String, epoch: Int, now: @escaping () -> Int64) {
            self.o = o
            self.p = p
            self.chat = chat
            bindingId = Base64Url.encode(V2Suite.sha256(V2Suite.utf8("join-test-binding")))
            let oDevice = Base64Url.encode(V2Suite.sha256(o.publicKey))
            let pDevice = Base64Url.encode(V2Suite.sha256(p.publicKey))
            let keys: [String: V2Binding.DeviceKeys] = [
                oDevice: V2Binding.DeviceKeys(identityPk: Base64Url.encode(o.publicKey), encapsulationPk: Base64Url.encode(o.encapsulationPk)),
                pDevice: V2Binding.DeviceKeys(identityPk: Base64Url.encode(p.publicKey), encapsulationPk: Base64Url.encode(p.encapsulationPk)),
            ]
            bindingStore.install(V2Binding.freshTemplate(chatId: chat, bindingId: bindingId, epoch: epoch, deviceRoster: [oDevice, pDevice].sorted(), deviceKeys: keys, revision: 1, txnId: "txn-1", installedAtMs: 1000))
            var masters: [Int: [UInt8]] = [:]
            for e in 1...epoch {
                var m = [UInt8](repeating: 0, count: 32)
                m[0] = UInt8(e)
                masters[e] = m
                keyStore.installCurrent(bindingId: bindingId, epoch: e, master: m)
            }
            self.masters = masters
            roster = V2Roster.RosterProcessor(identity: o, bindingStore: bindingStore, tombstoneStore: tombstoneStore, keyStore: keyStore, now: now)
        }
    }

    private struct Minted {
        let ed: V2Suite.KeyPair
        let x: V2Suite.KeyPair
        var deviceId: String { return Base64Url.encode(V2Suite.sha256(ed.publicKey)) }
        var newDevice: V2JoinPayload.NewDevice {
            return V2JoinPayload.NewDevice(label: "O's phone", identitySeed: Base64Url.encode(Array(ed.secretKey.prefix(32))), encapsulationSk: Base64Url.encode(x.secretKey))
        }
    }

    private func mint() -> Minted {
        return Minted(ed: V2Suite.generateEd25519(), x: V2Suite.generateX25519())
    }

    /// A complete, honestly-signed payload the way `V2JoinCoordinator.prepareShare` assembles one.
    private func makePayload(_ f: Fixture, minted: Minted, historyKept: Int, expiresMs: Int64) -> V2JoinPayload.Payload {
        let binding = f.bindingStore.current(f.chat)!
        let prepared = f.roster.prepareAddDevice(chatId: f.chat, newDevice: V2Roster.NewDeviceInput(deviceId: minted.deviceId, identityPk: minted.ed.publicKey, encapsulationPk: minted.x.publicKey))!
        let commit = V2JoinPayload.compactCommitFromWire(prepared.wire, expected: V2JoinPayload.CompactCommitInput(
            bindingId: binding.bindingId, epoch: binding.epoch, peerUserId: f.chat, rosterIds: binding.deviceRoster, newDeviceId: minted.deviceId))!
        let roster = binding.deviceRoster.map { V2JoinPayload.RosterEntry(identityPk: binding.deviceKeys[$0]!.identityPk, encapsulationPk: binding.deviceKeys[$0]!.encapsulationPk) }
        var masters = [Base64Url.encode(f.masters[binding.epoch]!)]
        for e in stride(from: binding.epoch - 1, through: 1, by: -1).prefix(historyKept) {
            masters.append(Base64Url.encode(f.masters[e]!))
        }
        return V2JoinPayload.Payload(
            peerUserId: f.chat, bindingId: binding.bindingId, epoch: binding.epoch, safetyCode: "1234 5678 9012", roster: roster, masters: masters,
            newDevice: minted.newDevice, commit: commit, expiresMs: expiresMs)
    }

    private func fixture(epoch: Int = 1, nowMs: Int64 = 1_790_000_000_000) -> Fixture {
        return Fixture(o: makeIdentity(ownUser), p: makeIdentity(peerUser), chat: peerUser, epoch: epoch, now: { nowMs })
    }

    private func context(chat: String? = nil, nowMs: Int64 = 1_790_000_000_000) -> V2Join.OpenContext {
        return V2Join.OpenContext(chatId: chat ?? peerUser, ownUserId: ownUser, nowMs: nowMs)
    }

    // MARK: text

    func testTextParseIsStrictAndBuildIsItsInverse() {
        let nonceB64 = Base64Url.encode(nonce)
        let ct = String(repeating: "A", count: 40)
        let text = V2JoinText.build(code: "0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYZ", nonceB64: nonceB64, ciphertextB64: ct)
        XCTAssertEqual(text, "V2Q:\(code):\(nonceB64):\(ct)")
        XCTAssertEqual(V2JoinText.parse("  " + text! + "\n"), V2JoinText.Parsed(code: code, nonce: nonceB64, ciphertext: ct))
        XCTAssertTrue(V2JoinText.isV2JoinText(" V2Q:x"))
        XCTAssertFalse(V2JoinText.isV2JoinText("K1Q:x"))
        // no leniency for a machine-written code, exact nonce length, at least a tag, exactly three parts
        XCTAssertNil(V2JoinText.parse("V2Q:\(code.lowercased()):\(nonceB64):\(ct)"))
        XCTAssertNil(V2JoinText.parse("V2Q:\(code.replacingOccurrences(of: "V", with: "U")):\(nonceB64):\(ct)"))
        XCTAssertNil(V2JoinText.parse("V2Q:\(code):\(nonceB64.dropLast()):\(ct)"))
        XCTAssertNil(V2JoinText.parse("V2Q:\(code):\(nonceB64):\(String(repeating: "A", count: 21))"))
        XCTAssertNil(V2JoinText.parse("V2Q:\(code):\(nonceB64):\(ct):extra"))
        XCTAssertNil(V2JoinText.parse("V2Q:\(code):\(nonceB64)"))
        XCTAssertNil(V2JoinText.parse("V2Q:\(code):\(nonceB64):\(ct)!"))
        XCTAssertNil(V2JoinText.build(code: "not a code", nonceB64: nonceB64, ciphertextB64: ct))
        XCTAssertEqual(V2JoinText.canonicalCode("0123-4567-89ab-cdef-ghjk-mnpq-rstv-wxyz"), code)
        XCTAssertNil(V2JoinText.canonicalCode("0123-4567-89AB-CDEF-GHJK-MNPQ-RSTV-WXYI"))
    }

    func testJoinCodeDerivesADifferentKeyThanTheTransferCode() throws {
        let bytes = try XCTUnwrap(TransferCode.parse(code))
        XCTAssertNotEqual(try TransferCode.deriveKey(bytes), try TransferCode.deriveKey(bytes, context: V2JoinText.kdfContext))
        XCTAssertEqual(try TransferCode.deriveKey(bytes, context: V2JoinText.kdfContext).count, 32)
        XCTAssertEqual(V2Join.generateCode().count, 32)
        XCTAssertNotNil(V2JoinText.canonicalCode(V2Join.generateCode()))
    }

    func testTheNewDevicesKeysAreDerivedFromTheTwoSecretsTheCodeCarries() throws {
        let m = mint()
        let keys = try XCTUnwrap(m.newDevice.keys())
        XCTAssertEqual(keys.identityPk, m.ed.publicKey)
        XCTAssertEqual(keys.identitySk, m.ed.secretKey, "libsodium's 64-byte key is seed || pk, rebuilt from the seed alone")
        XCTAssertEqual(keys.encapsulationPk, m.x.publicKey)
        XCTAssertEqual(keys.encapsulationSk, m.x.secretKey)
        XCTAssertEqual(keys.deviceId, m.deviceId)
        XCTAssertEqual(V2Suite.ed25519Seed(ofSecretKey: m.ed.secretKey), Array(m.ed.secretKey.prefix(32)))
        XCTAssertNil(V2Suite.ed25519KeyPair(seed: [1, 2, 3]))
        XCTAssertNil(V2Suite.x25519PublicKey(secretKey: [1, 2, 3]))
        XCTAssertNil(V2JoinPayload.NewDevice(label: "x", identitySeed: "AAAA", encapsulationSk: m.newDevice.encapsulationSk).keys())
    }

    // MARK: ordered JSON

    func testOrderedJsonSerializesLikeJsonStringifyAndParsesStrictly() {
        let value: V2JoinJSON = .object([
            .init("b", .string("q\"\\\n\t\u{01}\u{7f}é😀")), .init("a", .int(-12)), .init("z", .array([.null, .object([])])),
        ])
        let text = V2JoinJSON.serialize(value)
        XCTAssertEqual(text, "{\"b\":\"q\\\"\\\\\\n\\t\\u0001\u{7f}é😀\",\"a\":-12,\"z\":[null,{}]}")
        XCTAssertEqual(V2JoinJSON.parse(text), value)
        XCTAssertTrue(value.hasKeysInOrder(["b", "a", "z"]))
        XCTAssertFalse(value.hasKeysInOrder(["a", "b", "z"]))
        XCTAssertFalse(value.hasKeysInOrder(["b", "a"]))
        // JSON.parse's own tolerance: whitespace, escapes, integral floats
        XCTAssertEqual(V2JoinJSON.parse(" { \"a\" : 1.0 , \"b\" : \"\\u00e9\\ud83d\\ude00\\/\" } "),
                       .object([.init("a", .int(1)), .init("b", .string("é😀/"))]))
        // and what is refused: duplicates, non-integers, unsafe integers, trailing garbage, booleans, raw controls
        XCTAssertNil(V2JoinJSON.parse("{\"a\":1,\"a\":2}"))
        XCTAssertNil(V2JoinJSON.parse("{\"a\":1.5}"))
        XCTAssertNil(V2JoinJSON.parse("{\"a\":9007199254740992}"))
        XCTAssertNil(V2JoinJSON.parse("{\"a\":1}x"))
        XCTAssertNil(V2JoinJSON.parse("{\"a\":true}"))
        XCTAssertNil(V2JoinJSON.parse("{\"a\":\"\u{01}\"}"))
        XCTAssertNil(V2JoinJSON.parse("{\"a\":01}"))
        XCTAssertNil(V2JoinJSON.parse("{\"a\":\"\\x\"}"))
        XCTAssertNil(V2JoinJSON.parse("[1,]"))
    }

    // MARK: payload

    func testPayloadSerializesInTheFixedCompactOrderAndRoundTrips() throws {
        let f = fixture(epoch: 3)
        let payload = makePayload(f, minted: mint(), historyKept: 2, expiresMs: 1_790_000_600_000)
        let text = V2JoinPayload.serialize(payload)
        XCTAssertTrue(text.hasPrefix("{\"v\":1,\"kind\":\"v2join\",\"peer_user_id\":\"200\",\"binding_id\":\""))
        XCTAssertTrue(text.hasSuffix(",\"expires_ms\":1790000600000}"))
        XCTAssertTrue(text.contains("\"epoch\":3,\"safety_code\":\"1234 5678 9012\",\"roster\":[[\""))
        XCTAssertTrue(text.contains("\"masters\":[\""))
        XCTAssertTrue(text.contains("\"new_device\":{\"label\":\"O's phone\",\"identity_seed\":\""))
        XCTAssertTrue(text.contains("\"commit\":{\"event_id\":\""))
        XCTAssertFalse(text.contains("device_id"), "device ids are derived, never carried")
        XCTAssertFalse(text.contains("identity_pk\":") && text.contains("\"new_device\":{\"identity_pk"), "the new device's public keys are derived")
        let parsed = try XCTUnwrap(V2JoinPayload.parse(text))
        XCTAssertEqual(parsed, payload)
        XCTAssertEqual(parsed.masters.count, 3)
        XCTAssertEqual((0..<3).map { parsed.epochOfMaster(at: $0) }, [3, 2, 1])
        XCTAssertEqual(parsed.roster.map { $0.deviceId }.sorted(), f.bindingStore.current(f.chat)?.deviceRoster)
    }

    func testPayloadParseRefusesAnyDeviationFromTheFixedShape() throws {
        let f = fixture(epoch: 2)
        let payload = makePayload(f, minted: mint(), historyKept: 1, expiresMs: 1_790_000_600_000)
        let text = V2JoinPayload.serialize(payload)
        XCTAssertNotNil(V2JoinPayload.parse(text))
        func mutated(_ from: String, _ to: String, file: StaticString = #filePath, line: UInt = #line) -> V2JoinPayload.Payload? {
            XCTAssertTrue(text.contains(from), from, file: file, line: line)
            return V2JoinPayload.parse(text.replacingOccurrences(of: from, with: to))
        }
        // order, version, kind, an extra field, a number where a string belongs and vice versa
        XCTAssertNil(mutated("{\"v\":1,\"kind\":\"v2join\",", "{\"kind\":\"v2join\",\"v\":1,"))
        XCTAssertNil(mutated("{\"v\":1,", "{\"v\":2,"))
        XCTAssertNil(mutated("\"kind\":\"v2join\"", "\"kind\":\"v2joinx\""))
        XCTAssertNil(mutated("\"expires_ms\":1790000600000}", "\"expires_ms\":1790000600000,\"x\":1}"))
        XCTAssertNil(mutated("\"expires_ms\":1790000600000}", "\"expires_ms\":\"1790000600000\"}"))
        XCTAssertNil(mutated("\"epoch\":2,\"safety_code\"", "\"epoch\":\"2\",\"safety_code\""))
        // masters: positional, so at most `epoch` of them; each exactly 32 bytes
        XCTAssertNil(mutated("\"epoch\":2,\"safety_code\"", "\"epoch\":1,\"safety_code\""))
        XCTAssertNil(mutated("\"masters\":[\"\(payload.masters[0])\"", "\"masters\":[\"AAAA\""))
        // roster: pairs, not objects; no repeated key; at least two devices
        XCTAssertNil(mutated("\"roster\":[[\"\(payload.roster[0].identityPk)\",", "\"roster\":[{\"identity_pk\":\"\(payload.roster[0].identityPk)\",\"encapsulation_pk\":"))
        XCTAssertNil(mutated("\"roster\":[[\"\(payload.roster[0].identityPk)\",\"\(payload.roster[0].encapsulationPk)\"],", "\"roster\":["))
        // the new device: exactly the three keys, in order, 32 bytes each
        XCTAssertNil(mutated("\"new_device\":{\"label\":\"O's phone\",", "\"new_device\":{"))
        XCTAssertNil(mutated("\"identity_seed\":\"\(payload.newDevice.identitySeed)\"", "\"identity_seed\":\"\(payload.newDevice.encapsulationSk)\",\"identity_seed2\":\"x\""))
        // packages: exactly roster + 1; the actor is an index into the roster, a number, in range
        XCTAssertNil(mutated("\"packages\":[\"\(payload.commit.packages[0])\",", "\"packages\":["))
        XCTAssertNil(mutated("\"actor\":\(payload.commit.actor),", "\"actor\":9,"))
        XCTAssertNil(mutated("\"actor\":\(payload.commit.actor),", "\"actor\":\"\(payload.commit.actor)\","))
        XCTAssertNil(mutated("\"actor\":\(payload.commit.actor),", "\"actor\":-1,"))
        // the roster must be in ascending device-id order (which is also what makes it duplicate-free)
        let first = "[\"\(payload.roster[0].identityPk)\",\"\(payload.roster[0].encapsulationPk)\"]"
        let second = "[\"\(payload.roster[1].identityPk)\",\"\(payload.roster[1].encapsulationPk)\"]"
        XCTAssertNil(mutated("\"roster\":[\(first),\(second)]", "\"roster\":[\(second),\(first)]"))
        XCTAssertNil(mutated("\"roster\":[\(first),\(second)]", "\"roster\":[\(first),\(first)]"))
        // not JSON at all
        XCTAssertNil(V2JoinPayload.parse("nope"))
        XCTAssertNil(V2JoinPayload.parse(""))
    }

    func testCompactCommitRoundTripsThroughTheRebuiltWireByteForByte() throws {
        let f = fixture(epoch: 2)
        let binding = f.bindingStore.current(f.chat)!
        let m = mint()
        let prepared = try XCTUnwrap(f.roster.prepareAddDevice(chatId: f.chat, newDevice: V2Roster.NewDeviceInput(deviceId: m.deviceId, identityPk: m.ed.publicKey, encapsulationPk: m.x.publicKey)))
        // prepare does not touch O's own state
        XCTAssertEqual(f.bindingStore.current(f.chat)?.epoch, 2)
        XCTAssertNil(f.keyStore.get(f.bindingId, 3))
        XCTAssertEqual(prepared.epoch, 3)
        XCTAssertEqual(prepared.deviceRoster.count, 3)
        let expected = V2JoinPayload.CompactCommitInput(bindingId: binding.bindingId, epoch: binding.epoch, peerUserId: f.chat, rosterIds: binding.deviceRoster, newDeviceId: m.deviceId)
        let compact = try XCTUnwrap(V2JoinPayload.compactCommitFromWire(prepared.wire, expected: expected))
        XCTAssertEqual(compact.packages.count, 3)
        XCTAssertEqual(compact.eventId, prepared.eventId)
        XCTAssertEqual(compact.actor, binding.deviceRoster.firstIndex(of: deviceId(f.o)), "the actor travels as its roster index")
        // positional: [roster…, new_device], whatever the sorted wire order was
        let wirePackages = V2Messages.parseRosterCommit(prepared.wire)!.body.packages
        XCTAssertEqual(compact.packages.last, wirePackages.first { $0.deviceId == m.deviceId }?.pkg)
        XCTAssertEqual(compact.packages[0], wirePackages.first { $0.deviceId == binding.deviceRoster[0] }?.pkg)
        let roster = binding.deviceRoster.map { V2JoinPayload.RosterEntry(identityPk: binding.deviceKeys[$0]!.identityPk, encapsulationPk: binding.deviceKeys[$0]!.encapsulationPk) }
        let payload = V2JoinPayload.Payload(peerUserId: f.chat, bindingId: binding.bindingId, epoch: binding.epoch, safetyCode: "1234 5678 9012", roster: roster,
                                            masters: [Base64Url.encode(f.masters[2]!)], newDevice: m.newDevice, commit: compact, expiresMs: 0)
        XCTAssertEqual(V2JoinPayload.rebuildCommitWire(payload, ownUserId: ownUser), prepared.wire, "SJ is canonical, so the rebuilt envelope is the very bytes O signed")
        XCTAssertTrue(V2JoinPayload.verifyCommitWire(prepared.wire, actorIdentityPk: Base64Url.encode(f.o.publicKey)))
        XCTAssertFalse(V2JoinPayload.verifyCommitWire(prepared.wire, actorIdentityPk: Base64Url.encode(f.p.publicKey)))
        // refusals: a different expectation, or a wire that is not an add_device commit
        XCTAssertNil(V2JoinPayload.compactCommitFromWire(prepared.wire, expected: V2JoinPayload.CompactCommitInput(bindingId: binding.bindingId, epoch: 5, peerUserId: f.chat, rosterIds: binding.deviceRoster, newDeviceId: m.deviceId)))
        XCTAssertNil(V2JoinPayload.compactCommitFromWire(prepared.wire, expected: V2JoinPayload.CompactCommitInput(bindingId: binding.bindingId, epoch: 2, peerUserId: "999", rosterIds: binding.deviceRoster, newDeviceId: m.deviceId)))
        let rekey = try XCTUnwrap(f.roster.rekey(f.chat))
        XCTAssertNil(V2JoinPayload.compactCommitFromWire(rekey, expected: expected))
    }

    // MARK: envelope

    func testEnvelopeRoundTripIsDeterministicUnderAFixedNonceAndOpensToTheSamePayload() throws {
        let f = fixture(epoch: 2)
        let payload = makePayload(f, minted: mint(), historyKept: 1, expiresMs: 1_790_000_600_000)
        let text = try XCTUnwrap(V2Join.build(payload, code: code, nonce: nonce))
        XCTAssertEqual(V2Join.build(payload, code: code, nonce: nonce), text)
        XCTAssertNotEqual(V2Join.build(payload, code: code), text, "a real code draws a fresh nonce")
        XCTAssertTrue(text.hasPrefix("V2Q:\(code):\(Base64Url.encode(nonce)):"))
        guard case let .success(opened) = V2Join.open(text, context: context()) else { return XCTFail("did not open") }
        XCTAssertEqual(opened.payload, payload)
        XCTAssertEqual(opened.code, code)
        XCTAssertTrue(V2JoinPayload.verifyCommitWire(opened.commitWire, actorIdentityPk: Base64Url.encode(f.o.publicKey)))
        XCTAssertNil(V2Join.build(payload, code: "short", nonce: nonce))
        XCTAssertNil(V2Join.build(payload, code: code, nonce: [1, 2, 3]))
    }

    func testEnvelopeRefusalReasonsInTheSpecifiedOrder() throws {
        let f = fixture(epoch: 1)
        let expires: Int64 = 1_790_000_600_000
        let payload = makePayload(f, minted: mint(), historyKept: 0, expiresMs: expires)
        let text = try XCTUnwrap(V2Join.build(payload, code: code, nonce: nonce))
        func error(_ t: String, _ ctx: V2Join.OpenContext) -> V2Join.OpenError? {
            if case let .failure(e) = V2Join.open(t, context: ctx) { return e }
            return nil
        }
        // syntax
        XCTAssertEqual(error("K1Q" + text.dropFirst(3), context()), .malformed)
        XCTAssertEqual(error(text + "!", context()), .malformed)
        // wrong code / tampered ciphertext
        let otherCode = "ZYXWVTSRQPNMKJHGFEDCBA9876543210"
        XCTAssertEqual(error("V2Q:\(otherCode):" + text.dropFirst("V2Q:\(code):".count), context()), .undecryptable)
        // a flipped character inside the ciphertext (not the last one, whose slack bits base64url may refuse as
        // non-canonical, which is a syntax refusal rather than an AEAD one)
        var tampered = Array(text.utf8)
        let ciphertextStart = "V2Q:\(code):\(Base64Url.encode(nonce)):".utf8.count + 10
        tampered[ciphertextStart] = tampered[ciphertextStart] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")
        XCTAssertEqual(error(String(decoding: tampered, as: UTF8.self), context()), .undecryptable)
        // a valid envelope for a different chat, and an expired one (grace: +2 minutes)
        XCTAssertEqual(error(text, context(chat: "300")), .wrongChat)
        XCTAssertNil(error(text, context(nowMs: expires + V2JoinText.expiryGraceMs)))
        XCTAssertEqual(error(text, context(nowMs: expires + V2JoinText.expiryGraceMs + 1)), .expired)
        // wrong_chat is decided before expired
        XCTAssertEqual(error(text, V2Join.OpenContext(chatId: "300", ownUserId: ownUser, nowMs: expires + 10 * 60 * 1000)), .wrongChat)
        // a payload whose commit signature does not verify: malformed, before wrong_chat or expired are even asked
        let badSig = V2JoinPayload.Commit(eventId: payload.commit.eventId, createdMs: payload.commit.createdMs, expiresMs: payload.commit.expiresMs,
                                         actor: payload.commit.actor, packages: payload.commit.packages, sig: Base64Url.encode([UInt8](repeating: 7, count: 64)))
        let forged = V2JoinPayload.Payload(peerUserId: payload.peerUserId, bindingId: payload.bindingId, epoch: payload.epoch, safetyCode: payload.safetyCode,
                                           roster: payload.roster, masters: payload.masters, newDevice: payload.newDevice, commit: badSig, expiresMs: payload.expiresMs)
        XCTAssertEqual(error(try XCTUnwrap(V2Join.build(forged, code: code, nonce: nonce)), V2Join.OpenContext(chatId: "300", ownUserId: ownUser, nowMs: expires + 10 * 60 * 1000)), .malformed)
        // the commit signed by the OTHER roster member's index: O's signature does not verify under P's key
        let otherActor = V2JoinPayload.Commit(eventId: payload.commit.eventId, createdMs: payload.commit.createdMs, expiresMs: payload.commit.expiresMs,
                                              actor: 1 - payload.commit.actor, packages: payload.commit.packages, sig: payload.commit.sig)
        let misattributed = V2JoinPayload.Payload(peerUserId: payload.peerUserId, bindingId: payload.bindingId, epoch: payload.epoch, safetyCode: payload.safetyCode,
                                                  roster: payload.roster, masters: payload.masters, newDevice: payload.newDevice, commit: otherActor, expiresMs: payload.expiresMs)
        XCTAssertEqual(error(try XCTUnwrap(V2Join.build(misattributed, code: code, nonce: nonce)), context()), .malformed)
        // a payload whose packages were shuffled: the rebuilt bytes differ from what O signed
        let shuffled = V2JoinPayload.Commit(eventId: payload.commit.eventId, createdMs: payload.commit.createdMs, expiresMs: payload.commit.expiresMs,
                                            actor: payload.commit.actor, packages: payload.commit.packages.reversed(), sig: payload.commit.sig)
        let reordered = V2JoinPayload.Payload(peerUserId: payload.peerUserId, bindingId: payload.bindingId, epoch: payload.epoch, safetyCode: payload.safetyCode,
                                              roster: payload.roster, masters: payload.masters, newDevice: payload.newDevice, commit: shuffled, expiresMs: payload.expiresMs)
        XCTAssertEqual(error(try XCTUnwrap(V2Join.build(reordered, code: code, nonce: nonce)), context()), .malformed)
        // and a scanning account that is not O's: the rebuilt envelope names another actor_user, so O's signature fails
        XCTAssertEqual(error(text, V2Join.OpenContext(chatId: peerUser, ownUserId: "777", nowMs: expires)), .malformed)
    }

    // MARK: capacity

    func testCapacityRuleKeepsAsMuchHistoryAsEitherLevelTakesBeforeDroppingAny() {
        // render(kept) = base + 300 bytes per kept master
        func render(base: Int) -> ([Int]) -> String {
            return { kept in String(repeating: "x", count: base + 300 * kept.count) }
        }
        let history = [3, 2, 1]
        // 1900 fits M outright
        XCTAssertEqual(V2JoinCapacity.fit(historyNewestFirst: history, render: render(base: 1000)),
                       .fits(text: String(repeating: "x", count: 1900), ecc: .m, bytes: 1900, historyKept: 3, historyDropped: 0))
        // 2500 > 2331 but <= 2953: L with everything, rather than M with less
        XCTAssertEqual(V2JoinCapacity.fit(historyNewestFirst: history, render: render(base: 1600)),
                       .fits(text: String(repeating: "x", count: 2500), ecc: .l, bytes: 2500, historyKept: 3, historyDropped: 0))
        // 3300 / 3000 miss both; 2700 fits L (kept 1, dropped 2)
        XCTAssertEqual(V2JoinCapacity.fit(historyNewestFirst: history, render: render(base: 2400)),
                       .fits(text: String(repeating: "x", count: 2700), ecc: .l, bytes: 2700, historyKept: 1, historyDropped: 2))
        // 2200 with two kept fits M again (a smaller set is tried at M before L)
        XCTAssertEqual(V2JoinCapacity.fit(historyNewestFirst: history, render: render(base: 1900)),
                       .fits(text: String(repeating: "x", count: 2800), ecc: .l, bytes: 2800, historyKept: 3, historyDropped: 0))
        XCTAssertEqual(V2JoinCapacity.fit(historyNewestFirst: [3], render: render(base: 2000)),
                       .fits(text: String(repeating: "x", count: 2300), ecc: .m, bytes: 2300, historyKept: 1, historyDropped: 0))
        XCTAssertEqual(V2JoinCapacity.fit(historyNewestFirst: history, render: render(base: 2954)), .tooLarge)
        XCTAssertEqual(V2JoinCapacity.fit(historyNewestFirst: [Int](), render: render(base: 2953)),
                       .fits(text: String(repeating: "x", count: 2953), ecc: .l, bytes: 2953, historyKept: 0, historyDropped: 0))
        XCTAssertEqual(V2JoinCapacity.byteLength("é"), 2)
    }

    // MARK: store

    func testJoinStoreKeepsOneRecordPerBindingAndRoundTripsItsSnapshot() {
        let store = V2JoinStore()
        store.set(V2JoinPending(role: .show, chatId: "200", bindingId: "b1", targetEpoch: 2, commitId: "e1", expiresMs: 1000))
        store.set(V2JoinPending(role: .import, chatId: "300", bindingId: "b2", targetEpoch: 5, commitId: "e2", expiresMs: 2000, commitWire: "P2:x"))
        store.set(V2JoinPending(role: .show, chatId: "200", bindingId: "b1", targetEpoch: 3, commitId: "e3", expiresMs: 1500))
        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(store.get("b1")?.targetEpoch, 3)
        XCTAssertEqual(store.forChat("300")?.commitWire, "P2:x")
        XCTAssertTrue(store.isPendingUnexpired(bindingId: "b1", nowMs: 1500))
        XCTAssertFalse(store.isPendingUnexpired(bindingId: "b1", nowMs: 1501))
        XCTAssertFalse(store.isPendingUnexpired(bindingId: "nope", nowMs: 0))
        store.markExpiredRekey(bindingId: "b1", epoch: 4)
        let reloaded = V2JoinStore.fromSnapshot(store.toSnapshot())
        XCTAssertEqual(reloaded.all(), store.all())
        XCTAssertEqual(reloaded.expiredRekeyEpoch("b1"), 4)
        reloaded.delete("b1")
        XCTAssertNil(reloaded.get("b1"))
        XCTAssertEqual(reloaded.expiredRekeyEpoch("b1"), 4, "the marker outlives the record: history re-renders forever")
        XCTAssertTrue(V2JoinStore.fromSnapshot(nil).all().isEmpty)
    }

    func testBindingSnapshotWithoutTheNewFieldsStillDecodesAndOwnIdentityRoundTrips() throws {
        let own = V2OwnIdentity.fromKeys(identityPk: [UInt8](repeating: 1, count: 32), identitySk: [UInt8](repeating: 2, count: 64),
                                         encapsulationPk: [UInt8](repeating: 3, count: 32), encapsulationSk: [UInt8](repeating: 4, count: 32))
        let binding = V2Binding.freshTemplate(chatId: "200", bindingId: "b", epoch: 1, deviceRoster: ["d"], deviceKeys: [:], revision: 1, txnId: "join:b", installedAtMs: 1, ownIdentity: own, safetyCode: "0000 1111 2222")
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(V2Binding.self, from: data)
        XCTAssertEqual(decoded.ownIdentity, own)
        XCTAssertEqual(decoded.safetyCode, "0000 1111 2222")
        // a pre-3.39 record: the two keys are simply absent
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "ownIdentity")
        object.removeValue(forKey: "safetyCode")
        let old = try JSONDecoder().decode(V2Binding.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.ownIdentity)
        XCTAssertNil(old.safetyCode)
        // and every store patch carries the fields
        let store = V2Binding.BindingStore()
        store.install(binding)
        store.markVerified(chatId: "200", bindingId: "b")
        store.applyRosterCommit(chatId: "200", epoch: 2, deviceRoster: ["d", "e"], deviceKeys: [:])
        XCTAssertEqual(store.current("200")?.ownIdentity, own)
        XCTAssertEqual(store.current("200")?.safetyCode, "0000 1111 2222")
        XCTAssertEqual(store.current("200")?.epoch, 2)
        XCTAssertTrue(store.current("200")!.verified)
        // a persisted-state snapshot written before 3.39 has no `join` key at all
        var stateObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(V2PersistedState.Snapshot.empty)) as? [String: Any])
        XCTAssertNotNil(stateObject["join"])
        stateObject.removeValue(forKey: "join")
        let oldState = try JSONDecoder().decode(V2PersistedState.Snapshot.self, from: JSONSerialization.data(withJSONObject: stateObject))
        XCTAssertNil(oldState.join)
        XCTAssertTrue(V2PersistedState.load(storage: V2MemoryStorage(oldState)).joinStore.all().isEmpty)
    }

    func testOwnIdentityHelperPrefersThePerBindingIdentityAndFallsBackToTheGlobalOne() {
        let global = makeIdentity(ownUser)
        let ed = V2Suite.generateEd25519(), x = V2Suite.generateX25519()
        let own = V2OwnIdentity.fromKeys(identityPk: ed.publicKey, identitySk: ed.secretKey, encapsulationPk: x.publicKey, encapsulationSk: x.secretKey)
        let joined = V2Binding.freshTemplate(chatId: "200", bindingId: "b", epoch: 1, deviceRoster: [], deviceKeys: [:], revision: 1, txnId: "join:b", installedAtMs: 1, ownIdentity: own)
        let paired = V2Binding.freshTemplate(chatId: "300", bindingId: "c", epoch: 1, deviceRoster: [], deviceKeys: [:], revision: 1, txnId: "t", installedAtMs: 1)
        XCTAssertEqual(V2OwnIdentity.identity(for: joined, fallback: global).publicKey, ed.publicKey)
        XCTAssertEqual(V2OwnIdentity.identity(for: joined, fallback: global).encapsulationSk, x.secretKey)
        XCTAssertEqual(V2OwnIdentity.identity(for: joined, fallback: global).userId, ownUser)
        XCTAssertEqual(V2OwnIdentity.ownDeviceId(for: joined, fallback: global), Base64Url.encode(V2Suite.sha256(ed.publicKey)))
        XCTAssertEqual(V2OwnIdentity.identity(for: paired, fallback: global).publicKey, global.publicKey)
        XCTAssertEqual(V2OwnIdentity.ownDeviceId(for: nil, fallback: global), deviceId(global))
        let corrupt = V2Binding.freshTemplate(chatId: "200", bindingId: "b", epoch: 1, deviceRoster: [], deviceKeys: [:], revision: 1, txnId: "join:b", installedAtMs: 1,
                                              ownIdentity: V2Binding.OwnIdentity(deviceId: "x", identityPk: "!!", identitySk: "!!", encapsulationPk: "!!", encapsulationSk: "!!"))
        XCTAssertEqual(V2OwnIdentity.identity(for: corrupt, fallback: global).publicKey, global.publicKey, "a corrupt record never crashes a receive path")
    }

    func testDeviceCodeOfTheJoinedDeviceComesFromItsEncapsulationKey() throws {
        let x = V2Suite.generateX25519()
        XCTAssertEqual(V2JoinCoordinator.deviceCode(encapsulationPkB64: Base64Url.encode(x.publicKey), fallback: "abcdefghij"),
                       try DeviceIdentity.derive(x25519Pk: x.publicKey).deviceCode)
        XCTAssertEqual(V2JoinCoordinator.deviceCode(encapsulationPkB64: "AAAA", fallback: "abcdefghij"), "abcdefg")
    }
}
