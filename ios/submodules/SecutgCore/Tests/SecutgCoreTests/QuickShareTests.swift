import XCTest
@testable import SecutgCore

/// PLAN.md 3.14.1: one QR code carrying one chat's keys (Saved Messages / groups) to another device of the same user.
final class QuickShareTests: XCTestCase {
    let now: Int64 = 1_789_214_400_000   // 2026-09-13 12:00 UTC, in ms
    var nowSeconds: Int64 { return now / 1000 }
    let group = "-1001234567890"
    let plainCode = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    /// shape-valid container: 32-char nonce, 22-char ciphertext
    let fakeBundle = "K1:1:" + String(repeating: "A", count: 32) + ":" + String(repeating: "B", count: 22)

    func ring() -> KeyRing {
        return KeyRing(storage: MemoryKeyRingStorage(), clock: { self.now }, epochDays: 1, epochTolerance: 1)
    }

    /// `yyyyMMdd` (UTC) of 2026-09-13 minus `daysBefore` days
    func dayLabel(daysBefore: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(nowSeconds - Int64(daysBefore) * 86_400)))
    }

    /// A group whose key was rebuilt `rebuilds` times: every earlier master stays in its `chatMasterHistory`.
    func groupRing(rebuilds: Int) throws -> (KeyRing, current: String, historyNewestFirst: [String]) {
        let source = ring()
        try source.setIdentity(try Rekey.generateIdentity())
        var ids: [String] = []
        for index in 0...rebuilds {
            let masterId = try source.addMaster(KeyDerivation.generateMasterKey())
            try source.setChatMaster(chatId: group, masterId: masterId, label: dayLabel(daysBefore: rebuilds - index))
            ids.append(masterId)
        }
        source.setChatEncryption(chatId: group, enabled: true)
        let current = ids.removeLast()
        let kept = Array(ids.suffix(KeyRing.maxMasterHistory - 1))
        return (source, current, kept.reversed())
    }

    func build(_ source: KeyRing, code: String = TransferCode.generate(), maxBytes: Int = QuickShare.maxQrBytes) throws -> QuickShare.Outcome {
        let base = source.exportChatsSnapshot(chatIds: [group], withIdentity: false, includeDeviceLabels: false)
        return try QuickShare.build(
            chatId: group, base: base, historyNewestFirst: QuickShare.history(full: source.snapshot(), chatId: group, base: base),
            createdAt: nowSeconds, device: "test", code: code, maxBytes: maxBytes)
    }

    func opened(_ text: String) throws -> TransferPayload {
        switch QuickShare.open(text) {
        case let .success(value): return value.payload
        case let .failure(error): throw error
        }
    }

    // MARK: wire shape

    func testComposeWritesCanonicalCodeAndVerbatimContainer() throws {
        let formatted = TransferCode.format(plainCode).lowercased()
        XCTAssertEqual(QuickShare.compose(code: formatted, bundle: fakeBundle), "K1Q:\(plainCode):\(fakeBundle)")
        XCTAssertNil(QuickShare.compose(code: "short", bundle: fakeBundle))
        XCTAssertNil(QuickShare.compose(code: plainCode, bundle: "K1:1:abc:def"))
        XCTAssertNil(QuickShare.compose(code: plainCode, bundle: "secutg://key?x"))
    }

    func testParseIsStrictAboutCodeContainerAndPrefix() {
        let good = "K1Q:\(plainCode):\(fakeBundle)"
        XCTAssertEqual(QuickShare.parse(good), QuickShare.Parsed(code: plainCode, bundle: fakeBundle))
        XCTAssertEqual(QuickShare.parse("  \(good)\n")?.code, plainCode)
        XCTAssertTrue(QuickShare.isQuickShare(good))
        XCTAssertNil(QuickShare.parse("K1Q:\(TransferCode.format(plainCode)):\(fakeBundle)"))
        XCTAssertNil(QuickShare.parse("K1Q:\(plainCode.lowercased()):\(fakeBundle)"))
        XCTAssertNil(QuickShare.parse("K1Q:\(plainCode.replacingOccurrences(of: "1", with: "I")):\(fakeBundle)"))
        XCTAssertNil(QuickShare.parse("K1Q:\(plainCode.dropLast()):\(fakeBundle)"))
        XCTAssertNil(QuickShare.parse("K1Q:\(plainCode)0:\(fakeBundle)"))
        XCTAssertNil(QuickShare.parse("K1Q:\(plainCode):"))
        XCTAssertNil(QuickShare.parse("K1Q:\(plainCode)\(fakeBundle)"))
        XCTAssertNil(QuickShare.parse("K1Q:\(plainCode):K1:2:" + String(repeating: "A", count: 32) + ":" + String(repeating: "B", count: 22)))
        XCTAssertNil(QuickShare.parse("K1Q:\(plainCode):K1:1:" + String(repeating: "A", count: 31) + ":" + String(repeating: "B", count: 22)))
        XCTAssertNil(QuickShare.parse("K1Q:\(plainCode):K1:1:" + String(repeating: "A", count: 32) + ":" + String(repeating: "+", count: 22)))
        XCTAssertNil(QuickShare.parse(fakeBundle))
        XCTAssertNil(QuickShare.parse("k1q:\(plainCode):\(fakeBundle)"))
        XCTAssertNil(QuickShare.parse(""))
        XCTAssertFalse(QuickShare.isQuickShare(fakeBundle))
    }

    /// The existing classifier is left alone: a K1Q text is not a bare `K1:` file, and the cross-client `k1`
    /// vectors keep meaning what they meant.
    func testClassifierDoesNotMistakeQuickShareForAK1File() {
        XCTAssertEqual(ImportText.classify("K1Q:\(plainCode):\(fakeBundle)"), .unknown)
    }

    // MARK: round trip

    func testFullRoundTripCarriesTheChatAndItsHistoryWithoutIdentity() throws {
        let (source, current, history) = try groupRing(rebuilds: 2)
        let outcome = try build(source)
        guard case let .full(text, count) = outcome else { return XCTFail("expected full, got \(outcome)") }
        XCTAssertEqual(count, 3)
        XCTAssertTrue(text.hasPrefix("K1Q:"))
        XCTAssertLessThanOrEqual(QuickShare.byteCount(text), QuickShare.maxQrBytes)
        XCTAssertFalse(text.contains(current))

        let payload = try opened(text)
        XCTAssertEqual(payload.scope, .chat)
        XCTAssertEqual(payload.chatIds, [group])
        XCTAssertEqual(payload.snapshot.chatMasters[group], current)
        XCTAssertEqual(Set(payload.snapshot.masters.keys), Set([current] + history))
        XCTAssertNil(payload.snapshot.identityEd25519Sk)
        XCTAssertNil(payload.snapshot.identityX25519Sk)
        XCTAssertTrue(payload.snapshot.deviceLabels.isEmpty)
        XCTAssertFalse(TransferBundle.summarize(payload, nowSeconds: nowSeconds).hasIdentity)

        // and it goes through the ordinary 3.14 merge unchanged
        let target = ring()
        let merged = target.mergeSnapshot(payload.snapshot)
        XCTAssertEqual(merged.boundChats, [group])
        XCTAssertEqual(target.snapshot().chatMasters[group], current)
        for masterId in history { XCTAssertNotNil(target.masterKey(for: masterId)) }
    }

    func testRefusalsAreMalformedUndecryptableOrWrongScope() throws {
        let (source, _, _) = try groupRing(rebuilds: 0)
        guard case let .full(text, _) = try build(source), let parsed = QuickShare.parse(text) else { return XCTFail("expected full") }
        let otherCode = TransferCode.generate().replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(QuickShare.open("K1Q:\(otherCode):\(parsed.bundle)").openFailure, .undecryptable)
        XCTAssertEqual(QuickShare.open(String(text.dropLast(4)) + "AAAA").openFailure, .undecryptable)
        XCTAssertEqual(QuickShare.open("hello").openFailure, .malformed)

        let all = try TransferBundle.build(
            TransferPayload(scope: .all, createdAt: nowSeconds, device: "test", snapshot: source.exportSnapshot()), code: plainCode)
        XCTAssertEqual(QuickShare.open(try XCTUnwrap(QuickShare.compose(code: plainCode, bundle: all))).openFailure, .wrongScope)
    }

    func testNewerLocalBindingIsNotOverwrittenOnImport() throws {
        let (source, current, _) = try groupRing(rebuilds: 0)
        guard case let .full(text, _) = try build(source) else { return XCTFail("expected full") }
        let payload = try opened(text)
        let target = ring()
        let newer = try target.addMaster(KeyDerivation.generateMasterKey())
        try target.setChatMaster(chatId: group, masterId: newer, label: "20260920")
        let merged = target.mergeSnapshot(payload.snapshot)
        XCTAssertEqual(merged.skippedChats, [group])
        XCTAssertEqual(target.snapshot().chatMasters[group], newer)
        // the imported master still lands, so older messages open
        XCTAssertNotNil(target.masterKey(for: current))
    }

    func testNoKey() throws {
        XCTAssertEqual(try build(ring()), .noKey)
    }

    // MARK: Saved Messages takeover (2026-09-28 decision)

    func savedRing(_ label: String, own: String = "777") throws -> (KeyRing, String) {
        let r = ring()
        let masterId = try r.addMaster(KeyDerivation.generateMasterKey())
        try r.setChatMaster(chatId: own, masterId: masterId, label: label)
        r.setChatEncryption(chatId: own, enabled: true)
        return (r, masterId)
    }

    func quickSharePayload(from source: KeyRing, chatId: String) throws -> TransferPayload {
        let base = source.exportChatsSnapshot(chatIds: [chatId], withIdentity: false, includeDeviceLabels: false)
        let outcome = try QuickShare.build(chatId: chatId, base: base, historyNewestFirst: [], createdAt: nowSeconds, device: "test", code: plainCode)
        guard case let .full(text, _) = outcome else { throw QuickShare.OpenError.malformed }
        return try opened(text)
    }

    func testSavedMessagesScannedKeyReplacesTheLocalOneEvenWhenOlder() throws {
        let (phone, phoneKey) = try savedRing("20260901")
        let (laptop, laptopKey) = try savedRing("20260910")   // made later, by 3.20, on first launch
        let payload = try quickSharePayload(from: phone, chatId: "777")
        XCTAssertNotNil(QuickShare.savedMessagesTakeover(payload, savedChatId: "777"))

        let result = laptop.mergeQuickShare(payload, savedChatId: "777")
        XCTAssertEqual(result.boundChats, ["777"])
        XCTAssertEqual(result.skippedChats, [])
        XCTAssertEqual(laptop.chatMasterId("777"), phoneKey)
        XCTAssertEqual(laptop.chatKeyLabel("777"), "20260901")
        XCTAssertTrue(laptop.isChatEncrypted("777"))
        // the laptop's own key stays, read-only, so what it wrote before still opens
        XCTAssertNotNil(laptop.masterKey(for: laptopKey))
        XCTAssertEqual(laptop.snapshot().chatMasterHistory["777"], [laptopKey, phoneKey])

        // scanning the same QR again changes nothing
        let again = laptop.mergeQuickShare(payload, savedChatId: "777")
        XCTAssertEqual(laptop.chatMasterId("777"), phoneKey)
        XCTAssertEqual(again.addedMasters, 0)
    }

    func testGroupsKeepTheNeverRollBackMerge() throws {
        let (source, _, _) = try groupRing(rebuilds: 0)
        let payload = try quickSharePayload(from: source, chatId: group)
        XCTAssertNil(QuickShare.savedMessagesTakeover(payload, savedChatId: "777"))
        let target = ring()
        let newer = try target.addMaster(KeyDerivation.generateMasterKey())
        try target.setChatMaster(chatId: group, masterId: newer, label: "20260920")
        let result = target.mergeQuickShare(payload, savedChatId: "777")
        XCTAssertEqual(result.skippedChats, [group])
        XCTAssertEqual(target.chatMasterId(group), newer)
    }

    func testAnotherAccountsSavedMessagesIsNotTakenOver() throws {
        let (phone, _) = try savedRing("20260901", own: "555")
        let payload = try quickSharePayload(from: phone, chatId: "555")
        XCTAssertNil(QuickShare.savedMessagesTakeover(payload, savedChatId: "777"))
    }

    // MARK: capacity

    func testHistoryIsNewestFirstAndSkipsWhatTheBaseAlreadyHas() throws {
        let (source, current, history) = try groupRing(rebuilds: 5)
        let base = source.exportChatsSnapshot(chatIds: [group], withIdentity: false, includeDeviceLabels: false)
        let found = QuickShare.history(full: source.snapshot(), chatId: group, base: base)
        XCTAssertEqual(found.map { $0.masterId }, history)
        XCTAssertFalse(found.contains { $0.masterId == current })
        let two = QuickShare.adding(found.prefix(2), to: base)
        XCTAssertEqual(Set(two.masters.keys), Set([current] + history.prefix(2)))
        XCTAssertEqual(two.chatMasters[group], current)
    }

    func testTooMuchHistoryKeepsCurrentPlusNewestThatFit() throws {
        let (source, current, history) = try groupRing(rebuilds: 40)
        XCTAssertEqual(history.count, KeyRing.maxMasterHistory - 1)
        let code = TransferCode.generate()
        let outcome = try build(source, code: code)
        guard case let .partial(text, count, dropped) = outcome else { return XCTFail("expected partial, got \(outcome)") }
        XCTAssertLessThanOrEqual(QuickShare.byteCount(text), QuickShare.maxQrBytes)
        XCTAssertGreaterThan(count, 1)
        XCTAssertEqual(count - 1 + dropped, history.count)
        let payload = try opened(text)
        XCTAssertEqual(payload.snapshot.masters.count, count)
        XCTAssertEqual(Set(payload.snapshot.masters.keys), Set([current] + history.prefix(count - 1)))

        // one more would not have fitted: the search keeps the maximum
        let base = source.exportChatsSnapshot(chatIds: [group], withIdentity: false, includeDeviceLabels: false)
        let all = QuickShare.history(full: source.snapshot(), chatId: group, base: base)
        let oneMore = QuickShare.adding(all.prefix(count), to: base)
        let bigger = try XCTUnwrap(QuickShare.compose(code: code, bundle: TransferBundle.build(
            TransferPayload(scope: .chat, chatIds: [group], createdAt: nowSeconds, device: "test", snapshot: oneMore), code: code)))
        XCTAssertGreaterThan(QuickShare.byteCount(bigger), QuickShare.maxQrBytes)
    }

    func testTooLargeWhenEvenTheBaseAloneDoesNotFit() throws {
        let (source, _, _) = try groupRing(rebuilds: 3)
        XCTAssertEqual(try build(source, maxBytes: 200), .tooLarge)
    }

    func testCapacityBoundaryIsInclusive() throws {
        let (source, _, _) = try groupRing(rebuilds: 0)
        let code = TransferCode.generate()
        guard case let .full(text, _) = try build(source, code: code) else { return XCTFail("expected full") }
        let size = QuickShare.byteCount(text)
        XCTAssertNotEqual(try build(source, code: code, maxBytes: size), .tooLarge)
        XCTAssertEqual(try build(source, code: code, maxBytes: size - 1), .tooLarge)
    }
}

extension Result {
    var openFailure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
