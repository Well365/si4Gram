import XCTest
@testable import SecutgCore

/// PLAN.md 3.0. Two things are under test and they pull in opposite directions: a keyring written under the
/// old `"-100" + id` spelling has to become readable again, and a keyring that was always right must not be
/// touched. In between sits the ambiguity — `"-1001"` is both channel 1 the old way and basic group 1001 the
/// current way — where the correct behaviour is to do nothing to the data and everything to the send path.
final class ChannelKeyMigrationTests: XCTestCase {
    /// A channel with a ten-digit bare id: the string and the arithmetic spelling are the same number, which
    /// is why the bug went unnoticed for so long and why almost no real keyring needs moving at all.
    func testTenDigitChannelKeysWereAlreadyCorrect() {
        let arithmetic = SharedChatId.encodeString(kind: .channel, bareId: 1_234_567_890)
        XCTAssertEqual(arithmetic, "-1001234567890")
        XCTAssertEqual(ChannelKeyMigration.decide(chatKey: arithmetic), .keep)
    }

    /// A nine-digit channel: `"-100" + 987654321` lands at ~1.0e11, two orders of magnitude above any basic
    /// group id, so the basic-group reading is impossible and the entry is moved without a guess.
    func testNineDigitLegacyChannelIsMovedUnambiguously() {
        XCTAssertEqual(ChannelKeyMigration.decide(chatKey: "-100987654321"), .rename(to: "-1000987654321"))
        XCTAssertEqual(SharedChatId.encodeString(kind: .channel, bareId: 987_654_321), "-1000987654321")
    }

    /// An eleven-digit channel: the entry sits in the channel zone but implies a bare id past the base, which
    /// encoding could never have produced. Structural, not a magnitude guess.
    func testElevenDigitLegacyChannelIsMovedUnambiguously() {
        XCTAssertEqual(ChannelKeyMigration.decide(chatKey: "-10012345678901"), .rename(to: "-1012345678901"))
    }

    /// The ambiguous sample from the spec: nothing in the number says which chat it is, so nothing moves.
    func testSmallIdCollisionIsRefusedNotGuessed() {
        XCTAssertEqual(ChannelKeyMigration.decide(chatKey: "-1001"), .ambiguous(counterpart: "-1000000000001"))
        XCTAssertEqual(SharedChatId.encodeString(kind: .channel, bareId: 1), "-1000000000001")
        // …and the same key read the other way really is a legal basic group, which is the whole problem.
        XCTAssertEqual(SharedChatId.decode("-1001")?.kind, .basicGroup)
        XCTAssertEqual(SharedChatId.decode("-1001")?.bareId, 1001)
    }

    func testKeysThatCannotBeConfusedAreLeftAlone() {
        for key in ["777000", "-999", "-123456", "-100", "-0", "", "not-a-number", "-1000000000000"] {
            XCTAssertEqual(ChannelKeyMigration.decide(chatKey: key), .keep, key)
        }
    }

    /// Running the migration twice must change nothing the second time, for every outcome it can produce.
    func testDecisionsAreIdempotent() {
        for moved in ["-1000987654321", "-1012345678901", "-1000000000001", "-1001234567890"] {
            XCTAssertEqual(ChannelKeyMigration.decide(chatKey: moved), .keep, moved)
        }
    }

    // MARK: whole-snapshot moves

    private func populated(_ chatId: String, masterId: String = "0123456789abcdef") -> KeyRing.Snapshot {
        var s = KeyRing.Snapshot()
        s.masters[masterId] = [UInt8](repeating: 7, count: 32)
        s.chatMasters[chatId] = masterId
        s.chatKeyLabels[chatId] = "20260911"
        s.chatEncryption[chatId] = true
        s.chatAdminPks[chatId] = [UInt8](repeating: 1, count: 32)
        s.chatAdminSks[chatId] = [UInt8](repeating: 2, count: 64)
        s.memberPks[chatId] = ["42": [UInt8](repeating: 3, count: 32)]
        s.memberEdPks[chatId] = ["42": [UInt8](repeating: 4, count: 32)]
        s.chatRatchets[chatId] = KeyRing.Ratchet(label: "20260911", masters: ["20260911": masterId])
        s.chatKeySources[chatId] = .offline
        s.groupOnlineInvites[chatId] = ["42": .verified]
        return s
    }

