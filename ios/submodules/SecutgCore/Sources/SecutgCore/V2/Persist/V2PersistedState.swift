import Foundation

/// Aggregates every v2 store this device needs to survive a reload into one persisted unit — the v2
/// analog of `KeyRing`'s own snapshot/persist pattern, reused deliberately rather than invented
/// fresh. Ported by analogy from the Web reference's `persist/state.ts`.
///
/// One instance per device/account, matching how every store here is already keyed internally by
/// chatId/groupId/account rather than needing one instance per chat — the same singleton shape
/// `V2RuntimeRegistry` gives the whole `V2Runtime` this state backs.
///
/// Unlike the Web reference (`storage.load`/`storage.save` are async over IndexedDB, so `persist()`
/// there queues onto a sequential promise chain to keep two saves from racing), this port's
/// `V2Storage` is synchronous disk/Keychain I/O — the same shape `KeyRingStorage` already uses on
/// this platform — so `persist()` simply saves inline. It still never throws into the caller: a
/// persistence failure is logged by the storage implementation itself (mirroring
/// `SecutgKeyRingStorage.save`'s own "log, do not throw" contract), so an already-completed
/// in-memory protocol operation is never unwound because its own persistence write failed
/// afterward.
///
/// Deliberately excluded from this snapshot, and why (matching the Web reference's own exclusions):
/// `V2EventLog` is generic and used ad hoc with different result shapes per call site — persisting
/// it generically is a separate, harder problem, and losing it on reload only costs a few idempotent
/// replay checks re-running once, which every family here already tolerates by design. `V2SyncGate`
/// is explicitly NOT meant to survive a reload per its own module doc (always re-enters
/// CATCHING_UP). `V2DataProcessor`'s own internal outbox/dedup maps are ALSO not persisted in this
/// slice, the same known, bounded gap the Web reference's `hooks/state.ts` notes for
/// `E2Processor` — left for a follow-up once that class grows a snapshot method of its own.
///
/// SECUTG-HOOK (fix E1, no longer excluded): `V2Processor.PairingProcessor`'s in-flight `pending`
/// (pair_txn) and `chatSlot` (the per-chat CAS) used to be missing from here — the direct cause of
/// A restart mid-pairing losing everything back to "unknown_txn" — and, worse, `persist()` itself was
/// never actually called from any real send/receive path (`V2Dispatch`/`V2PairingDispatch`), so even
/// the other 9 stores below were pure in-memory in production despite having snapshot support. Both
/// gaps are closed together: `pendingTxnStore`/`chatSlotStore` are included below exactly like every
/// other store, and every real dispatch entry point now calls `persist()` once it finishes handling
/// a message (see `V2Dispatch.swift`/`V2PairingDispatch.swift`).
///
/// SECUTG-HOOK (fix, mirrors E1): `incomingInviteStore` closes the same shape of gap one layer up —
/// `SecutgRuntime.swift` (TelegramCore) kept the live incoming P2 invite's wire text in a plain
/// in-memory dictionary, not part of `V2Processor.PairingProcessor`'s own state at all, so it never
/// went through this snapshot. An app relaunch between "invite received" and "user taps accept" lost
/// it, and the accept tap then started a fresh outgoing invite instead of accepting — both sides end
/// up inviting each other, stuck in a loop. See `SecutgRuntime.swift`'s call sites.
public final class V2PersistedState {
    public struct Snapshot: Codable {
        public var binding: V2Binding.BindingStore.Snapshot
        public var tombstone: V2Binding.TombstoneStore.Snapshot
        public var bindingKeys: V2KeyStore.BindingKeyStore.Snapshot
        public var authorization: V2Authorization.AuthorizationStore.Snapshot
        public var groupState: V2GroupState.GroupStateStore.Snapshot
        public var groupKeys: V2GroupKeyStore.Snapshot
        public var w2Authorization: V2W2.W2AuthorizationStore.Snapshot
        public var w2Dedup: V2W2.W2DedupStore.Snapshot
        public var outbox: V2OutboxQueue.Snapshot
        public var pendingTxn: V2Processor.InMemoryTxnStore.Snapshot
        public var chatSlot: V2SelectionCas<String>.Snapshot
        public var incomingInvite: V2IncomingInviteStore.Snapshot
        /// PLAN.md 3.39.13: the P2 event ids this device built (`V2SentEventStore`). Optional: a snapshot written
        /// before 3.39.13 has none and decodes to an empty log. The 3.39.12 `join` record (`join_pending`) such a
        /// snapshot may still carry is no longer a field here, so decoding simply skips it. `V2Binding.ownIdentity`
        /// rides inside `binding`.
        public var sentEvents: V2SentEventStore.Snapshot?
        /// PLAN.md 3.41.4: the per-chat `keyRequired` flags and the one-time migration marker. Optional for the same
        /// reason as `sentEvents`: a snapshot written before 3.41 has none, and decodes to an empty, unmigrated store.
        /// Local only — this snapshot never leaves the device, and K2 / disaster files are built from key records,
        /// not from it (`KeyRequiredStore`'s own doc).
        public var keyRequired: KeyRequiredStore.Snapshot?

