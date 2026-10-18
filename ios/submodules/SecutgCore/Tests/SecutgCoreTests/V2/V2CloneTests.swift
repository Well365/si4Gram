import XCTest
@testable import SecutgCore

/// PLAN.md 3.39.13 — the V2Q clone payload, its refusals, the coordinator's two sides, and the sent-event log that
/// tells this device's own P2 echo from its clone's.
final class V2CloneTests: XCTestCase {
    private let code = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private let nonce = [UInt8](0..<24)

    private struct Keys {
        let signing: V2Suite.KeyPair
        let x: V2Suite.KeyPair
        var entry: V2JoinPayload.RosterEntry {
            return V2JoinPayload.RosterEntry(identityPk: Base64Url.encode(signing.publicKey), encapsulationPk: Base64Url.encode(x.publicKey))
        }
        var own: V2JoinPayload.Own {
            return V2JoinPayload.Own(identitySeed: Base64Url.encode(Array(signing.secretKey.prefix(32))), encapsulationSk: Base64Url.encode(x.secretKey))
        }
    }

    private func keys() -> Keys {
        return Keys(signing: V2Suite.generateEd25519(), x: V2Suite.generateX25519())
    }

    private func payload(o: Keys, p: Keys, own: V2JoinPayload.Own? = nil, epoch: Int = 2, masters: Int = 2, expiresMs: Int64 = 1_000_000, peer: String = "200") -> V2JoinPayload.Payload {
        let roster = [o.entry, p.entry].sorted { $0.deviceId < $1.deviceId }
        return V2JoinPayload.Payload(
            peerUserId: peer, bindingId: Base64Url.encode([UInt8](repeating: 7, count: 32)), epoch: epoch, safetyCode: "123456789012",
            roster: roster, masters: (0..<masters).map { Base64Url.encode([UInt8](repeating: UInt8(0x40 + epoch - $0), count: 32)) },
            own: own ?? o.own, expiresMs: expiresMs)
    }

    // MARK: payload

