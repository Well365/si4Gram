import XCTest
@testable import SecutgCore

/// PLAN.md 3.41.5: the `shouldBlockSend` table row by row, then auto-arm, the manual switch's stickiness, re-arm
/// on a new key, the one-time upgrade pass, and the flag's home in `V2PersistedState` (round trip, wipe, and a
/// snapshot written before 3.41).
final class KeyRequiredTests: XCTestCase {
    private func block(_ keyRequired: Bool, _ kind: KeyRequired.ChatKind, _ state: KeyRequired.KeyState, control: Bool = false) -> Bool {
        return KeyRequired.shouldBlockSend(keyRequired: keyRequired, chatKind: kind, keyState: state, isControlLine: control)
    }

    // MARK: the 3.41.5 table

    func testFlagOffLetsEverythingThrough() {
        // 关 | 任意 | 任意 | 任意 | 放行
        for kind in [KeyRequired.ChatKind.privateChat, .group, .savedMessages] {
            for state in [KeyRequired.KeyState.v2Sendable, .v1LegacyOnly, .notPaired, .unpaired, .invited, .joinPending, .suspended, .groupKey, .noGroupKey, .savedKey, .noSavedKey] {
                XCTAssertFalse(block(false, kind, state), "\(kind) \(state)")
                XCTAssertFalse(block(false, kind, state, control: true), "\(kind) \(state) control")
            }
        }
    }

    func testPrivateChatWithASendableV2BindingPasses() {
        // 开 | 1v1 | v2 可发 | 否 | 放行
        XCTAssertFalse(block(true, .privateChat, .v2Sendable))
    }

    func testPrivateChatWithOnlyALegacyV1KeyPasses() {
        // 开 | 1v1 | 仅 v1 旧配对可发 | 否 | 放行
        XCTAssertFalse(block(true, .privateChat, .v1LegacyOnly))
    }

    func testPrivateChatWithoutASendKeyIsRefused() {
        // 开 | 1v1 | 未配对 / 已解除 / 邀请中 / join_pending | 否 | 拒发
        XCTAssertTrue(block(true, .privateChat, .notPaired))
        XCTAssertTrue(block(true, .privateChat, .unpaired))
        XCTAssertTrue(block(true, .privateChat, .invited))
        XCTAssertTrue(block(true, .privateChat, .joinPending))
        XCTAssertTrue(block(true, .privateChat, .suspended))
    }

    func testPrivateChatControlLinePassesWithoutAKey() {
        // 开 | 1v1 | 未配对 | 是（P2） | 放行 — the invite is how the key arrives
        XCTAssertFalse(block(true, .privateChat, .notPaired, control: true))
        XCTAssertFalse(block(true, .privateChat, .unpaired, control: true))
        XCTAssertFalse(block(true, .privateChat, .joinPending, control: true))
    }

    func testGroupWithAKeyPasses() {
        // 开 | 群 | 有群钥匙 | 否 | 放行
        XCTAssertFalse(block(true, .group, .groupKey))
    }

    func testGroupWithoutAKeyIsRefused() {
        // 开 | 群 | 无群钥匙 | 否 | 拒发
        XCTAssertTrue(block(true, .group, .noGroupKey))
    }

    func testGroupControlLinePassesWithoutAKey() {
        // 开 | 群 | 无群钥匙 | 是（G2 / GP1 / N1） | 放行
        XCTAssertFalse(block(true, .group, .noGroupKey, control: true))
    }

    func testSavedMessagesWithoutAKeyIsRefused() {
        // 开 | 收藏夹 | 无钥匙 | 否 | 拒发
        XCTAssertTrue(block(true, .savedMessages, .noSavedKey))
        XCTAssertFalse(block(true, .savedMessages, .savedKey))
    }

    /// The real control lines, through the same structural test the runtimes use (`V2Dispatch.isProtocolWire`):
    /// a typed "P2: hi" is user text and must still be refused, a built `GP1` / `N1` is a protocol line and passes.
    func testTheRuntimesControlLineTestTellsProtocolLinesFromTypedText() throws {
        let gp1 = try XCTUnwrap(GP1.build(chatId: "-1001234567890", at: 1_789_300_020, payload: .off, publisherId: "7001"))
        XCTAssertTrue(V2Dispatch.isProtocolWire(gp1))
        XCTAssertFalse(block(true, .group, .noGroupKey, control: V2Dispatch.isProtocolWire(gp1)))
        XCTAssertFalse(V2Dispatch.isProtocolWire("P2: looks like a control line but is typed text"))
        XCTAssertTrue(block(true, .privateChat, .notPaired, control: V2Dispatch.isProtocolWire("P2: looks like a control line but is typed text")))
        XCTAssertFalse(V2Dispatch.isProtocolWire(""))
        XCTAssertTrue(block(true, .privateChat, .notPaired, control: V2Dispatch.isProtocolWire("")), "media without a caption is user content")
    }