        public static let empty = Snapshot(
            binding: V2Binding.BindingStore().toSnapshot(),
            tombstone: V2Binding.TombstoneStore().toSnapshot(),
            bindingKeys: V2KeyStore.BindingKeyStore().toSnapshot(),
            authorization: V2Authorization.AuthorizationStore().toSnapshot(),
            groupState: V2GroupState.GroupStateStore().toSnapshot(),
            groupKeys: V2GroupKeyStore().toSnapshot(),
            w2Authorization: V2W2.W2AuthorizationStore().toSnapshot(),
            w2Dedup: V2W2.W2DedupStore().toSnapshot(),
            outbox: V2OutboxQueue().toSnapshot(),
            pendingTxn: V2Processor.InMemoryTxnStore().toSnapshot(),
            chatSlot: V2SelectionCas<String>().toSnapshot(),
            incomingInvite: V2IncomingInviteStore().toSnapshot(),
            sentEvents: V2SentEventStore().toSnapshot(),
            keyRequired: KeyRequiredStore().toSnapshot()
        )
    }

    public let bindingStore: V2Binding.BindingStore
    public let tombstoneStore: V2Binding.TombstoneStore
    public let bindingKeyStore: V2KeyStore.BindingKeyStore
    public let authorizationStore: V2Authorization.AuthorizationStore
    public let groupStateStore: V2GroupState.GroupStateStore
    public let groupKeyStore: V2GroupKeyStore
    public let w2AuthorizationStore: V2W2.W2AuthorizationStore
    public let w2DedupStore: V2W2.W2DedupStore
    public let outboxQueue: V2OutboxQueue
    /// SECUTG-HOOK (fix E1): passed into `V2Runtime`'s `V2Processor.PairingProcessor` as its
    /// `pendingStore`/`chatSlotStore` — the same instances this class snapshots, not a parallel copy.
    public let pendingTxnStore: V2Processor.InMemoryTxnStore
    public let chatSlotStore: V2SelectionCas<String>
    public let incomingInviteStore: V2IncomingInviteStore
    /// PLAN.md 3.39.13: what tells this device's own P2 echo from its clone's (`V2SentEventStore`). Written by
    /// `V2Runtime.noteSent` at build time, read by `V2PairingDispatch.handleIncoming`.
    public let sentEventStore: V2SentEventStore
    /// PLAN.md 3.41: the per-chat 「没有钥匙时禁止发送」 flags. Read and written by the runtime's send gate and lock
    /// menu, never by any v2 processor — it lives here only because this is the device-local per-chat state the
    /// two Apple clients keep identical, and because the wipe already destroys it (3.41.1).
    public let keyRequiredStore: KeyRequiredStore

    private let storage: V2Storage

