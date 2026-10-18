import XCTest
@testable import SecutgCore

/// Web integration draft 1/4 (persistence adapter) coverage: every store `toSnapshot`/`fromSnapshot`
/// pair added for this slice, plus `V2PersistedState`'s own aggregate round trip through a real
/// `V2Storage` (`V2KeychainStorage`, exercising the actual Keychain + file path this port uses on
/// device) and through `V2MemoryStorage` (the fast path most other tests should prefer).
final class V2PersistTests: XCTestCase {
    private func randomBytes(_ n: Int) -> [UInt8] {
        return V2Suite.randomBytes(n)
    }

    // MARK: individual store round trips

    func testBindingStoreSnapshotRoundTrip() {
        let store = V2Binding.BindingStore()
        let binding = V2Binding.freshTemplate(
            chatId: "100", bindingId: "b1", epoch: 1, deviceRoster: ["d1", "d2"],
            deviceKeys: ["d1": V2Binding.DeviceKeys(identityPk: "pk1", encapsulationPk: "ek1")],
            revision: 1, txnId: "t1", installedAtMs: 123
        )
        store.install(binding)
        store.markVerified(chatId: "100", bindingId: "b1")
        // A second install with a different bindingId pushes the first to historical.
        store.install(V2Binding.freshTemplate(
            chatId: "100", bindingId: "b2", epoch: 1, deviceRoster: ["d1", "d2"],
            deviceKeys: [:], revision: 1, txnId: "t2", installedAtMs: 456
        ))

        let restored = V2Binding.BindingStore.fromSnapshot(store.toSnapshot())
        XCTAssertEqual(restored.current("100")?.bindingId, "b2")
        XCTAssertEqual(restored.historical("100").map(\.bindingId), ["b1"])
        XCTAssertTrue(restored.alreadyInstalledFor(chatId: "100", txnId: "t1"))
    }

    func testTombstoneStoreSnapshotRoundTrip() {
        let store = V2Binding.TombstoneStore()
        store.recordCancelled(txnId: "t1", eventId: "e1", atMs: 10)
        store.recordUnpaired(bindingId: "b1", eventId: "e2", atMs: 20)

        let restored = V2Binding.TombstoneStore.fromSnapshot(store.toSnapshot())
        XCTAssertEqual(restored.cancelledFor("t1")?.eventId, "e1")
        XCTAssertEqual(restored.unpairedFor("b1")?.eventId, "e2")
    }

    func testBindingKeyStoreSnapshotRoundTrip() {
        let store = V2KeyStore.BindingKeyStore()
        store.installCurrent(bindingId: "b1", epoch: 1, master: randomBytes(32))
        store.installCurrent(bindingId: "b1", epoch: 2, master: randomBytes(32))

        let restored = V2KeyStore.BindingKeyStore.fromSnapshot(store.toSnapshot())
        XCTAssertEqual(restored.get("b1", 2)?.status, .current)
        XCTAssertEqual(restored.get("b1", 1)?.status, .historical)
        XCTAssertEqual(restored.get("b1", 2)?.master, store.get("b1", 2)?.master)
    }

    func testAuthorizationStoreSnapshotRoundTrip() {
        let store = V2Authorization.AuthorizationStore()
        let policy = V2Authorization.Policy(
            policyId: "p1", localDevice: "d1", chatId: "100", peerUser: "200", peerSignPk: "pk",
            createdAtMs: 0, expiresAtMs: 999_999_999_999
        )
        store.register(policy)
        store.lockToTxn(policyId: "p1", txnId: "t1")

        let restored = V2Authorization.AuthorizationStore.fromSnapshot(store.toSnapshot())
        XCTAssertEqual(restored.statusOf("p1"), .active)
        // Locked to t1, so a DIFFERENT txn must not find it eligible.
        XCTAssertNil(restored.findEligible(chatId: "100", peerUser: "200", peerSignPk: "pk", nowMs: 1, txnId: "other"))
        XCTAssertNotNil(restored.findEligible(chatId: "100", peerUser: "200", peerSignPk: "pk", nowMs: 1, txnId: "t1"))
    }