    /// Every map a chat can appear in moves together — a half-moved chat would read as "key, but no switch".
    func testEveryChatKeyedMapMovesTogether() {
        let (out, report) = ChannelKeyMigration.apply(to: populated("-100987654321"))
        XCTAssertEqual(report.renamed, ["-100987654321": "-1000987654321"])
        XCTAssertTrue(report.ambiguous.isEmpty)
        let moved = "-1000987654321"
        XCTAssertEqual(out.chatMasters[moved], "0123456789abcdef")
        XCTAssertEqual(out.chatKeyLabels[moved], "20260911")
        XCTAssertEqual(out.chatEncryption[moved], true)
        XCTAssertNotNil(out.chatAdminPks[moved])
        XCTAssertNotNil(out.chatAdminSks[moved])
        XCTAssertNotNil(out.memberPks[moved]?["42"])
        XCTAssertNotNil(out.memberEdPks[moved]?["42"])
        XCTAssertNotNil(out.chatRatchets[moved])
        XCTAssertEqual(out.chatKeySources[moved], .offline)
        XCTAssertEqual(out.groupOnlineInvites[moved]?["42"], .verified)
        XCTAssertNil(out.chatMasters["-100987654321"])
        // the master table is keyed by master id and must be carried through untouched
        XCTAssertEqual(out.masters["0123456789abcdef"], [UInt8](repeating: 7, count: 32))
        // and a second run is a no-op
        XCTAssertFalse(ChannelKeyMigration.apply(to: out).report.changed)
    }

    /// The ambiguous case end to end: the data stays exactly where it was, and the counterpart is quarantined.
    func testAmbiguousEntryIsKeptAndItsCounterpartQuarantined() {
        let (out, report) = ChannelKeyMigration.apply(to: populated("-1001"))
        XCTAssertEqual(report.ambiguous, ["-1001": "-1000000000001"])
        XCTAssertTrue(report.renamed.isEmpty)
        XCTAssertEqual(out.chatMasters["-1001"], "0123456789abcdef")   // the basic group keeps working
        XCTAssertEqual(out.chatEncryption["-1001"], true)
        XCTAssertTrue(out.encryptionLost.contains("-1000000000001"))   // the channel reading fails closed
    }

    /// An ambiguous key with nothing to lose is not worth a mark: no key and no switch means no downgrade.
    func testAmbiguousEntryWithoutEncryptionStateIsNotQuarantined() {
        var s = KeyRing.Snapshot()
        s.chatKeySources["-1001"] = .offline
        let (out, report) = ChannelKeyMigration.apply(to: s)
        XCTAssertTrue(out.encryptionLost.isEmpty)
        XCTAssertTrue(report.ambiguous.isEmpty)
    }

    /// Two chats claiming one key: leave both readable and say so, never merge one into the other.
    func testRenameOntoAnOccupiedKeyIsRefused() {
        var s = populated("-100987654321")
        s.chatMasters["-1000987654321"] = "fedcba9876543210"
        s.masters["fedcba9876543210"] = [UInt8](repeating: 9, count: 32)
        let (out, report) = ChannelKeyMigration.apply(to: s)
        XCTAssertEqual(report.conflicts, ["-100987654321"])
        XCTAssertTrue(report.renamed.isEmpty)
        XCTAssertEqual(out.chatMasters["-100987654321"], "0123456789abcdef")
        XCTAssertEqual(out.chatMasters["-1000987654321"], "fedcba9876543210")
    }

    /// A rename is a judgement, not a proof, so the key it moved off is quarantined too. If the bounds read
    /// the entry wrong, the chat that really lives at the old key is now holding nothing — and "nothing" is
    /// what the send path used to read as "this chat never encrypted".
    func testRenamingAnEntryQuarantinesTheKeyItCameFrom() {
        let (out, report) = ChannelKeyMigration.apply(to: populated("-100987654321"))
        XCTAssertEqual(report.renamed, ["-100987654321": "-1000987654321"])
        XCTAssertTrue(out.encryptionLost.contains("-100987654321"))    // the source fails closed
        XCTAssertFalse(out.encryptionLost.contains("-1000987654321"))  // the chat it moved to does not
        // and the mark survives a second run, which still reports no change at all
        let again = ChannelKeyMigration.apply(to: out)
        XCTAssertFalse(again.report.changed)
        XCTAssertEqual(again.snapshot.encryptionLost, out.encryptionLost)
    }