    private init(storage: V2Storage, snapshot: Snapshot?) {
        self.storage = storage
        self.bindingStore = snapshot.map { V2Binding.BindingStore.fromSnapshot($0.binding) } ?? V2Binding.BindingStore()
        self.tombstoneStore = snapshot.map { V2Binding.TombstoneStore.fromSnapshot($0.tombstone) } ?? V2Binding.TombstoneStore()
        self.bindingKeyStore = snapshot.map { V2KeyStore.BindingKeyStore.fromSnapshot($0.bindingKeys) } ?? V2KeyStore.BindingKeyStore()
        self.authorizationStore = snapshot.map { V2Authorization.AuthorizationStore.fromSnapshot($0.authorization) } ?? V2Authorization.AuthorizationStore()
        self.groupStateStore = snapshot.map { V2GroupState.GroupStateStore.fromSnapshot($0.groupState) } ?? V2GroupState.GroupStateStore()
        self.groupKeyStore = snapshot.map { V2GroupKeyStore.fromSnapshot($0.groupKeys) } ?? V2GroupKeyStore()
        self.w2AuthorizationStore = snapshot.map { V2W2.W2AuthorizationStore.fromSnapshot($0.w2Authorization) } ?? V2W2.W2AuthorizationStore()
        self.w2DedupStore = snapshot.map { V2W2.W2DedupStore.fromSnapshot($0.w2Dedup) } ?? V2W2.W2DedupStore()
        self.outboxQueue = snapshot.map { V2OutboxQueue.fromSnapshot($0.outbox) } ?? V2OutboxQueue()
        self.pendingTxnStore = snapshot.map { V2Processor.InMemoryTxnStore.fromSnapshot($0.pendingTxn) } ?? V2Processor.InMemoryTxnStore()
        self.chatSlotStore = snapshot.map { V2SelectionCas<String>.fromSnapshot($0.chatSlot) } ?? V2SelectionCas<String>()
        self.incomingInviteStore = snapshot.map { V2IncomingInviteStore.fromSnapshot($0.incomingInvite) } ?? V2IncomingInviteStore()
        self.sentEventStore = V2SentEventStore.fromSnapshot(snapshot?.sentEvents)
        self.keyRequiredStore = KeyRequiredStore.fromSnapshot(snapshot?.keyRequired)
    }

    public static func load(storage: V2Storage) -> V2PersistedState {
        return V2PersistedState(storage: storage, snapshot: storage.load())
    }

    private func snapshot() -> Snapshot {
        return Snapshot(
            binding: bindingStore.toSnapshot(),
            tombstone: tombstoneStore.toSnapshot(),
            bindingKeys: bindingKeyStore.toSnapshot(),
            authorization: authorizationStore.toSnapshot(),
            groupState: groupStateStore.toSnapshot(),
            groupKeys: groupKeyStore.toSnapshot(),
            w2Authorization: w2AuthorizationStore.toSnapshot(),
            w2Dedup: w2DedupStore.toSnapshot(),
            outbox: outboxQueue.toSnapshot(),
            pendingTxn: pendingTxnStore.toSnapshot(),
            chatSlot: chatSlotStore.toSnapshot(),
            incomingInvite: incomingInviteStore.toSnapshot(),
            sentEvents: sentEventStore.toSnapshot(),
            keyRequired: keyRequiredStore.toSnapshot()
        )
    }

    /// Call after any operation that changed persisted state (a completed pairing, a rekey, a group
    /// COMMIT, a W2 authorization change, an outbox mutation — never after an ordinary E2 business
    /// send/receive, which touches none of the stores above). See the type doc for why a failure
    /// here never unwinds the caller.
    public func persist() {
        if isWiped { return } // a wiped state is never written back (see `wipe()`)
        storage.save(snapshot())
    }

    private let wipeLock = NSLock()
    private var wiped = false

    /// Whether `wipe()` has run for this state.
    public var isWiped: Bool {
        wipeLock.lock(); defer { wipeLock.unlock() }
        return wiped
    }

    /// SECUTG-HOOK (fix, 2026-09-27): the emergency wipe (PLAN.md 3.22) destroys v2's state too — bindings,
    /// their masters, open transactions, cached invites. `destroyKeyring` used to take v1's keyring only,
    /// so v2 history stayed readable and the in-memory runtime kept encrypting. From this call on
    /// `persist()` writes nothing, so a runtime something still holds cannot put the keys back.
    public func wipe() {
        wipeLock.lock()
        wiped = true
        wipeLock.unlock()
        storage.wipe()
    }
}
