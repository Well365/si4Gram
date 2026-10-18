import XCTest
@testable import SecutgCore

/// What an encrypted chat leaves on disk (PLAN.md 3.19) — the iOS counterpart of Web A's `persist.test.ts`.
final class PersistTests: XCTestCase {
    let wire = "E1:aab2.20260913:bm9uY2Vub25jZW5vbmNlbm9uY2Vub25j:Y2lwaGVydGV4dGNpcGhlcnRleHQ"
    let entities = [E1Entity(type: "MessageEntityBold", offset: 0, length: 4)]

    func testTheWordsAreSwappedBackForTheEnvelopeTheyCameOutOf() {
        let stored = SecutgPersist.storedForm(plaintext: "nine, the usual place", entities: entities, wire: wire, keepsCiphertextLocally: true)
        XCTAssertTrue(stored.isSealed)
        XCTAssertEqual(stored.text, wire)
        XCTAssertFalse(stored.text.contains("usual place"))
        // the entities describe the words, so they travel inside the envelope rather than beside it
        XCTAssertEqual(stored.entities, [])
    }

    func testAChatThatDoesNotEncryptIsWrittenExactlyAsItIs() {
        let stored = SecutgPersist.storedForm(plaintext: "hello", entities: entities, wire: wire, keepsCiphertextLocally: false)
        XCTAssertFalse(stored.isSealed)
        XCTAssertEqual(stored.text, "hello")
        XCTAssertEqual(stored.entities, entities)
    }

    /// The one failure that would lose a message: sealing away a text whose envelope is not a usable envelope
    /// would leave nothing that any key could ever open.
    func testAnUnusableEnvelopeIsNeverSubstituted() {
        for bad in ["", "E1:", "not an envelope", "E1:aab2.20260913:onlytwofields"] {
            let stored = SecutgPersist.storedForm(plaintext: "hello", entities: nil, wire: bad, keepsCiphertextLocally: true)
            XCTAssertFalse(stored.isSealed, bad)
            XCTAssertEqual(stored.text, "hello", bad)
        }
    }

    func testNilEntitiesBecomeAnEmptyList() {
        XCTAssertEqual(SecutgPersist.storedForm(plaintext: "hello", entities: nil, wire: wire, keepsCiphertextLocally: false).entities, [])
    }

    // MARK: the per-session cache

    func testTheWordsAreReadBackOutOfTheCacheByTheirEnvelope() {
        let cache = SecutgPlaintextCache()
        cache.remember(wire: wire, text: "nine, the usual place", entities: entities)
        XCTAssertEqual(cache.opened(wire: wire), SecutgPlaintextCache.Opened(text: "nine, the usual place", entities: entities))
        XCTAssertNil(cache.opened(wire: "E1:other.20260913:n:c"))
    }

    func testForgettingLeavesNothingBehind() {
        let cache = SecutgPlaintextCache()
        cache.remember(wire: wire, text: "nine, the usual place", entities: [])
        cache.forgetAll()
        XCTAssertNil(cache.opened(wire: wire))
        XCTAssertEqual(cache.count, 0)
    }

