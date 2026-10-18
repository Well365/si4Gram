import Foundation

/// PLAN.md 3.38.2: the keyring half of the group-password GATE — the persisted per-group policy and the in-memory
/// unlock table keyed by it. Nothing here reads or writes a master: whether a message decrypts never depends on
/// the policy.
extension KeyRing {
    /// Called with the lock held. "Locked" = the policy is on and this run has not checked a password against
    /// exactly this policy.
    func policyLockedLocked(_ chatId: String) -> Bool {
        guard let params = state.chatGroupPasswordPolicies[chatId]?.payload.params else { return false }
        return unlockedPolicies[chatId] != params
    }

    // MARK: reads

    public func groupPasswordPolicy(_ chatId: String) -> GroupPasswordPolicy? {
        lock.lock(); defer { lock.unlock() }
        return state.chatGroupPasswordPolicies[chatId]
    }

    public func isGroupPasswordOn(_ chatId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.chatGroupPasswordPolicies[chatId]?.isOn == true
    }

    /// The policy is on and this run checked a password against it.
    public func isGroupPasswordPolicyUnlocked(_ chatId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let params = state.chatGroupPasswordPolicies[chatId]?.payload.params else { return false }
        return unlockedPolicies[chatId] == params
    }

    /// PLAN.md 3.38.2 "上锁": policy on and not unlocked in this run. Drives the password page, the masking, the
    /// send refusal and the forced 3.19 storage. Never consulted by decryption.
    public func needsGroupPassword(_ chatId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return policyLockedLocked(chatId)
    }

    // MARK: writes

    /// Adopts a policy the processor has judged `apply` (or the admin's own). An "off" policy also forgets this
    /// run's unlock of the group.
    ///
    /// - Returns: true when this adoption turned the group's password ON on this device (no policy before, or
    ///   one that was off) — the moment the local message cache is dropped (3.38.2).
    @discardableResult
    public func adoptGroupPasswordPolicy(chatId: String, policy: GroupPasswordPolicy) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return adoptPolicyLocked(chatId: chatId, policy: policy)
    }

    private func adoptPolicyLocked(chatId: String, policy: GroupPasswordPolicy) -> Bool {
        let wasOn = state.chatGroupPasswordPolicies[chatId]?.isOn == true
        state.chatGroupPasswordPolicies[chatId] = policy
        if !policy.isOn { unlockedPolicies.removeValue(forKey: chatId) }
        persist()
        return policy.isOn && !wasOn
    }

    /// The admin's own set / change: adopt what is about to be sent and, since the password was just typed,
    /// count this run as unlocked for it.
    @discardableResult
    public func adoptOwnGroupPasswordPolicy(chatId: String, policy: GroupPasswordPolicy) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let turnedOn = adoptPolicyLocked(chatId: chatId, policy: policy)
        if let params = policy.payload.params { unlockedPolicies[chatId] = params }
        return turnedOn
    }

    /// A password was verified against `params`. Recorded only if that is still the group's policy — a check
    /// that raced a newer `GP1` unlocks nothing.
    @discardableResult
    public func unlockGroupPasswordPolicy(chatId: String, params: GroupPasswordPolicyParams) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state.chatGroupPasswordPolicies[chatId]?.payload.params == params else { return false }
        unlockedPolicies[chatId] = params
        return true
    }
}