    // MARK: auto-arm (3.41.1)

    func testTheFirstKeyArmsTheFlag() {
        XCTAssertEqual(KeyRequired.observed(nil, keyId: "b1"), KeyRequired.Record(enabled: true))
    }

    func testNoKeyArmsNothing() {
        XCTAssertNil(KeyRequired.observed(nil, keyId: nil))
        let off = KeyRequired.Record(enabled: false, manualOffKeyId: "b1")
        XCTAssertEqual(KeyRequired.observed(off, keyId: nil), off)
    }

    func testAFlagAlreadyOnStaysOn() {
        let on = KeyRequired.Record(enabled: true)
        XCTAssertEqual(KeyRequired.observed(on, keyId: "b1"), on)
        XCTAssertEqual(KeyRequired.observed(on, keyId: "b2"), on)
        // Losing the key does not turn the flag off — that is the moment it is for.
        XCTAssertEqual(KeyRequired.observed(on, keyId: nil), on)
    }

    // MARK: the manual switch (3.41.1 手动)

    func testTurningOffByHandRemembersTheCurrentKey() {
        XCTAssertEqual(KeyRequired.toggled(KeyRequired.Record(enabled: true), enabled: false, currentKeyId: "b1"),
                       KeyRequired.Record(enabled: false, manualOffKeyId: "b1"))
    }

    func testManualOffSticksForTheSameKey() {
        let off = KeyRequired.toggled(nil, enabled: false, currentKeyId: "b1")
        XCTAssertEqual(KeyRequired.observed(off, keyId: "b1"), off, "the same key seen again must not re-arm")
        XCTAssertEqual(KeyRequired.observed(KeyRequired.observed(off, keyId: "b1"), keyId: "b1"), off)
    }

    func testANewKeyReArmsAfterManualOff() {
        // Unpair, then pair again: a different binding id is a new key.
        let off = KeyRequired.toggled(nil, enabled: false, currentKeyId: "b1")
        XCTAssertEqual(KeyRequired.observed(off, keyId: "b2"), KeyRequired.Record(enabled: true, manualOffKeyId: nil))
    }

    func testManualOffWithNoKeyReArmsOnAnyKey() {
        // 〔本聊天允许明文〕 is tapped from the refusal notice, i.e. while the chat has no key; the next key of any
        // identity is a new one.
        let off = KeyRequired.toggled(nil, enabled: false, currentKeyId: nil)
        XCTAssertEqual(KeyRequired.observed(off, keyId: "b1"), KeyRequired.Record(enabled: true, manualOffKeyId: nil))
    }

    func testTurningOnByHandForgetsTheRememberedKey() {
        let off = KeyRequired.Record(enabled: false, manualOffKeyId: "b1")
        XCTAssertEqual(KeyRequired.toggled(off, enabled: true, currentKeyId: "b1"), KeyRequired.Record(enabled: true, manualOffKeyId: nil))
    }

    // MARK: the store

    func testStoreReportsChangesSoTheCallerKnowsWhenToPersist() {
        let store = KeyRequiredStore()
        XCTAssertFalse(store.isRequired("100"))
        XCTAssertTrue(store.observeKey(chatId: "100", keyId: "b1"))
        XCTAssertTrue(store.isRequired("100"))
        XCTAssertFalse(store.observeKey(chatId: "100", keyId: "b1"), "nothing changed")
        XCTAssertFalse(store.observeKey(chatId: "100", keyId: nil), "losing the key changes nothing in the record")
        XCTAssertTrue(store.isRequired("100"))
        XCTAssertTrue(store.setManually(chatId: "100", enabled: false, currentKeyId: "b1"))
        XCTAssertFalse(store.isRequired("100"))
        XCTAssertFalse(store.setManually(chatId: "100", enabled: false, currentKeyId: "b1"), "already off for this key")
        XCTAssertFalse(store.observeKey(chatId: "100", keyId: "b1"), "sticky")
        XCTAssertTrue(store.observeKey(chatId: "100", keyId: "b2"), "a new key re-arms")
        XCTAssertEqual(store.requiredChatIds(), ["100"])
    }

    func testMigrationRunsOnce() {
        let store = KeyRequiredStore()
        XCTAssertFalse(store.isMigrated)
        XCTAssertTrue(store.migrate(keyedChats: ["100": "b1", "-200": "m1", "7001": "s1"]))
        XCTAssertTrue(store.isMigrated)
        XCTAssertEqual(store.requiredChatIds(), ["-200", "100", "7001"])
        // Turned off by hand after the pass; a second pass must not turn it back on.
        store.setManually(chatId: "100", enabled: false, currentKeyId: "b1")
        XCTAssertFalse(store.migrate(keyedChats: ["100": "b1", "300": "b3"]))
        XCTAssertFalse(store.isRequired("100"))
        XCTAssertFalse(store.isRequired("300"), "a chat keyed after the pass is armed by observeKey, not by a second pass")
    }