    /// The same terms the ambiguous branch uses: an entry that carried no key and no switch could not have
    /// been silently downgraded, so moving it costs nothing and is not worth a permanent refusal.
    func testRenamingAnEntryWithNothingToLoseLeavesNoMark() {
        var s = KeyRing.Snapshot()
        s.chatKeySources["-100987654321"] = .offline
        let (out, report) = ChannelKeyMigration.apply(to: s)
        XCTAssertEqual(report.renamed, ["-100987654321": "-1000987654321"])
        XCTAssertTrue(out.encryptionLost.isEmpty)
    }

    /// An explicit `false` is the user's decision and travels with the entry; the key it left behind is not
    /// quarantined, because plaintext there was never a downgrade.
    func testRenamingAnEntryTheUserSwitchedOffLeavesNoMark() {
        var s = KeyRing.Snapshot()
        s.chatEncryption["-100987654321"] = false
        let (out, report) = ChannelKeyMigration.apply(to: s)
        XCTAssertEqual(report.renamed, ["-100987654321": "-1000987654321"])
        XCTAssertEqual(out.chatEncryption["-1000987654321"], false)
        XCTAssertTrue(out.encryptionLost.isEmpty)
    }

    // MARK: the snapshot version, which decode used to write and then ignore

    func testVersionOneBlobIsMigratedAndVersionTwoIsNot() throws {
        let legacy = Data(#"{"v":1,"chat_encryption":{"-100987654321":true},"chat_masters":{}}"#.utf8)
        let migrated = try XCTUnwrap(SnapshotCodec.decodeWithReport(legacy))
        XCTAssertEqual(migrated.snapshot.chatEncryption["-1000987654321"], true)
        XCTAssertEqual(migrated.migration.renamed, ["-100987654321": "-1000987654321"])

        let current = Data(#"{"v":2,"chat_encryption":{"-100987654321":true},"chat_masters":{}}"#.utf8)
        let untouched = try XCTUnwrap(SnapshotCodec.decodeWithReport(current))
        XCTAssertEqual(untouched.snapshot.chatEncryption["-100987654321"], true)
        XCTAssertFalse(untouched.migration.changed)
    }

    /// A blob with no version field at all predates the field and is treated as version 1.
    func testMissingVersionIsTreatedAsLegacy() throws {
        let blob = Data(#"{"chat_encryption":{"-100987654321":true}}"#.utf8)
        let decoded = try XCTUnwrap(SnapshotCodec.decodeWithReport(blob))
        XCTAssertEqual(decoded.migration.renamed, ["-100987654321": "-1000987654321"])
    }

    func testEncodeWritesTheCurrentVersionAndCarriesTheQuarantine() throws {
        var s = KeyRing.Snapshot()
        s.encryptionLost = ["-1000000000001"]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: SnapshotCodec.encode(s)) as? [String: Any])
        XCTAssertEqual((json["v"] as? NSNumber)?.intValue, ChannelKeyMigration.snapshotVersion)
        XCTAssertEqual(json["chat_encryption_lost"] as? [String], ["-1000000000001"])
        let back = try XCTUnwrap(SnapshotCodec.decode(SnapshotCodec.encode(s)))
        XCTAssertEqual(back.encryptionLost, ["-1000000000001"])
    }
}

/// PLAN.md 3.0, the fail-closed half. `SecutgAccountRuntime.prepareOutgoing` lives in TelegramCore and cannot
/// be reached from here, so what is pinned is the predicate it asks: the keyring's own answer to "is this
/// chat's encryption switch missing rather than off?". That answer is what stands between a lost switch and a
/// plaintext send, and it is the thing that used to not exist at all.
final class EncryptionStateUnknownTests: XCTestCase {
    private func ring(_ snapshot: KeyRing.Snapshot) -> KeyRing {
        let storage = MemoryKeyRingStorage()
        storage.save(snapshot)
        return KeyRing(storage: storage, clock: { 1_789_171_170_000 }, epochDays: 1, epochTolerance: 1)
    }

