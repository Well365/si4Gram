import XCTest
@testable import SecutgCore

/// PLAN.md 3.16 items 5-10 / 3.22: wipe preferences persist with the ring, and the wipe destroys
/// everything including the preferences.
final class WipeSettingsTests: XCTestCase {
    func ring(_ storage: KeyRingStorage = MemoryKeyRingStorage()) -> KeyRing {
        return KeyRing(storage: storage, clock: { 1_800_000_000_000 }, epochDays: 1, epochTolerance: 1)
    }

    func testDefaultsMatchSpec() {
        let r = ring()
        XCTAssertTrue(r.getWipeNeedsConfirmation())      // 3.16 item 5 default on
        XCTAssertNil(r.getWipeCustomPhrase())            // 3.16 item 7 default empty
        XCTAssertTrue(r.getWipeListensToPhrase())        // 3.16 item 8 default on
        XCTAssertTrue(r.getWipeResetsAuthorizations())   // 3.16 item 9 default on
    }

    func testSettersPersistAndRoundTripThroughCodec() {
        let storage = MemoryKeyRingStorage()
        let r = ring(storage)
        r.setWipeNeedsConfirmation(false)
        r.setWipeListensToPhrase(false)
        r.setWipeResetsAuthorizations(false)
        XCTAssertNil(r.setWipeCustomPhrase("a good long phrase"))

        // Re-open from the same storage: settings survive.
        let reopened = ring(storage)
        XCTAssertFalse(reopened.getWipeNeedsConfirmation())
        XCTAssertFalse(reopened.getWipeListensToPhrase())
        XCTAssertFalse(reopened.getWipeResetsAuthorizations())
        XCTAssertEqual(reopened.getWipeCustomPhrase(), "a good long phrase")

        // And through the JSON codec directly.
        let encoded = SnapshotCodec.encode(r.snapshot())
        let decoded = SnapshotCodec.decode(encoded)
        XCTAssertEqual(decoded?.wipeCustomPhrase, "a good long phrase")
        XCTAssertEqual(decoded?.wipeNeedsConfirmation, false)
        XCTAssertEqual(decoded?.wipeListensToPhrase, false)
        XCTAssertEqual(decoded?.wipeResetsAuthorizations, false)
    }

    func testCustomPhraseRejectionsAreReported() {
        let r = ring()
        XCTAssertEqual(r.setWipeCustomPhrase("short"), .tooShort)
        XCTAssertEqual(r.setWipeCustomPhrase(WipePhrase.builtInPhrase), .sameAsBuiltIn)
        XCTAssertNil(r.getWipeCustomPhrase()) // nothing stored after rejection
    }

    func testEmptyCustomPhraseClears() {
        let r = ring()
        XCTAssertNil(r.setWipeCustomPhrase("a good long phrase"))
        XCTAssertEqual(r.getWipeCustomPhrase(), "a good long phrase")
        XCTAssertNil(r.setWipeCustomPhrase("   "))
        XCTAssertNil(r.getWipeCustomPhrase())
    }

    func testDestroyAllKeysWipesKeysAndPreferences() throws {
        let storage = MemoryKeyRingStorage()
        let r = ring(storage)
        let master = KeyDerivation.generateMasterKey()
        let id = try r.addMaster(master)
        try r.setChatMaster(chatId: "c", masterId: id, label: nil)
        r.setWipeNeedsConfirmation(false)
        XCTAssertNil(r.setWipeCustomPhrase("a good long phrase"))
        XCTAssertNotNil(r.currentKey(chatId: "c"))

        r.destroyAllKeys()

        // Keys gone.
        XCTAssertTrue(r.listMasterIds().isEmpty)
        XCTAssertNil(r.currentKey(chatId: "c"))
        XCTAssertNil(r.chatMasterId("c"))
        // Preferences reset to defaults (PLAN.md 3.16 item 10).
        XCTAssertTrue(r.getWipeNeedsConfirmation())
        XCTAssertNil(r.getWipeCustomPhrase())
        // Storage now holds the empty ring, so a reopen is empty too.
        let reopened = ring(storage)
        XCTAssertTrue(reopened.listMasterIds().isEmpty)
        XCTAssertTrue(reopened.getWipeNeedsConfirmation())
    }
}
