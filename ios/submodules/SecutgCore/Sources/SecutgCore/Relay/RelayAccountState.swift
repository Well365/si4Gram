import Foundation

/// The in-memory, thread-safe handle for one account's relay history: sent items (PLAN.md 3.48.4 「我发出的中转
/// 内容」) and local copies (PLAN.md 3.48.7). `RelayAccountStore` is the disk backend underneath.
public final class RelayAccountState {
    private let store: RelayAccountStore
    private let lock = NSLock()
    private var snapshot: RelayAccountSnapshot

    public init(store: RelayAccountStore) {
        self.store = store
        self.snapshot = store.load() ?? .empty
    }

    public var current: RelayAccountSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    // MARK: - Sent items

    public func recordSentItem(_ item: RelaySentItem) {
        mutate { $0.sentItems.append(item) }
    }

    public func sentItem(id: String) -> RelaySentItem? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.sentItems.first { $0.id == id }
    }

    /// PLAN.md 3.48.4 长按→查看状态/撤回, and 3.48.7 §4's delete-follows-delete withdraw.
    public func markRevoked(id: String, pendingRetry: Bool = false) {
        mutate { config in
            guard let index = config.sentItems.firstIndex(where: { $0.id == id }) else { return }
            config.sentItems[index].revoked = true
            config.sentItems[index].pendingRevokeRetry = pendingRetry
        }
    }

    public func sentItem(chatId: String, messageId: Int64) -> RelaySentItem? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.sentItems.first { $0.chatId == chatId && $0.messageId == messageId }
    }

    // MARK: - Local copies (PLAN.md 3.48.7)

    public func saveLocalCopy(_ copy: RelayLocalCopy) {
        mutate { $0.localCopies[copy.key] = copy }
    }

    public func localCopy(chatId: String, messageId: Int64) -> RelayLocalCopy? {
        lock.lock(); defer { lock.unlock() }
        return snapshot.localCopies[RelayLocalCopy.key(chatId: chatId, messageId: messageId)]
    }

    /// PLAN.md 3.48.7 §3: the local copy's lifetime follows the message's — called from the deletion hook.
    public func removeLocalCopy(chatId: String, messageId: Int64) {
        mutate { $0.localCopies.removeValue(forKey: RelayLocalCopy.key(chatId: chatId, messageId: messageId)) }
    }

    public func removeLocalCopies(chatId: String, messageIds: [Int64]) {
        mutate { config in
            for id in messageIds {
                config.localCopies.removeValue(forKey: RelayLocalCopy.key(chatId: chatId, messageId: id))
            }
        }
    }

    // MARK: - Per-chat policy (PLAN.md 3.48.4 锁菜单 → 中转)

    public func chatPolicy(chatId: String) -> RelayChatPolicy {
        lock.lock(); defer { lock.unlock() }
        return snapshot.chatPolicies[chatId] ?? .default
    }

    public func setChatPolicy(chatId: String, policy: RelayChatPolicy) {
        mutate { $0.chatPolicies[chatId] = policy }
    }

    // MARK: - Wipe

    /// PLAN.md 3.16 (this account's slice) and 3.46.2 (forced-logout, whole thing): clears this account's sent
    /// items AND local copies. 3.46.2's own doc says "only clears this account's relay sent items" — local
    /// copies are included too, because 3.48.7 §5 extends both wipes to "全部本机副本".
    public func wipeAll() {
        lock.lock()
        snapshot = .empty
        lock.unlock()
        store.wipe()
    }

    // MARK: - Private

    private func mutate(_ change: (inout RelayAccountSnapshot) -> Void) {
        lock.lock()
        change(&snapshot)
        let copy = snapshot
        lock.unlock()
        store.save(copy)
    }
}