    /// The three states told apart. Only the middle one may ever let plaintext out.
    func testOffIsADecisionMissingIsAFault() throws {
        var s = KeyRing.Snapshot()
        s.masters["0123456789abcdef"] = [UInt8](repeating: 7, count: 32)
        s.chatEncryption["-10"] = false              // the user turned it off: a decision
        s.chatMasters["-20"] = "0123456789abcdef"    // a key with no switch at all: damage
        s.encryptionLost = ["-30"]                   // a migration refused to claim an entry for this chat
        let r = ring(s)
        XCTAssertFalse(r.isEncryptionStateUnknown("-10"))
        XCTAssertTrue(r.isEncryptionStateUnknown("-20"))
        XCTAssertTrue(r.isEncryptionStateUnknown("-30"))
        XCTAssertFalse(r.isEncryptionStateUnknown("-40"))  // a chat nobody ever configured: nothing to lose
    }

    /// The user answering the question — either way — ends the refusal.
    func testTheQuarantineClearsWhenTheUserAnswers() throws {
        var s = KeyRing.Snapshot()
        s.encryptionLost = ["-1000000000001", "-1000000000002"]
        let r = ring(s)
        r.setChatEncryption(chatId: "-1000000000001", enabled: false)
        XCTAssertFalse(r.isEncryptionStateUnknown("-1000000000001"))
        let masterId = try r.addMaster(KeyDerivation.generateMasterKey())
        try r.setChatMaster(chatId: "-1000000000002", masterId: masterId, label: nil)
        // A key alone is not the answer: it clears the migration's mark but leaves the chat holding a key
        // with no switch, which is the other half of `isEncryptionStateUnknown` and still refuses to send.
        // Every real import path (`importPayload`, `createMaster`, a completed pairing) writes both, and
        // this is what makes a half-written one refuse rather than fall back to plaintext.
        XCTAssertTrue(r.isEncryptionStateUnknown("-1000000000002"))
        r.setChatEncryption(chatId: "-1000000000002", enabled: true)
        XCTAssertFalse(r.isEncryptionStateUnknown("-1000000000002"))
    }

    /// A mark whose chat has meanwhile gained real state is stale, and sanitising drops it rather than
    /// leaving the chat refusing to send forever.
    func testAStaleQuarantineIsDroppedOnLoad() {
        var s = KeyRing.Snapshot()
        s.chatEncryption["-1000000000001"] = true
        s.encryptionLost = ["-1000000000001"]
        XCTAssertFalse(ring(s).isEncryptionStateUnknown("-1000000000001"))
    }

    /// The hole the rename branch used to leave, end to end (PLAN.md 3.0). An old keyring holds a nine-digit
    /// channel under `"-100" + bare`; the migration is sure enough to move it, and the question nobody asked
    /// was what happens to anyone still addressing the chat by the key it moved off. The answer used to be:
    /// no key, no switch, `prepareOutgoing` sends it in the clear — the exact failure this migration exists
    /// to end, reintroduced by the migration itself on the one path that claims certainty.
    func testSendingUnderTheKeyARenameMovedAwayFromFailsClosed() {
        var legacy = KeyRing.Snapshot()
        legacy.masters["0123456789abcdef"] = [UInt8](repeating: 7, count: 32)
        legacy.chatMasters["-100987654321"] = "0123456789abcdef"
        legacy.chatEncryption["-100987654321"] = true

        let (migrated, report) = ChannelKeyMigration.apply(to: legacy)
        XCTAssertEqual(report.renamed, ["-100987654321": "-1000987654321"])

        let r = ring(migrated)
        // The source key holds nothing now, and that is exactly why it has to refuse rather than pass through.
        XCTAssertNil(r.chatMasterId("-100987654321"))
        XCTAssertFalse(r.isChatEncrypted("-100987654321"))
        XCTAssertTrue(r.isEncryptionStateUnknown("-100987654321"))
        // The chat the entry moved to is untouched by the mark and works normally.
        XCTAssertEqual(r.chatMasterId("-1000987654321"), "0123456789abcdef")
        XCTAssertTrue(r.isChatEncrypted("-1000987654321"))
        XCTAssertFalse(r.isEncryptionStateUnknown("-1000987654321"))
        // And the user can answer the question on the old key too, which ends the refusal.
        r.setChatEncryption(chatId: "-100987654321", enabled: false)
        XCTAssertFalse(r.isEncryptionStateUnknown("-100987654321"))
    }
}