    func testMigrationRespectsAManualOffRecordedBeforeIt() {
        // Possible only on a device that toggled the flag before its first pass ran; still the right answer.
        let store = KeyRequiredStore()
        store.setManually(chatId: "100", enabled: false, currentKeyId: "b1")
        XCTAssertTrue(store.migrate(keyedChats: ["100": "b1", "101": "b9"]))
        XCTAssertFalse(store.isRequired("100"))
        XCTAssertTrue(store.isRequired("101"))
    }

    // MARK: the forward funnel (the same two gates, in `prepareOutgoing`'s order)

    func testAForwardIntoALockedGroupIsRefusedByThePasswordGateFirst() {
        // Both gates would refuse; the password lock is named, as it is the one `prepareOutgoing` reaches first.
        XCTAssertEqual(ForwardGate.refusal(groupPasswordLocked: true, keyRequired: true, chatKind: .group, keyState: .noGroupKey), .groupPasswordLocked)
        XCTAssertEqual(ForwardGate.refusal(groupPasswordLocked: true, keyRequired: false, chatKind: .group, keyState: .groupKey), .groupPasswordLocked)
    }

    func testAForwardIntoAChatWithoutItsKeyIsRefusedWhenTheFlagIsOn() {
        XCTAssertEqual(ForwardGate.refusal(groupPasswordLocked: false, keyRequired: true, chatKind: .privateChat, keyState: .unpaired), .keyRequired)
        XCTAssertEqual(ForwardGate.refusal(groupPasswordLocked: false, keyRequired: true, chatKind: .group, keyState: .noGroupKey), .keyRequired)
        XCTAssertEqual(ForwardGate.refusal(groupPasswordLocked: false, keyRequired: true, chatKind: .savedMessages, keyState: .noSavedKey), .keyRequired)
    }

    func testAForwardGoesAheadWithAKeyOrWithTheFlagOff() {
        XCTAssertNil(ForwardGate.refusal(groupPasswordLocked: false, keyRequired: true, chatKind: .privateChat, keyState: .v2Sendable))
        XCTAssertNil(ForwardGate.refusal(groupPasswordLocked: false, keyRequired: true, chatKind: .group, keyState: .groupKey))
        XCTAssertNil(ForwardGate.refusal(groupPasswordLocked: false, keyRequired: false, chatKind: .privateChat, keyState: .notPaired))
    }

    // MARK: its home in V2PersistedState

    func testFlagsRoundTripThroughV2PersistedState() {
        let storage = V2MemoryStorage()
        let state = V2PersistedState.load(storage: storage)
        XCTAssertFalse(state.keyRequiredStore.isMigrated)
        state.keyRequiredStore.migrate(keyedChats: ["100": "b1"])
        state.keyRequiredStore.setManually(chatId: "-200", enabled: false, currentKeyId: "m1")
        state.persist()

        let reloaded = V2PersistedState.load(storage: storage)
        XCTAssertTrue(reloaded.keyRequiredStore.isMigrated)
        XCTAssertTrue(reloaded.keyRequiredStore.isRequired("100"))
        XCTAssertEqual(reloaded.keyRequiredStore.record("-200"), KeyRequired.Record(enabled: false, manualOffKeyId: "m1"))
    }

    func testASnapshotWrittenBefore341DecodesToAnEmptyUnmigratedStore() throws {
        // The `keyRequired` key is simply absent from an older file.
        var snapshot = V2PersistedState.Snapshot.empty
        snapshot.keyRequired = nil
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(V2PersistedState.Snapshot.self, from: data)
        XCTAssertNil(decoded.keyRequired)
        let storage = V2MemoryStorage(decoded)
        let state = V2PersistedState.load(storage: storage)
        XCTAssertFalse(state.keyRequiredStore.isMigrated)
        XCTAssertTrue(state.keyRequiredStore.requiredChatIds().isEmpty)
    }

    func testTheWipeTakesTheFlagsWithIt() {
        // PLAN.md 3.41.1 last line / 3.16: the flag is a local trace and goes with the rest.
        let storage = V2MemoryStorage()
        let state = V2PersistedState.load(storage: storage)
        state.keyRequiredStore.observeKey(chatId: "100", keyId: "b1")
        state.persist()
        XCTAssertTrue(V2PersistedState.load(storage: storage).keyRequiredStore.isRequired("100"))

        state.wipe()
        XCTAssertNil(storage.saved)
        state.keyRequiredStore.observeKey(chatId: "300", keyId: "b3")
        state.persist()
        XCTAssertNil(storage.saved, "nothing is written back after the wipe")
        XCTAssertFalse(V2PersistedState.load(storage: storage).keyRequiredStore.isRequired("100"))
    }
}
