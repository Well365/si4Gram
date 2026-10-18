import Foundation

/// v2's storage-agnostic-until-now stores (every `toSnapshot`/`fromSnapshot` pair added across
/// `V2/Core`, `V2/Pairing`, `V2/Group`, `V2/Wipe` for this integration slice) finally get a real
/// backend. Deliberately mirrors `KeyRingStorage`'s shape exactly (`submodules/SecutgCore/Sources/
/// SecutgCore/Keyring/KeyRing.swift`) — one whole-snapshot `load`/`save`/`wipe`, synchronous, never
/// throwing into a caller — rather than inventing a second persistence convention. v1's keyring
/// proved this shape works for exactly this kind of "a device's local crypto state" data; v2 has no
/// reason to do it differently. Ported by analogy from the Web reference's `persist/storage.ts`
/// (there `load`/`save` are async over IndexedDB; here, like `KeyRingStorage`, they are synchronous
/// disk/Keychain I/O, so no `Promise`/`async` wrapper is needed).
public protocol V2Storage: AnyObject {
    func load() -> V2PersistedState.Snapshot?
    func save(_ snapshot: V2PersistedState.Snapshot)
    /// Removes the stored snapshot outright, matching `KeyRingStorage.wipe`'s same "empty database,
    /// not an empty snapshot" contract.
    func wipe()
}

public extension V2Storage {
    func wipe() { save(V2PersistedState.Snapshot.empty) }
}

/// In-memory `V2Storage`, the v2 analog of `MemoryKeyRingStorage` — used by tests and by
/// `initV2Worker`'s own IndexedDB/Keychain-failure fallback (mirroring the Web reference's
/// `hooks/init.ts` fallback shape).
public final class V2MemoryStorage: V2Storage {
    public private(set) var saved: V2PersistedState.Snapshot?

    public init(_ initial: V2PersistedState.Snapshot? = nil) {
        saved = initial
    }

    public func load() -> V2PersistedState.Snapshot? { return saved }
    public func save(_ snapshot: V2PersistedState.Snapshot) { saved = snapshot }
    public func wipe() { saved = nil }
}