    func testGroupStateStoreSnapshotRoundTrip() {
        let store = V2GroupState.GroupStateStore()
        let admin = V2GroupState.AdminAclEntry(deviceId: "d1", identityPk: "pk1")
        let genesis = V2GroupState(
            groupId: "-1", genesisId: "g1", stateHash: "s1", epoch: 0, mode: .auto, adminAcl: [admin],
            deviceRoster: ["d1"], deviceKeys: ["d1": V2GroupState.DeviceKeys(identityPk: "pk1", encapsulationPk: "ek1")],
            keyCommitment: "kc1", modeConfirmed: true
        )
        XCTAssertTrue(store.installGenesis(genesis))
        let commit = V2GroupState(
            groupId: "-1", genesisId: "g1", stateHash: "s2", epoch: 1, mode: .auto, adminAcl: [admin],
            deviceRoster: ["d1"], deviceKeys: genesis.deviceKeys, keyCommitment: "kc2", modeConfirmed: true
        )
        store.applyCommit(groupId: "-1", newState: commit)

        let restored = V2GroupState.GroupStateStore.fromSnapshot(store.toSnapshot())
        XCTAssertEqual(restored.current("-1")?.stateHash, "s2")
        XCTAssertEqual(restored.historical("-1").map(\.stateHash), ["s1"])
    }

    func testGroupKeyStoreSnapshotRoundTrip() {
        let store = V2GroupKeyStore()
        store.set(V2GroupKeyStore.KeyRecord(groupId: "-1", stateHash: "s1", epoch: 0, status: .current, master: randomBytes(32)))
        store.set(V2GroupKeyStore.KeyRecord(groupId: "-1", stateHash: "s2", epoch: 1, status: .missing, master: nil))

        let restored = V2GroupKeyStore.fromSnapshot(store.toSnapshot())
        XCTAssertEqual(restored.get("-1", "s1")?.status, .current)
        XCTAssertEqual(restored.get("-1", "s2")?.status, .missing)
        XCTAssertNil(restored.get("-1", "s2")?.master)
    }

    func testW2StoresSnapshotRoundTrip() {
        let authStore = V2W2.W2AuthorizationStore()
        authStore.authorize(V2W2.Authorization(account: "100", controlPublicKey: "pk", allowedScope: ["wipe_all"]))
        let restoredAuth = V2W2.W2AuthorizationStore.fromSnapshot(authStore.toSnapshot())
        XCTAssertEqual(restoredAuth.get("100")?.allowedScope, ["wipe_all"])

        let dedup = V2W2.W2DedupStore()
        dedup.markProcessed("e1")
        let restoredDedup = V2W2.W2DedupStore.fromSnapshot(dedup.toSnapshot())
        XCTAssertTrue(restoredDedup.alreadyProcessed("e1"))
        XCTAssertFalse(restoredDedup.alreadyProcessed("e2"))
    }

    /// Fix E1: `PendingTxn`/`InMemoryTxnStore` used to have no snapshot support at all — the direct
    /// cause of a restart mid-pairing losing the in-flight exchange back to "unknown_txn"
    /// (`V2ProcessorTests.testP25P29ARestartMidPairingRestoresThePendingTransactionFromASnapshot`
    /// exercises that scenario end to end; this test is the narrower per-store round trip the other
    /// `test*SnapshotRoundTrip` cases above already establish the pattern for).
    func testPendingTxnStoreSnapshotRoundTrip() {
        let ephemeral = V2Suite.generateX25519()
        let txn = V2Processor.PendingTxn(role: .initiator, phase: .confirming, chatId: "100", txnId: "t1", ownEphemeral: ephemeral, ownWire: "P2:INVITE")
        txn.peerWire = "P2:ACCEPT"
        txn.peerIdentityPk = randomBytes(32)
        txn.transcriptHash = randomBytes(32)
        txn.keys = V2Transcript.DerivedKeys(master: randomBytes(32), kc: randomBytes(32))
        txn.siblingAcceptHashes = ["h1", "h2"]

        let store = V2Processor.InMemoryTxnStore()
        store.set("t1", txn)

        let restored = V2Processor.InMemoryTxnStore.fromSnapshot(store.toSnapshot())
        let restoredTxn = restored.get("t1")
        XCTAssertEqual(restoredTxn?.chatId, "100")
        XCTAssertEqual(restoredTxn?.phase, .confirming)
        XCTAssertEqual(restoredTxn?.ownEphemeral.publicKey, ephemeral.publicKey)
        XCTAssertEqual(restoredTxn?.ownEphemeral.secretKey, ephemeral.secretKey)
        XCTAssertEqual(restoredTxn?.peerWire, "P2:ACCEPT")
        XCTAssertEqual(restoredTxn?.keys?.master, txn.keys?.master)
        XCTAssertEqual(restoredTxn?.siblingAcceptHashes, ["h1", "h2"])
    }