    func testTheCacheIsBoundedAndEvictsTheOldestFirst() {
        let cache = SecutgPlaintextCache(limit: 3)
        for i in 0..<5 { cache.remember(wire: "w\(i)", text: "t\(i)", entities: []) }
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.opened(wire: "w0"))
        XCTAssertNil(cache.opened(wire: "w1"))
        XCTAssertEqual(cache.opened(wire: "w4")?.text, "t4")
        // an eviction costs one decryption on the next read, never a wrong answer
        XCTAssertEqual(cache.opened(wire: "w2")?.text, "t2")
    }

    func testRememberingTheSameEnvelopeTwiceDoesNotGrowTheCache() {
        let cache = SecutgPlaintextCache(limit: 2)
        cache.remember(wire: wire, text: "first", entities: [])
        cache.remember(wire: wire, text: "first", entities: [])
        XCTAssertEqual(cache.count, 1)
    }

    // MARK: the setting

    func testTheSettingIsOnUntilItIsTurnedOff() {
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { 0 }, epochDays: 1, epochTolerance: 1)
        XCTAssertTrue(ring.getLocalCiphertext())
        // …but only an encrypting chat is affected by it
        XCTAssertFalse(ring.keepsCiphertextLocally("-100123"))
        ring.setChatEncryption(chatId: "-100123", enabled: true)
        XCTAssertTrue(ring.keepsCiphertextLocally("-100123"))
        XCTAssertFalse(ring.keepsCiphertextLocally("456"))

        ring.setLocalCiphertext(false)
        XCTAssertFalse(ring.keepsCiphertextLocally("-100123"))
    }

    func testTheSettingSurvivesAReload() {
        let storage = MemoryKeyRingStorage()
        let ring = KeyRing(storage: storage, clock: { 0 }, epochDays: 1, epochTolerance: 1)
        ring.setLocalCiphertext(false)
        let reloaded = KeyRing(storage: MemoryKeyRingStorage(SnapshotCodec.decode(SnapshotCodec.encode(storage.saved!))), clock: { 0 }, epochDays: 1, epochTolerance: 1)
        XCTAssertFalse(reloaded.getLocalCiphertext())
    }

    // MARK: the whole round trip

    /// What a restart actually does: the cache is empty, the database holds the envelope, and the words have to come
    /// back out of it. This is the part Web A never needed — it keeps every message in memory — and the reason the
    /// swap on this client is "store the envelope, open it on read" rather than "store the envelope, reload later".
    func testAfterARestartTheWordsComeBackOutOfTheStoredEnvelope() throws {
        let v = Vectors.load("e1")
        let keyId = v["key_id"] as! String
        let sessionKey = Vectors.hex(v["session_key_hex"] as! String)
        let wire = try E1Codec.encrypt(text: "nine, the usual place", entities: entities, keyId: keyId, sessionKey: sessionKey)

        let stored = SecutgPersist.storedForm(plaintext: "nine, the usual place", entities: entities, wire: wire, keepsCiphertextLocally: true)
        XCTAssertEqual(stored.text, wire)

        // a fresh process: nothing remembered, so the envelope is opened again
        let cache = SecutgPlaintextCache()
        XCTAssertNil(cache.opened(wire: stored.text))
        let opened = E1Codec.decrypt(wire: stored.text) { $0 == keyId ? sessionKey : nil }
        XCTAssertTrue(opened.ok)
        XCTAssertEqual(opened.text, "nine, the usual place")
        XCTAssertEqual(opened.entities, entities)

        cache.remember(wire: stored.text, text: opened.text!, entities: opened.entities ?? [])
        XCTAssertEqual(cache.opened(wire: stored.text)?.text, "nine, the usual place")
    }

    /// The key is gone — a wipe, an unpair, a rotated-away master. The stored envelope is untouched and unreadable,
    /// which is the honest answer and the one the PLAN.md 3.17 notice already knows how to say.
    func testAnEnvelopeWhoseKeyIsGoneStaysSealedRatherThanBecomingNonsense() throws {
        let v = Vectors.load("e1")
        let keyId = v["key_id"] as! String
        let sessionKey = Vectors.hex(v["session_key_hex"] as! String)
        let wire = try E1Codec.encrypt(text: "nine, the usual place", entities: nil, keyId: keyId, sessionKey: sessionKey)
        let opened = E1Codec.decrypt(wire: wire) { _ in nil }
        XCTAssertFalse(opened.ok)
        XCTAssertEqual(opened.reason, .unknownKey)
    }

    /// A ring written before this setting existed has no field for it, and the safe reading of that is "on" —
    /// the same rule the wipe confirmation uses: anything but an explicit `false`.
    func testAnOlderSnapshotDefaultsToOn() {
        let older = SnapshotCodec.decode(Data("{\"v\":1,\"masters\":{}}".utf8))
        XCTAssertEqual(older?.localCiphertext, true)
    }

    // MARK: PLAN.md 3.44 — a v2 row (private chat or group, `E2:`) seals on the same terms

    private var v2Devices: [V2SealedDevice] = []

    private func v2Device(_ userId: String, _ key: String) -> V2SealedDevice {
        let device = V2SealedDevice(userId: userId, key: key)
        v2Devices.append(device)
        return device
    }

    override func tearDown() {
        v2Devices.forEach { $0.forget() }
        v2Devices = []
        super.tearDown()
    }

    private func v2Wire(from: V2SealedDevice, chat: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let outgoing = V2Dispatch.prepareOutgoingText(accountKey: from.key, chatId: chat, text: text)
        guard case .sent(let wire) = outgoing else {
            XCTFail("expected an E2 send, got \(outgoing)", file: file, line: line)
            return ""
        }
        return wire
    }

    /// (a) incoming and (b) our own sent copy: the envelope stands in for the words while the switch is on, the words
    /// are stored while it is off — the one decision, from both doors.
    func testAV2EnvelopeIsSwappedInForTheWordsWhenTheSettingIsOnAndNotWhenItIsOff() {
        let a = v2Device("100", "persist-A")
        let b = v2Device("200", "persist-B")
        let chats = V2SealedFixture.pair(a, b)
        let wire = v2Wire(from: a, chat: chats.chatA, "nine, the usual place")

        let received = SecutgPersist.storedForm(
            plaintext: "nine, the usual place", entities: nil, wire: wire,
            keepsCiphertextLocally: V2Dispatch.keepsCiphertextLocally(accountKey: b.key, chatId: chats.chatB, localCiphertext: true))
        XCTAssertTrue(received.isSealed)
        XCTAssertEqual(received.text, wire)
        XCTAssertFalse(received.text.contains("usual place"))
        XCTAssertEqual(received.entities, [])

        let sent = SecutgPersist.storedForm(
            plaintext: "nine, the usual place", entities: [], wire: wire,
            keepsCiphertextLocally: V2Dispatch.keepsCiphertextLocally(accountKey: a.key, chatId: chats.chatA, localCiphertext: true))
        XCTAssertTrue(sent.isSealed)
        XCTAssertEqual(sent.text, wire)

        for (device, chat) in [(b, chats.chatB), (a, chats.chatA)] {
            let off = SecutgPersist.storedForm(
                plaintext: "nine, the usual place", entities: nil, wire: wire,
                keepsCiphertextLocally: V2Dispatch.keepsCiphertextLocally(accountKey: device.key, chatId: chat, localCiphertext: false))
            XCTAssertFalse(off.isSealed)
            XCTAssertEqual(off.text, "nine, the usual place")
        }
    }

    func testAV2GroupRowSealsOnTheSameTerms() {
        let creator = v2Device("100", "persist-A")
        let member = v2Device("200", "persist-B")
        let group = V2SealedFixture.group(creator: creator, member: member)
        let wire = v2Wire(from: creator, chat: group, "hello group")
        let on = SecutgPersist.storedForm(
            plaintext: "hello group", entities: nil, wire: wire,
            keepsCiphertextLocally: V2Dispatch.keepsCiphertextLocally(accountKey: member.key, chatId: group, localCiphertext: true))
        XCTAssertTrue(on.isSealed)
        XCTAssertEqual(on.text, wire)
        let off = SecutgPersist.storedForm(
            plaintext: "hello group", entities: nil, wire: wire,
            keepsCiphertextLocally: V2Dispatch.keepsCiphertextLocally(accountKey: member.key, chatId: group, localCiphertext: false))
        XCTAssertFalse(off.isSealed)
        XCTAssertEqual(off.text, "hello group")
    }

    /// The same rule as for `E1:`: words that merely begin with the prefix are never sealed away behind themselves.
    func testTextThatMerelyLooksLikeAV2WireIsNeverSubstituted() {
        for bad in ["E2:", "E2: hi", "E2:not base64!"] {
            let stored = SecutgPersist.storedForm(plaintext: "hello", entities: nil, wire: bad, keepsCiphertextLocally: true)
            XCTAssertFalse(stored.isSealed, bad)
            XCTAssertEqual(stored.text, "hello", bad)
        }
        XCTAssertTrue(SecutgPersist.isEnvelope(wire))
        XCTAssertTrue(SecutgPersist.isEnvelope("E2:eyJoZWFkZXIiOnt9fQ"))
        XCTAssertFalse(SecutgPersist.isEnvelope("P2:eyJoZWFkZXIiOnt9fQ"))
    }

    /// (c) A restart: the cache is empty, the runtime is rebuilt from what it persisted, and the words come back out
    /// of the stored `E2:` — including when this very process had already opened that wire once.
    func testAfterARestartTheWordsComeBackOutOfAStoredV2Envelope() {
        let a = v2Device("100", "persist-A")
        let b = v2Device("200", "persist-B")
        let chats = V2SealedFixture.pair(a, b)
        let wire = v2Wire(from: a, chat: chats.chatA, "nine, the usual place")
        XCTAssertEqual(V2Dispatch.decryptIncomingText(accountKey: b.key, chatId: chats.chatB, wireText: wire), .decrypted(text: "nine, the usual place"))
        let stored = SecutgPersist.storedForm(plaintext: "nine, the usual place", entities: nil, wire: wire, keepsCiphertextLocally: true)
        XCTAssertEqual(stored.text, wire)

        let cache = SecutgPlaintextCache()
        cache.remember(wire: stored.text, text: "nine, the usual place", entities: [])
        XCTAssertEqual(cache.opened(wire: stored.text)?.text, "nine, the usual place")

        // the same process, the cache emptied (a key event, an eviction): opened again, not refused as a replay
        cache.forgetAll()
        XCTAssertEqual(V2Dispatch.openStoredText(accountKey: b.key, chatId: chats.chatB, wireText: stored.text), .decrypted(text: "nine, the usual place"))

        // a fresh process: nothing remembered anywhere
        b.restart()
        XCTAssertNil(cache.opened(wire: stored.text))
        guard case .decrypted(let opened) = V2Dispatch.openStoredText(accountKey: b.key, chatId: chats.chatB, wireText: stored.text) else {
            return XCTFail("the stored envelope must open again after a restart")
        }
        XCTAssertEqual(opened, "nine, the usual place")
        cache.remember(wire: stored.text, text: opened, entities: [])
        XCTAssertEqual(cache.opened(wire: stored.text)?.text, "nine, the usual place")
    }

    /// (e) The binding is not on this device. The stored envelope is untouched and unreadable, which is the honest
    /// answer — the PLAN.md 3.17 "no key here" line, never the reason code and never the base64.
    func testAV2EnvelopeWhoseBindingIsNotHereStaysSealedRatherThanBecomingNonsense() {
        let a = v2Device("100", "persist-A")
        let b = v2Device("200", "persist-B")
        let c = v2Device("300", "persist-C")
        let chats = V2SealedFixture.pair(a, b)
        let wire = v2Wire(from: a, chat: chats.chatA, "nine, the usual place")
        let outcome = V2Dispatch.openStoredText(accountKey: c.key, chatId: a.userId, wireText: wire)
        guard case .failed(let reason) = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertEqual(V2Dispatch.storedFailureDetail(reason: reason), DecryptResult.Reason.unknownKey.rawValue)
    }
}