    func testPayloadRoundTripsInTheFixedOrder() throws {
        let p = payload(o: keys(), p: keys())
        let text = V2JoinPayload.serialize(p)
        XCTAssertTrue(text.hasPrefix(#"{"v":2,"kind":"v2clone","peer_user_id":"200","binding_id":"#), text)
        XCTAssertTrue(text.contains(#","own":{"identity_seed":""#), text)
        XCTAssertTrue(text.hasSuffix(#""expires_ms":1000000}"#), text)
        XCTAssertFalse(text.contains(" "))
        XCTAssertEqual(V2JoinPayload.parse(text), .ok(p))
    }

    func testOwnKeysOutsideTheRosterAreMalformed() {
        let o = keys(), p = keys(), stranger = keys()
        XCTAssertEqual(V2JoinPayload.parse(V2JoinPayload.serialize(payload(o: o, p: p, own: stranger.own))), .malformed)
        // the right identity with somebody else's encapsulation key cannot open the roster's packages either
        let mixed = V2JoinPayload.Own(identitySeed: o.own.identitySeed, encapsulationSk: stranger.own.encapsulationSk)
        XCTAssertEqual(V2JoinPayload.parse(V2JoinPayload.serialize(payload(o: o, p: p, own: mixed))), .malformed)
    }

    func testStructuralRefusals() {
        let o = keys(), p = keys()
        let good = V2JoinPayload.serialize(payload(o: o, p: p))
        // extra field, reordered fields, unsorted roster, too many masters, a single-device roster
        XCTAssertEqual(V2JoinPayload.parse(good.replacingOccurrences(of: #"}"#, with: #","x":1}"#, options: .backwards, range: good.range(of: "}", options: .backwards))), .malformed)
        XCTAssertEqual(V2JoinPayload.parse(good.replacingOccurrences(of: #"{"v":2,"kind":"v2clone""#, with: #"{"kind":"v2clone","v":2"#)), .malformed)
        let roster = [o.entry, p.entry].sorted { $0.deviceId < $1.deviceId }
        let unsorted = V2JoinPayload.Payload(peerUserId: "200", bindingId: Base64Url.encode([UInt8](repeating: 7, count: 32)), epoch: 1, safetyCode: "1",
                                            roster: roster.reversed(), masters: [Base64Url.encode([UInt8](repeating: 1, count: 32))], own: o.own, expiresMs: 1)
        XCTAssertEqual(V2JoinPayload.parse(V2JoinPayload.serialize(unsorted)), .malformed)
        XCTAssertEqual(V2JoinPayload.parse(V2JoinPayload.serialize(payload(o: o, p: p, epoch: 1, masters: 2))), .malformed)
        let alone = V2JoinPayload.Payload(peerUserId: "200", bindingId: Base64Url.encode([UInt8](repeating: 7, count: 32)), epoch: 1, safetyCode: "1",
                                         roster: [o.entry], masters: [Base64Url.encode([UInt8](repeating: 1, count: 32))], own: o.own, expiresMs: 1)
        XCTAssertEqual(V2JoinPayload.parse(V2JoinPayload.serialize(alone)), .malformed)
    }

    func testTheRetiredFormatIsOldVersion() {
        XCTAssertEqual(V2JoinPayload.parse(#"{"v":1,"kind":"v2join"}"#), .oldVersion)
        XCTAssertEqual(V2JoinPayload.parse(#"{"v":1}"#), .oldVersion)
        XCTAssertEqual(V2JoinPayload.parse(#"{"kind":"v2join","v":2}"#), .oldVersion)
        XCTAssertEqual(V2JoinPayload.parse(#"[1]"#), .malformed)
    }

    // MARK: envelope

    func testOpenReasonsInWebOrder() throws {
        let o = keys(), p = keys()
        let pay = payload(o: o, p: p, expiresMs: 1_000_000)
        let text = try XCTUnwrap(V2Join.build(pay, code: code, nonce: nonce))
        XCTAssertTrue(text.hasPrefix("V2Q:" + code + ":"))
        let ctx = V2Join.OpenContext(chatId: "200", nowMs: 1_000_000)
        guard case let .success(opened) = V2Join.open(text, context: ctx) else { return XCTFail("did not open") }
        XCTAssertEqual(opened.payload, pay)
        // the grace is 2 minutes; past it, expired — before wrong_chat and already_paired
        XCTAssertEqual(open(text, chat: "999", now: 1_000_000 + V2JoinText.expiryGraceMs + 1, paired: true), "expired")
        XCTAssertEqual(open(text, chat: "200", now: 1_000_000 + V2JoinText.expiryGraceMs), "ok")
        XCTAssertEqual(open(text, chat: "999", now: 1, paired: true), "wrong_chat")
        XCTAssertEqual(open(text, chat: "200", now: 1, paired: true), "already_paired")
        // syntax, a wrong code, the retired AAD, the retired plaintext
        XCTAssertEqual(open("V2Q:" + code + ":short:xx", chat: "200", now: 1), "malformed")
        let otherCode = "Z" + code.dropFirst()
        let wrongCode = text.replacingOccurrences(of: code, with: otherCode)
        XCTAssertEqual(open(wrongCode, chat: "200", now: 1), "undecryptable")
        let legacyAad = try XCTUnwrap(V2Join.seal(V2JoinPayload.serialize(pay), code: code, nonce: nonce, aad: V2JoinText.legacyAad))
        XCTAssertEqual(open(legacyAad, chat: "200", now: 1), "old_version")
        let legacyPlain = try XCTUnwrap(V2Join.seal(#"{"v":1,"kind":"v2join","peer_user_id":"200"}"#, code: code, nonce: nonce))
        XCTAssertEqual(open(legacyPlain, chat: "200", now: 1), "old_version")
        let notJson = try XCTUnwrap(V2Join.seal("not json", code: code, nonce: nonce))
        XCTAssertEqual(open(notJson, chat: "200", now: 1), "malformed")
    }

    private func open(_ text: String, chat: String, now: Int64, paired: Bool = false) -> String {
        switch V2Join.open(text, context: V2Join.OpenContext(chatId: chat, nowMs: now, hasCurrentBinding: paired)) {
        case .success: return "ok"
        case let .failure(error): return error.rawValue
        }
    }

    func testCapacityTwoDevicesFitsMAndHistoryIsTrimmedNewestFirst() throws {
        let o = keys(), p = keys()
        let history = (1..<60).map { Base64Url.encode([UInt8](repeating: UInt8($0), count: 32)) }
        let fit = try V2JoinCapacity.fit(historyNewestFirst: history) { kept in
            let pay = V2JoinPayload.Payload(peerUserId: "200", bindingId: Base64Url.encode([UInt8](repeating: 7, count: 32)), epoch: 60, safetyCode: "123456789012",
                                            roster: [o.entry, p.entry].sorted { $0.deviceId < $1.deviceId },
                                            masters: [Base64Url.encode([UInt8](repeating: 0, count: 32))] + kept, own: o.own, expiresMs: 1_790_000_600_000)
            return try XCTUnwrap(V2Join.build(pay, code: code, nonce: nonce))
        }
        guard case let .fits(text, ecc, bytes, kept, dropped) = fit else { return XCTFail("\(fit)") }
        XCTAssertEqual(ecc, .l, "history beats the error-correction level")
        XCTAssertLessThanOrEqual(bytes, 2953)
        XCTAssertEqual(kept + dropped, history.count)
        XCTAssertGreaterThan(kept, 20)
        guard case let .success(opened) = V2Join.open(text, context: V2Join.OpenContext(chatId: "200", nowMs: 0)) else { return XCTFail("open") }
        XCTAssertEqual(opened.payload.masters.count, 1 + kept)
        XCTAssertEqual(Array(opened.payload.masters.dropFirst()), Array(history.prefix(kept)))
    }

    // MARK: sent-event log

    func testSentEventLogKeepsTheNewestAndSurvivesASnapshot() {
        let log = V2SentEventStore()
        for i in 0..<(V2SentEventStore.capacity + 10) { log.record(eventId: "e\(i)", createdMs: 1_000 + Int64(i)) }
        XCTAssertEqual(log.count, V2SentEventStore.capacity)
        XCTAssertFalse(log.contains("e0"))
        XCTAssertFalse(log.contains("e9"))
        XCTAssertTrue(log.contains("e10"))
        XCTAssertTrue(log.contains("e\(V2SentEventStore.capacity + 9)"))
        let restored = V2SentEventStore.fromSnapshot(log.toSnapshot())
        XCTAssertEqual(restored.toSnapshot(), log.toSnapshot())
    }

    /// A snapshot written before 3.39.13 carries `join` (3.39.12's `join_pending`) and no `sentEvents`: it still decodes,
    /// the old record is ignored, the log starts empty.
    func testAPre3913SnapshotDecodes() throws {
        let data = try JSONEncoder().encode(V2PersistedState.Snapshot.empty)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "sentEvents")
        object["join"] = ["pending": [["role": "show", "chatId": "200", "bindingId": "x", "targetEpoch": 2, "commitId": "c", "expiresMs": 1]], "expiredRekeys": [:]]
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let snapshot = try JSONDecoder().decode(V2PersistedState.Snapshot.self, from: legacy)
        XCTAssertNil(snapshot.sentEvents)
        XCTAssertEqual(V2PersistedState.load(storage: V2MemoryStorage(snapshot)).sentEventStore.count, 0)
    }

    /// This device's own P2 from before 3.39.13 was never recorded, so re-rendering it reads as the clone's — which the
    /// clone handlers tolerate: an old own REKEY is already applied and keeps the own 换新密钥 line, the binding stays.
    func testAnUnrecordedOwnRekeyFromBeforeTheUpgradeIsTolerated() throws {
        func device(_ key: String, _ userId: String) {
            let ed = V2Suite.generateEd25519(), x = V2Suite.generateX25519()
            let id = KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
            V2RuntimeRegistry.shared.set(V2Runtime(identity: V2IdentityBridge.identity(userId: userId, from: id)!, persisted: V2PersistedState.load(storage: V2MemoryStorage())), for: key)
        }
        defer { V2RuntimeRegistry.shared.reset(for: "legacy-A"); V2RuntimeRegistry.shared.reset(for: "legacy-B") }
        device("legacy-A", "100")
        device("legacy-B", "200")
        guard case let .sent(invite) = V2PairingDispatch.startPairing(accountKey: "legacy-A", chatId: "200", targetUser: "200"),
              case let .invited(_, _, cached) = V2PairingDispatch.handleIncoming(accountKey: "legacy-B", chatId: "100", wireText: invite, isOutgoing: false),
              case let .sent(accept) = V2PairingDispatch.acceptInvite(accountKey: "legacy-B", chatId: "100", inviteWire: cached),
              case let .progressed(select?) = V2PairingDispatch.handleIncoming(accountKey: "legacy-A", chatId: "200", wireText: accept, isOutgoing: false),
              case let .progressed(confirm?) = V2PairingDispatch.handleIncoming(accountKey: "legacy-B", chatId: "100", wireText: select, isOutgoing: false),
              case let .progressed(ready?) = V2PairingDispatch.handleIncoming(accountKey: "legacy-A", chatId: "200", wireText: confirm, isOutgoing: false) else {
            return XCTFail("pairing")
        }
        _ = V2PairingDispatch.handleIncoming(accountKey: "legacy-B", chatId: "100", wireText: ready, isOutgoing: false)
        let a = try XCTUnwrap(V2RuntimeRegistry.shared.runtime(for: "legacy-A"))
        // built straight on the processor, as before 3.39.13 — nothing recorded
        let legacy = try XCTUnwrap(a.roster.rekey("200"))
        XCTAssertFalse(a.persisted.sentEventStore.contains(try XCTUnwrap(V2Envelope.parse(prefix: V2Messages.prefix, text: legacy)?.eventId)))
        let epoch = a.pairing.bindingStore.current("200")?.epoch
        XCTAssertEqual(V2PairingDispatch.handleIncoming(accountKey: "legacy-A", chatId: "200", wireText: legacy, isOutgoing: true), .ignored(reason: "own_echo:roster_commit"))
        XCTAssertEqual(a.pairing.bindingStore.current("200")?.epoch, epoch)
    }

    // MARK: the coordinator, alone

    func testShowingWritesNothingAndRefusesWithoutASendableBinding() {
        let storage = V2MemoryStorage()
        let identity = V2Identity(userId: "100", publicKey: V2Suite.generateEd25519().publicKey, secretKey: V2Suite.generateEd25519().secretKey,
                                  encapsulationPk: V2Suite.generateX25519().publicKey, encapsulationSk: V2Suite.generateX25519().secretKey)
        let runtime = V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: storage), now: { 1 })
        XCTAssertEqual(runtime.join.prepareShare(chatId: "200"), .notPaired)
        XCTAssertEqual(runtime.join.inspect("V2Q:nonsense", chatId: "200"), .refused(.malformed))
    }
}
