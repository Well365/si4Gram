import Foundation

/// PLAN.md 3.38 item 5 / 3.38.1 member rule 4: 5 wrong passwords in a row lock this group's password prompt for
/// 60 seconds. Counted on this device, in memory, per group. It only slows a person at the keyboard; offline
/// guessing is what Argon2id's cost is for.
public final class GroupPasswordAttemptLimiter {
    public static let maxFailures = 5
    public static let lockoutSeconds: Int64 = 60

    public typealias Clock = () -> Int64

    private let clock: Clock
    private let lock = NSLock()
    private var failures: [String: Int] = [:]
    private var lockedUntil: [String: Int64] = [:]

    /// `clock` returns unix SECONDS.
    public init(clock: @escaping Clock = { Int64(Date().timeIntervalSince1970) }) {
        self.clock = clock
    }

    /// Seconds left before this group may be tried again, or nil when it may be tried now.
    public func remainingLockout(chatId: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return remainingLocked(chatId)
    }

    private func remainingLocked(_ chatId: String) -> Int64? {
        guard let until = lockedUntil[chatId] else { return nil }
        let left = until - clock()
        if left > 0 { return left }
        lockedUntil.removeValue(forKey: chatId)
        failures.removeValue(forKey: chatId)
        return nil
    }

    /// A wrong password. Returns the lockout in seconds when this one reached the limit, else nil.
    @discardableResult
    public func recordFailure(chatId: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        if let left = remainingLocked(chatId) { return left }
        let count = (failures[chatId] ?? 0) + 1
        guard count >= GroupPasswordAttemptLimiter.maxFailures else {
            failures[chatId] = count
            return nil
        }
        failures.removeValue(forKey: chatId)
        lockedUntil[chatId] = clock() + GroupPasswordAttemptLimiter.lockoutSeconds
        return GroupPasswordAttemptLimiter.lockoutSeconds
    }

    public func recordSuccess(chatId: String) {
        lock.lock(); defer { lock.unlock() }
        failures.removeValue(forKey: chatId)
        lockedUntil.removeValue(forKey: chatId)
    }

    /// Emergency wipe: a wiped device keeps no trace, not even a count.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        failures.removeAll()
        lockedUntil.removeAll()
    }
}