    /// Fix E1: the per-chat CAS (`V2Processor.PairingProcessor`'s own `chatSlot`) — previously
    /// explicitly excluded from `V2PersistedState`'s doc comment, now included.
    func testChatSlotCasSnapshotRoundTrip() {
        let cas = V2SelectionCas<String>()
        let claimed = cas.select(slotKey: "100", candidateId: "txn-a")
        XCTAssertTrue(claimed.won)

        let restored = V2SelectionCas<String>.fromSnapshot(cas.toSnapshot())
        XCTAssertEqual(restored.get("100"), "txn-a")
        // The CAS's own "permanently-once-set" contract survives the round trip too.
        let secondClaim = restored.select(slotKey: "100", candidateId: "txn-b")
        XCTAssertFalse(secondClaim.won)
        XCTAssertEqual(secondClaim.selected, "txn-a")
    }

    func testOutboxQueueSnapshotRoundTrip() {
        let queue = V2OutboxQueue()
        queue.enqueue(eventId: "e1", bytes: "b1", family: "SELECT")
        queue.enqueue(eventId: "e2", bytes: "b2", family: "ACCEPT")
        queue.markSent("e1")

        let restored = V2OutboxQueue.fromSnapshot(queue.toSnapshot())
        XCTAssertEqual(restored.get("e1")?.status, .sent)
        // Dependency order (ACCEPT before SELECT), preserved across the round trip.
        XCTAssertEqual(restored.pending().map(\.eventId), ["e2"])
    }

    // MARK: aggregate round trip

    func testPersistedV2StateRoundTripsThroughMemoryStorage() {
        let storage = V2MemoryStorage()
        let state = V2PersistedState.load(storage: storage)
        state.bindingStore.install(V2Binding.freshTemplate(
            chatId: "100", bindingId: "b1", epoch: 1, deviceRoster: ["d1"], deviceKeys: [:],
            revision: 1, txnId: "t1", installedAtMs: 1
        ))
        state.outboxQueue.enqueue(eventId: "e1", bytes: "b1", family: "INVITE")
        state.persist()

        let reloaded = V2PersistedState.load(storage: storage)
        XCTAssertEqual(reloaded.bindingStore.current("100")?.bindingId, "b1")
        XCTAssertEqual(reloaded.outboxQueue.get("e1")?.bytes, "b1")
    }

    /// Fix E1: `pendingTxnStore`/`chatSlotStore` are now part of the aggregate, alongside the other
    /// 9 stores `testPersistedV2StateRoundTripsThroughMemoryStorage` above already covers.
    func testPersistedV2StatePendingTxnAndChatSlotSurviveMemoryStorageRoundTrip() {
        let storage = V2MemoryStorage()
        let state = V2PersistedState.load(storage: storage)
        let ephemeral = V2Suite.generateX25519()
        state.pendingTxnStore.set("t1", V2Processor.PendingTxn(role: .initiator, phase: .invited, chatId: "100", txnId: "t1", ownEphemeral: ephemeral, ownWire: "P2:INVITE"))
        _ = state.chatSlotStore.select(slotKey: "100", candidateId: "t1")
        state.persist()

        let reloaded = V2PersistedState.load(storage: storage)
        XCTAssertEqual(reloaded.pendingTxnStore.get("t1")?.chatId, "100")
        XCTAssertEqual(reloaded.chatSlotStore.get("100"), "t1")
    }

    func testPersistedV2StateRoundTripsThroughARealKeychainBackedStorage() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("v2persist-\(UUID().uuidString)")
        let accountKey = "test-\(UUID().uuidString)"
        let storage = V2KeychainStorage(accountKey: accountKey, basePath: tmpDir.path)
        defer { storage.wipe(); try? FileManager.default.removeItem(at: tmpDir) }

        let state = V2PersistedState.load(storage: storage)
        XCTAssertNil(state.bindingStore.current("100")) // nothing persisted yet

        state.bindingStore.install(V2Binding.freshTemplate(
            chatId: "100", bindingId: "b1", epoch: 1, deviceRoster: ["d1"], deviceKeys: [:],
            revision: 1, txnId: "t1", installedAtMs: 1
        ))
        state.groupKeyStore.set(V2GroupKeyStore.KeyRecord(groupId: "-1", stateHash: "s1", epoch: 0, status: .current, master: randomBytes(32)))
        state.persist()

