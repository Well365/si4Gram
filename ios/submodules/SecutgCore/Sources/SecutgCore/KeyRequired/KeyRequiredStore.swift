import Foundation

/// PLAN.md 3.41.4: the per-chat `keyRequired` dictionary of one account, persisted as part of `V2PersistedState`
/// (the one persisted per-chat state the two Apple clients carry byte for byte).
///
/// Why there and not in the v1 keyring: the keyring is what a K1 transfer exports and what `mergeSnapshot` takes
/// in, and this flag must never travel (3.41.1) — a device that receives the keys re-arms itself the moment it
/// sees them. `V2PersistedState` is written only to this device's own sealed store; K2 / disaster files are built
/// from key records, never from the whole snapshot, so nothing has to be filtered out on the way. The emergency
/// wipe destroys that store outright (`V2PersistedState.wipe`), which is 3.41.1's last line for free.
///
/// The rules are `KeyRequired.observed` / `KeyRequired.toggled`; this class only keeps the records and reports
/// whether a call changed anything, so the caller knows when to persist.
public final class KeyRequiredStore {
    public struct Snapshot: Codable, Equatable {
        public var chats: [String: KeyRequired.Record]
        /// 3.41.1 `keyRequiredMigrated`: the one-time upgrade pass has run on this device.
        public var migrated: Bool

        public init(chats: [String: KeyRequired.Record] = [:], migrated: Bool = false) {
            self.chats = chats
            self.migrated = migrated
        }
    }

    private let lock = NSLock()
    private var chats: [String: KeyRequired.Record]
    private var migrated: Bool

    public init(chats: [String: KeyRequired.Record] = [:], migrated: Bool = false) {
        self.chats = chats
        self.migrated = migrated
    }

    public func record(_ chatId: String) -> KeyRequired.Record? {
        lock.lock(); defer { lock.unlock() }
        return chats[chatId]
    }

    /// The flag as the send gate reads it: absent means off.
    public func isRequired(_ chatId: String) -> Bool {
        return record(chatId)?.enabled ?? false
    }

    public var isMigrated: Bool {
        lock.lock(); defer { lock.unlock() }
        return migrated
    }

    /// Every chat whose flag is on, for a status page or a test.
    public func requiredChatIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return chats.filter { $0.value.enabled }.map { $0.key }.sorted()
    }

    /// `KeyRequired.observed` applied to the chat's record. Returns true when the record changed — the caller
    /// persists then, and only then, because this is asked on every status read and every send.
    @discardableResult
    public func observeKey(chatId: String, keyId: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = chats[chatId]
        let after = KeyRequired.observed(before, keyId: keyId)
        guard after != before else { return false }
        chats[chatId] = after
        return true
    }

    /// `KeyRequired.toggled` applied to the chat's record. Returns true when the record changed.
    @discardableResult
    public func setManually(chatId: String, enabled: Bool, currentKeyId: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let before = chats[chatId]
        let after = KeyRequired.toggled(before, enabled: enabled, currentKeyId: currentKeyId)
        guard after != before else { return false }
        chats[chatId] = after
        return true
    }

    /// 3.41.1 升级安装: arms every chat that holds a key today, once per device. `keyedChats` maps a chat id to the
    /// identity of its current send key. Returns true when the pass ran (the caller persists); false on every later
    /// call, whatever it is handed — a chat keyed after the pass is armed by `observeKey` when its key is seen.
    @discardableResult
    public func migrate(keyedChats: [String: String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !migrated else { return false }
        for (chatId, keyId) in keyedChats {
            chats[chatId] = KeyRequired.observed(chats[chatId], keyId: keyId)
        }
        migrated = true
        return true
    }

    // MARK: persistence

    public func toSnapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(chats: chats, migrated: migrated)
    }

    /// A snapshot written before 3.41 has none of this, and decodes to an empty store that has not migrated —
    /// so the upgrade pass runs exactly once, on the first launch that knows about the flag.
    public static func fromSnapshot(_ snapshot: Snapshot?) -> KeyRequiredStore {
        guard let snapshot = snapshot else { return KeyRequiredStore() }
        return KeyRequiredStore(chats: snapshot.chats, migrated: snapshot.migrated)
    }
}
