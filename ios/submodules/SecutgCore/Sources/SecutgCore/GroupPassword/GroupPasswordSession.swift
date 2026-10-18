import Foundation

/// PLAN.md 3.38.2 (supersedes 3.38.1's session): the three things a device does to a group's password — the admin
/// sets / changes it, the admin turns it off, anybody unlocks it for this run. The password is a gate: none of
/// this touches a master. Pure keyring work plus the one `GP1` it produces; the sending and the UI are the glue
/// layer's. Everything here that derives a key runs Argon2id (64 MiB by default), so callers keep it OFF the
/// main thread.
public enum GroupPasswordSession {
    public enum Failure: Error, Equatable {
        /// Admin rule 4: change / disable need this run to have unlocked the group first.
        case notUnlocked
        /// Only groups carry a group password (and only auto-mode ones in this batch, 3.38.1 scope).
        case notGroup
        case passwordRejected(PasswordCheck)
        case buildFailed
    }

    /// PLAN.md 3.38.2: what the admin's button sends — ONE `GP1`, nothing else.
    public struct PolicyBuilt: Equatable {
        public let broadcast: String
        /// This turned the password on for this device (it was off / absent): drop the local cache first.
        public let turnedOn: Bool
        public let policy: GroupPasswordPolicy
    }

    public enum UnlockResult: Equatable {
        case unlocked
        /// `GroupPasswordUnwrapFailure.wrongPassword`, or any other refusal — the UI says 「密码不对或数据已损坏」
        /// for all of them (3.38: wrong password and tampering are indistinguishable by design).
        case wrong(GroupPasswordUnwrapFailure)
        /// Too many wrong tries: seconds until the next one is accepted.
        case tooMany(seconds: Int64)
        /// No policy locks the group and no legacy record is on file.
        case noRecord
    }

    /// PLAN.md 3.38.2 管理员菜单 〔设置群密码〕/〔修改群密码〕: a `GP1` "on" with a fresh salt. No master is created,
    /// wrapped or sent; no `N1`, no `G2`. Changing needs this run to have unlocked the current policy (admin
    /// rule 4). Argon2id — OFF the main thread.
    public static func setPassword(ring: KeyRing, chatId: String, ownUserId: String, password: String, at: Int64,
                                   ops: Int = GroupPassword.defaultOps, mem: Int = GroupPassword.defaultMem) throws -> PolicyBuilt {
        guard chatId.hasPrefix("-") else { throw Failure.notGroup }
        let check = GroupPassword.validatePassword(password)
        guard check == .ok else { throw Failure.passwordRejected(check) }
        guard !ring.needsGroupPassword(chatId) else { throw Failure.notUnlocked }
        let params: GroupPasswordPolicyParams
        do {
            params = try GroupPassword.makePolicyParams(password: password, groupId: chatId, ops: ops, mem: mem)
        } catch {
            throw Failure.buildFailed
        }
        return try publish(ring: ring, chatId: chatId, ownUserId: ownUserId, payload: .on(params), at: at)
    }

    /// PLAN.md 3.38.2 〔关闭群密码〕: a `GP1` "off". Needs this run to have unlocked the policy (admin rule 4).
    public static func disablePassword(ring: KeyRing, chatId: String, ownUserId: String, at: Int64) throws -> PolicyBuilt {
        guard chatId.hasPrefix("-") else { throw Failure.notGroup }
        guard !ring.needsGroupPassword(chatId) else { throw Failure.notUnlocked }
        return try publish(ring: ring, chatId: chatId, ownUserId: ownUserId, payload: .off, at: at)
    }

    /// Builds the wire, then adopts it here. `at` is pushed past the policy on file so the echo — and every other
    /// device — orders it after the one it replaces even when two are sent within the same second.
    private static func publish(ring: KeyRing, chatId: String, ownUserId: String, payload: GroupPasswordPolicyPayload,
                                at: Int64) throws -> PolicyBuilt {
        let usedAt = max(at, (ring.groupPasswordPolicy(chatId)?.at ?? -1) + 1)
        guard let broadcast = GP1.build(chatId: chatId, at: usedAt, payload: payload, publisherId: ownUserId) else {
            throw Failure.buildFailed
        }
        let policy = GroupPasswordPolicy(payload: payload, at: usedAt)
        let turnedOn = ring.adoptOwnGroupPasswordPolicy(chatId: chatId, policy: policy)
        return PolicyBuilt(broadcast: broadcast, turnedOn: turnedOn, policy: policy)
    }

    /// PLAN.md 3.38.2 解锁: while the policy locks the group, the password is checked against its verifier (constant
    /// time) and the group opens for this run. Otherwise — LEGACY — it is tried against the 3.38.1 locked record
    /// (active or not), whose masters then go into the legacy unlock table.
    public static func unlock(ring: KeyRing, limiter: GroupPasswordAttemptLimiter, chatId: String,
                              password: String) -> UnlockResult {
        if let left = limiter.remainingLockout(chatId: chatId) { return .tooMany(seconds: left) }
        if ring.needsGroupPassword(chatId), let params = ring.groupPasswordPolicy(chatId)?.payload.params {
            if let failure = GroupPassword.verifyPolicy(params, password: password, groupId: chatId) {
                if let left = limiter.recordFailure(chatId: chatId) { return .tooMany(seconds: left) }
                return .wrong(failure)
            }
            ring.unlockGroupPasswordPolicy(chatId: chatId, params: params)
            limiter.recordSuccess(chatId: chatId)
            return .unlocked
        }
        return unlockLegacy(ring: ring, limiter: limiter, chatId: chatId, password: password)
    }

    /// LEGACY (3.38.1): open a stored locked record so the history it wraps can be read.
    public static func unlockLegacy(ring: KeyRing, limiter: GroupPasswordAttemptLimiter, chatId: String,
                                    password: String) -> UnlockResult {
        if let left = limiter.remainingLockout(chatId: chatId) { return .tooMany(seconds: left) }
        guard let record = ring.groupPasswordRecord(chatId) else { return .noRecord }
        switch GroupPassword.unwrapGroupKeys(record.fields, password: password, groupId: chatId) {
        case let .ok(current, history):
            do {
                try ring.unlockGroup(chatId: chatId, current: current, history: history)
            } catch {
                return .wrong(.malformed)
            }
            limiter.recordSuccess(chatId: chatId)
            return .unlocked
        case let .failure(failure):
            if let left = limiter.recordFailure(chatId: chatId) { return .tooMany(seconds: left) }
            return .wrong(failure)
        }
    }
}