        // A SEPARATE V2PersistedState/V2KeychainStorage instance over the SAME accountKey/basePath
        // sees what the first one wrote — a real disk+Keychain round trip, not just an in-memory one.
        let reloadedStorage = V2KeychainStorage(accountKey: accountKey, basePath: tmpDir.path)
        let reloaded = V2PersistedState.load(storage: reloadedStorage)
        XCTAssertEqual(reloaded.bindingStore.current("100")?.bindingId, "b1")
        XCTAssertEqual(reloaded.groupKeyStore.get("-1", "s1")?.status, .current)
        XCTAssertEqual(reloaded.groupKeyStore.get("-1", "s1")?.master, state.groupKeyStore.get("-1", "s1")?.master)
    }

    // MARK: fix E1 — persist() is now actually called from real dispatch, not just from tests

    private func makeStoredIdentity() -> KeyRing.Identity {
        let ed = V2Suite.generateEd25519()
        let x = V2Suite.generateX25519()
        return KeyRing.Identity(x25519Pk: x.publicKey, x25519Sk: x.secretKey, ed25519Pk: ed.publicKey, ed25519Sk: ed.secretKey)
    }

    /// Before this fix, `V2PersistedState.persist()` was only ever called by this very test file —
    /// never by `V2PairingDispatch`/`V2Dispatch`, so a real pairing exchange never actually reached
    /// disk despite every store above already having snapshot support. Reads the storage directly
    /// (never `runtime.persisted` itself) so a passing assertion can only mean the dispatch call
    /// itself invoked `persist()`, not that the in-memory store merely changed.
    func testStartPairingDispatchActuallyPersistsThePendingTransactionToStorage() {
        let accountKey = "persist-wiring-\(UUID().uuidString)"
        defer { V2RuntimeRegistry.shared.reset(for: accountKey) }
        let storage = V2MemoryStorage()
        let identity = V2IdentityBridge.identity(userId: "100", from: makeStoredIdentity())!
        let runtime = V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: storage))
        V2RuntimeRegistry.shared.set(runtime, for: accountKey)

        XCTAssertNil(storage.saved, "nothing persisted yet — persist() has not run")
        guard case .sent = V2PairingDispatch.startPairing(accountKey: accountKey, chatId: "100", targetUser: "200") else {
            return XCTFail("expected .sent")
        }
        XCTAssertFalse(storage.saved?.pendingTxn.entries.isEmpty ?? true, "startPairing must call persist() itself")
    }

    /// Same wiring check for `V2PairingDispatch.unpair` (fix A9 + fix E1 together): the deactivated
    /// binding must not silently reappear as "current" on the next real reload.
    func testUnpairDispatchActuallyPersistsTheDeactivatedBindingToStorage() {
        let accountKey = "persist-wiring-unpair-\(UUID().uuidString)"
        defer { V2RuntimeRegistry.shared.reset(for: accountKey) }
        let storage = V2MemoryStorage()
        let identity = V2IdentityBridge.identity(userId: "100", from: makeStoredIdentity())!
        let runtime = V2Runtime(identity: identity, persisted: V2PersistedState.load(storage: storage))
        V2RuntimeRegistry.shared.set(runtime, for: accountKey)

        // PLAN.md 3.39.7: an UNPAIR wire only goes out from a device the binding's roster knows (a V2Q join the roster
        // never adopted is torn down locally, with nothing to send), so the synthetic binding names this device.
        let ownDeviceId = Base64Url.encode(V2Suite.sha256(identity.publicKey))
        runtime.persisted.bindingStore.install(V2Binding.freshTemplate(
            chatId: "100", bindingId: "b1", epoch: 1, deviceRoster: [ownDeviceId],
            deviceKeys: [ownDeviceId: V2Binding.DeviceKeys(identityPk: Base64Url.encode(identity.publicKey), encapsulationPk: Base64Url.encode(identity.encapsulationPk))],
            revision: 1, txnId: "t1", installedAtMs: 1
        ))
        runtime.persisted.persist()
        XCTAssertNotNil(storage.saved?.binding.current.first { $0.chatId == "100" })

        guard case .sent = V2PairingDispatch.unpair(accountKey: accountKey, chatId: "100") else {
            return XCTFail("expected .sent")
        }
        XCTAssertNil(storage.saved?.binding.current.first { $0.chatId == "100" }, "unpair must persist the deactivation itself")
    }

    func testWipeRemovesEverythingSoANewLoadStartsEmpty() {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("v2persist-\(UUID().uuidString)")
        let accountKey = "test-\(UUID().uuidString)"
        let storage = V2KeychainStorage(accountKey: accountKey, basePath: tmpDir.path)
        defer { storage.wipe(); try? FileManager.default.removeItem(at: tmpDir) }

        let state = V2PersistedState.load(storage: storage)
        state.outboxQueue.enqueue(eventId: "e1", bytes: "b1", family: "INVITE")
        state.persist()
        storage.wipe()

        let reloaded = V2PersistedState.load(storage: storage)
        XCTAssertNil(reloaded.outboxQueue.get("e1"))
    }
}
