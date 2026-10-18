import Foundation

/// PLAN.md 3.38.1 member rule 1: what a device keeps for a group whose key arrived password-protected. The
/// `pw` fields exactly as received — never a master in the clear.
public struct GroupPasswordRecord: Equatable {
    public let fields: GroupPasswordLockedFields
    /// The `at` of the `G2` that carried it: the newer record wins a keyring merge.
    public let at: Int64
    /// The group's CURRENT key is this locked one. False once the admin turned the password off (member rule 6)
    /// or a retire notice announced a newer generation: the record is then kept only so the old history can
    /// still be opened with the old password.
    public let active: Bool
    /// A plain key has since replaced this one (the admin turned the password off). Distinct from `active`,
    /// which a retire notice also clears while the next generation is still on its way.
    public let superseded: Bool

    public init(fields: GroupPasswordLockedFields, at: Int64, active: Bool, superseded: Bool = false) {
        self.fields = fields
        self.at = at
        self.active = active
        self.superseded = superseded
    }

    public func with(active: Bool, superseded: Bool? = nil) -> GroupPasswordRecord {
        return GroupPasswordRecord(fields: fields, at: at, active: active, superseded: superseded ?? self.superseded)
    }

    /// Storage and the network are untrusted: anything that could never be unwrapped is not a record.
    public var isValid: Bool {
        return at >= 0 && fields.version == GroupPassword.version && fields.kdf == GroupPassword.kdfArgon2id13
            && GroupPassword.paramsInRange(ops: fields.ops, mem: fields.mem)
            && fields.salt.count == GroupPassword.saltBytes && fields.wrap.count == GroupPassword.wrapBytes
            && fields.hist.count <= GroupPassword.historyMax
            && fields.hist.allSatisfy { $0.count == GroupPassword.wrapBytes }
    }
}

/// PLAN.md 3.38.1 member rule 4: one entry of the session unlock table. Memory only.
public struct GroupPasswordUnlocked: Equatable {
    public let currentId: String
    public let current: [UInt8]
    /// Oldest first, as the wrap carried them.
    public let history: [[UInt8]]
    /// master_id → master, current included: what `lookupSessionKey` consults.
    public let byId: [String: [UInt8]]

    public init(current: [UInt8], history: [[UInt8]]) throws {
        self.currentId = try KeyDerivation.computeMasterId(current)
        self.current = current
        self.history = history
        var byId = [currentId: current]
        for key in history { byId[try KeyDerivation.computeMasterId(key)] = key }
        self.byId = byId
    }
}

/// PLAN.md 3.38.1: the keyring half of 群密码 — the persisted locked record and the in-memory unlock table.
///
/// LEGACY since PLAN.md 3.38.2: no client produces locked records any more (the password is now a gate, see
/// `GroupPasswordPolicyKeyRing.swift`). This stays so a `pw=1` `G2` already in a group's history, and a record
/// already stored on a test device, can still be read and opened with the old password.
///
/// The red line of 3.34.5 ("unbind, never destroy") is deliberately broken here and ONLY here, because 3.38.1
/// member rule 1 says so: once a group's key arrives locked, this device must no longer hold the group's masters
/// in the clear. They are not lost — the admin wrapped them into `hist` — but they open only with the password.
extension KeyRing {
    static let maxMasterHistory = 32

    /// Called with the lock held, from `setChatMaster`.
    func noteMasterHistoryLocked(chatId: String, masterId: String) {
        var ids = state.chatMasterHistory[chatId] ?? []
        guard ids.last != masterId else { return }
        ids.removeAll { $0 == masterId }
        ids.append(masterId)
        state.chatMasterHistory[chatId] = Array(ids.suffix(KeyRing.maxMasterHistory))
    }

    func activeUnlockedMasterIdLocked(_ chatId: String) -> String? {
        guard state.chatGroupPasswords[chatId]?.active == true else { return nil }
        return unlockedGroups[chatId]?.currentId
    }

    func unlockedMasterLocked(_ masterId: String) -> [UInt8]? {
        for (_, entry) in unlockedGroups {
            if let key = entry.byId[masterId] { return key }
        }
        return nil
    }

    private func purgeSessionsLocked(masterIds: Set<String>) {
        guard !masterIds.isEmpty else { return }
        let dead = { (keyId: String) -> Bool in
            guard let dot = keyId.firstIndex(of: ".") else { return false }
            return masterIds.contains(String(keyId[..<dot]))
        }
        for key in sessionCache.keys where dead(key) { sessionCache.removeValue(forKey: key) }
        sessionOrder.removeAll(where: dead)
    }

    // MARK: reads

    public func groupPasswordRecord(_ chatId: String) -> GroupPasswordRecord? {
        lock.lock(); defer { lock.unlock() }
        return state.chatGroupPasswords[chatId]
    }

    public func isGroupPasswordUnlocked(_ chatId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return unlockedGroups[chatId] != nil
    }

