import Foundation

/// PLAN.md 3.46.2 §1: telling a forced server-side session revocation apart from every USER-initiated logout on
/// this device. TelegramCore's `account.loggedOut` fires identically for both — the user tapping Settings →
/// 退出登录, the emergency wipe (3.16), the GDPR self-delete, *and* another device ending this session, or the
/// server invalidating it. Every call site that is about to log this account out on the user's own instruction
/// registers the account first (`markUserInitiated`); the `account.loggedOut` handler consumes the mark exactly
/// once. Present means this device asked for it — nothing more happens. Absent means the server revoked the
/// session out from under it — the per-account wipe (PLAN.md 3.46.2 §1) runs before `logoutFromAccount`.
///
/// Web reference: none — iOS/macOS are the only clients that cannot distinguish the two kinds of logout at the
/// network layer (3.46.2's own note), so they alone need this registration scheme.
public enum LogoutIntent {
    /// Pure core of the registry: consuming `accountKey` out of a snapshot of what is registered. Returns whether
    /// it was there and the set with it removed — a mark is consumed at most once, by design (a second, unrelated
    /// forced logout of the same account later must not be silently swallowed by a stale mark).
    public static func consuming(_ registered: Set<String>, accountKey: String) -> (wasRegistered: Bool, remaining: Set<String>) {
        var remaining = registered
        let wasRegistered = remaining.remove(accountKey) != nil
        return (wasRegistered, remaining)
    }
}

/// Thread-safe wrapper over `LogoutIntent`, one per process. `accountKey` is the account's `AccountRecordId` as
/// a decimal string (stable before and after login, and what every `logoutFromAccount` call site already has on
/// hand) — never a peer id, which a not-yet-authorized record does not have.
public final class LogoutIntentRegistry {
    public static let shared = LogoutIntentRegistry()

    private let lock = NSLock()
    private var registered: Set<String> = []

    public init() {}

    public func markUserInitiated(accountKey: String) {
        lock.lock()
        registered.insert(accountKey)
        lock.unlock()
    }

    /// Removes and returns whether `accountKey` was marked. Call exactly once per `account.loggedOut` event.
    @discardableResult
    public func consumeUserInitiated(accountKey: String) -> Bool {
        lock.lock()
        let (wasRegistered, remaining) = LogoutIntent.consuming(registered, accountKey: accountKey)
        registered = remaining
        lock.unlock()
        return wasRegistered
    }
}
