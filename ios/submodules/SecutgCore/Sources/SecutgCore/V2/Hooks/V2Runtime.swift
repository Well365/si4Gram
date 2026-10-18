import Foundation

/// Worker-side v2 runtime state — the v2 analog of `SecutgHookRegistry`/`SecutgAccountRuntime`'s own
/// per-account singleton shape (Web integration draft's `hooks/state.ts`). One
/// `V2Processor.PairingProcessor`/`V2Roster.RosterProcessor`/`V2GroupProcessor`/`V2DataProcessor`/
/// messaging pair per device, matching how each of those classes is already designed (constructed
/// once, handling every chat/group internally via the chatId/groupId keys already threaded through
/// their own stores) — never one instance per chat.
///
/// `V2Processor.PairingProcessor`'s own `syncGate` is intentionally NOT restored from
/// `V2PersistedState` — `V2SyncGate`'s own module doc: a fresh connection always re-enters
/// CATCHING_UP. `V2DataProcessor`'s internal outbox/dedup maps are ALSO not persisted in this
/// slice — the same known, bounded gap the Web reference notes for its `E2Processor`.
///
/// SECUTG-HOOK (fix E1): its `pending` transaction store and per-chat `chatSlot` CAS now ARE
/// restored from `V2PersistedState` (`pendingTxnStore`/`chatSlotStore` below) — previously these
/// were always freshly constructed in-memory here regardless of what `persisted` held, which is
/// exactly why a restart mid-pairing used to lose the in-flight exchange back to "unknown_txn".
public final class V2Runtime {
    public let identity: V2Identity
    public let persisted: V2PersistedState
    public let pairing: V2Processor.PairingProcessor
    public let roster: V2Roster.RosterProcessor
    /// PLAN.md 3.39.13: clone a 1v1 binding onto this account's other device by QR (`V2JoinCoordinator`).
    public let join: V2JoinCoordinator
    public let group: V2GroupProcessor
    public let e2: V2DataProcessor
    public let privateMessaging: V2PrivateChatMessaging
    public let groupMessaging: V2GroupMessaging
    /// The clock every processor here was built with — for the few rules that live outside them
    /// (`V2CloneSibling`).
    public let now: () -> Int64

    public init(identity: V2Identity, persisted: V2PersistedState, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.identity = identity
        self.persisted = persisted
        self.now = now
        self.pairing = V2Processor.PairingProcessor(
            identity: identity, now: now,
            pendingStore: persisted.pendingTxnStore, chatSlotStore: persisted.chatSlotStore,
            bindingStore: persisted.bindingStore, tombstoneStore: persisted.tombstoneStore,
            authorizationStore: persisted.authorizationStore, keyStore: persisted.bindingKeyStore
        )
        self.roster = V2Roster.RosterProcessor(
            identity: identity, bindingStore: persisted.bindingStore, tombstoneStore: persisted.tombstoneStore,
            keyStore: persisted.bindingKeyStore, now: now
        )
        self.join = V2JoinCoordinator(identity: identity, pairing: self.pairing, now: now)
        self.group = V2GroupProcessor(identity: identity, stateStore: persisted.groupStateStore, now: now, keyStore: persisted.groupKeyStore)
        self.e2 = V2DataProcessor()
        self.privateMessaging = V2PrivateChatMessaging(identity: identity, pairing: self.pairing, e2: self.e2)
        self.groupMessaging = V2GroupMessaging(identity: identity, group: self.group, e2: self.e2)
        // SECUTG-HOOK (fix C0, 2026-09-27): every runtime is built from persisted state here (real
        // startup goes through `V2Bootstrap.initV2Worker`), so this is where state written before
        // `PendingTxn.localChatId` existed gets re-filed from our own user id to the real chat — see
        // `PairingProcessor.repairResponderTxnsFiledUnderOwnUserId`. Idempotent; persists only on change.
        let repairedSelfChat = pairing.repairResponderTxnsFiledUnderOwnUserId()
        // SECUTG-HOOK (fix, 2026-09-27 真机): and bindings installed under an identity this device no longer has
        // (it was replaced) are dropped, so those chats read as unpaired and can pair afresh instead of failing
        // every E2 with bad_signature — see `PairingProcessor.dropBindingsWithoutOwnIdentity`.
        // PLAN.md 3.39.13: a 3.39.12 add_device join still waiting for its commit (own device not in `deviceKeys`) has
        // no exemption any more — that flow is gone, so it is demoted like any stale binding (masters kept).
        let droppedForeignBindings = pairing.dropBindingsWithoutOwnIdentity()
        if repairedSelfChat || !droppedForeignBindings.isEmpty { persisted.persist() }
    }

    /// PLAN.md 3.39.13 「必改项」 1: records a P2 wire THIS device built, at build time — before anything sends it or
    /// runs a local copy of it back through the receive path — so its echo reads as this device's own and not its
    /// clone's. Not a P2 envelope → ignored. The caller persists (every dispatch entry point already does).
    public func noteSent(_ wire: String) {
        guard let envelope = V2Envelope.parse(prefix: V2Messages.prefix, text: wire) else { return }
        persisted.sentEventStore.record(eventId: envelope.eventId, createdMs: Int64(envelope.createdMs) ?? 0)
    }
}

/// One `V2Runtime` per account, keyed the same way `SecutgHookRegistry` keys `SecutgAccountRuntime`
/// (by account) — just by a plain `String` account key here, since this package does not import
/// Postbox and has no `PeerId` type of its own. Callers in the runtime layer key by whatever they
/// already use to identify an account (e.g. the account's own v2 `userId`).
public final class V2RuntimeRegistry {
    public static let shared = V2RuntimeRegistry()
    private let lock = NSLock()
    private var byAccount: [String: V2Runtime] = [:]

    public func set(_ runtime: V2Runtime?, for accountKey: String) {
        lock.lock(); defer { lock.unlock() }
        byAccount[accountKey] = runtime
    }

    public func runtime(for accountKey: String) -> V2Runtime? {
        lock.lock(); defer { lock.unlock() }
        return byAccount[accountKey]
    }

    public func reset(for accountKey: String) {
        lock.lock(); defer { lock.unlock() }
        byAccount.removeValue(forKey: accountKey)
    }
}