    /// LEGACY (3.38.1 records only, superseded by 3.38.2): a locked record is on file for the group and this run
    /// has not opened it, so the history it wraps cannot be read yet. Offers 〔解锁〕; it no longer gates the chat —
    /// the gate is the policy's (`needsGroupPassword`).
    public func needsLegacyGroupPassword(_ chatId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.chatGroupPasswords[chatId] != nil && unlockedGroups[chatId] == nil
    }

    /// The masters the admin rewraps on set / change (admin rule 2): everything this device knows for the
    /// group, oldest first — what an earlier password opened, then the masters bound here since, then the one
    /// bound now. `GroupPassword.normaliseHistory` dedupes and keeps the newest 16.
    public func groupPasswordRewrapHistory(_ chatId: String) -> [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        var out: [[UInt8]] = []
        if let unlocked = unlockedGroups[chatId] { out += unlocked.history + [unlocked.current] }
        for id in state.chatMasterHistory[chatId] ?? [] {
            if let key = state.masters[id] { out.append(key) }
        }
        if let id = state.chatMasters[chatId], let key = state.masters[id] { out.append(key) }
        return out
    }

    // MARK: writes

    /// Member rule 1: adopt a locked group key. Deletes this group's masters held in the clear (the ones bound
    /// to it here, never one another chat is using), unbinds the chat, stores the record and forgets any earlier
    /// unlock of this group (the new generation needs the password again).
    ///
    /// - Returns: true when this is the FIRST locked record this device has for the group (member rule 2).
    @discardableResult
    public func adoptLockedGroupKey(chatId: String, record: GroupPasswordRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return adoptLockedLocked(chatId: chatId, record: record)
    }

    private func adoptLockedLocked(chatId: String, record: GroupPasswordRecord) -> Bool {
        let isFirst = state.chatGroupPasswords[chatId] == nil
        var doomed = Set(state.chatMasterHistory[chatId] ?? [])
        if let current = state.chatMasters[chatId] { doomed.insert(current) }
        let usedElsewhere = Set(state.chatMasters.filter { $0.key != chatId }.map { $0.value })
        doomed.subtract(usedElsewhere)
        for id in doomed {
            state.masters.removeValue(forKey: id)
            state.masterCreatedAt.removeValue(forKey: id)
        }
        state.chatMasters.removeValue(forKey: chatId)
        state.chatKeyLabels.removeValue(forKey: chatId)
        state.chatMasterHistory.removeValue(forKey: chatId)
        _ = clearChatProvenanceLocked(chatId)
        state.chatGroupPasswords[chatId] = record
        state.encryptionLost.remove(chatId)
        var purged = doomed
        if let old = unlockedGroups.removeValue(forKey: chatId) { purged.formUnion(old.byId.keys) }
        purgeSessionsLocked(masterIds: purged)
        persist()
        return isFirst
    }

    /// Admin rule 2: the admin's own device adopts what it is about to send and, since the password was just
    /// typed, keeps the opened masters for this run so nobody has to type it again straight away.
    @discardableResult
    public func adoptOwnLockedGroupKey(chatId: String, record: GroupPasswordRecord, current: [UInt8], history: [[UInt8]]) throws -> Bool {
        let unlocked = try GroupPasswordUnlocked(current: current, history: history)
        lock.lock(); defer { lock.unlock() }
        let isFirst = adoptLockedLocked(chatId: chatId, record: record)
        unlockedGroups[chatId] = unlocked
        return isFirst
    }

    /// Member rule 6 (the admin turned the password off) and the auto-mode retire notice: the locked key is no
    /// longer the group's current one. The record stays, to open the old history with the old password.
    ///
    /// - Returns: whether it was active before.
    @discardableResult
    public func deactivateGroupPassword(_ chatId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let record = state.chatGroupPasswords[chatId], record.active else { return false }
        state.chatGroupPasswords[chatId] = record.with(active: false)
        persist()
        return true
    }

    /// Member rule 4: the password opened the record; its masters go into the unlock table for this run.
    public func unlockGroup(chatId: String, current: [UInt8], history: [[UInt8]]) throws {
        let unlocked = try GroupPasswordUnlocked(current: current, history: history)
        lock.lock(); defer { lock.unlock() }
        unlockedGroups[chatId] = unlocked
    }

    /// Member rule 6: a plain key was just bound for the group. Returns true when that turned the group password
    /// OFF — a locked record existed and no plain key had replaced it yet — which is when the line says so.
    @discardableResult
    public func supersedeGroupPassword(_ chatId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let record = state.chatGroupPasswords[chatId], !record.superseded else { return false }
        state.chatGroupPasswords[chatId] = record.with(active: false, superseded: true)
        persist()
        return true
    }

    /// Empties both unlock tables — the legacy one and the 3.38.2 policy one (emergency wipe; `destroyAllKeys`
    /// does this too).
    public func clearGroupUnlocks() {
        lock.lock(); defer { lock.unlock() }
        purgeSessionsLocked(masterIds: Set(unlockedGroups.values.flatMap { $0.byId.keys }))
        unlockedGroups.removeAll()
        unlockedPolicies.removeAll()
    }
}
