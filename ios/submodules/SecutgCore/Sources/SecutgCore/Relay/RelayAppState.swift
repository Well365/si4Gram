import Foundation

/// The in-memory, thread-safe handle the app layer actually talks to for app-level relay state; `RelayAppStore`
/// is just the disk backend underneath. Load-once, mutate-in-memory, persist-on-every-change — the same shape
/// `V2PersistedState` uses over `V2Storage`.
public final class RelayAppState {
    private let store: RelayAppStore
    private let lock = NSLock()
    private var config: RelayAppConfig

    public init(store: RelayAppStore) {
        self.store = store
        self.config = store.load() ?? .empty
    }

    public var current: RelayAppConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    public func update(_ mutate: (inout RelayAppConfig) -> Void) {
        lock.lock()
        mutate(&config)
        let snapshot = config
        lock.unlock()
        store.save(snapshot)
    }

    /// PLAN.md 3.16 / 3.48.5: app-level relay config is cleared by the emergency wipe. (Forced-logout wipe,
    /// 3.46.2, is per-account and does NOT touch this — see `RelayAccountState.wipe`.)
    public func wipeForEmergencyWipe() {
        lock.lock()
        config = .empty
        lock.unlock()
        store.wipe()
    }
}
