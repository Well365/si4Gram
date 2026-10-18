import Foundation

/// PLAN.md 3.46: the runtime half of the check-up snapshot, read straight from the keyring and the v2 state —
/// both of which this package owns, so iOS and macOS share one reader. It hands back states, times and counts
/// only: no message text, no key bytes, no key ids. Nothing here is stored or logged.
/// Web reference: `src/secutg/hooks/auditMethods.ts`.
public enum SecurityAuditReader {
    /// PLAN.md 3.39.13: a binding whose transaction came from a V2Q clone / join.
    static let cloneTxnPrefixes = ["clone:", "join:"]

    /// A binding installed from a V2Q clone / join (check 6; PLAN.md 3.46.1 step 3 reads the same answer).
    public static func isClonedBinding(_ b: V2Binding) -> Bool {
        return b.ownIdentity != nil || cloneTxnPrefixes.contains(where: { b.txnId.hasPrefix($0) })
    }

    /// `ownUserId` is this account's own user id (Saved Messages is the chat with it). `hasUsableKey` lets the
    /// runtime answer with its own rule when it has one; the default asks the keyring and the v2 binding.
    /// `plaintextOnDisk` stays false: see `RuntimePart` users for why each client reports what it can.
    public static func runtimePart(ring: KeyRing, v2: V2Runtime?, ownUserId: String,
                                   hasUsableKey: ((String) -> Bool)? = nil) -> SecurityAuditFacts.RuntimePart {
        let chatIds = candidateChatIds(ring: ring, v2: v2)
        let pairings = ring.listChatPairings()
        let keyRequired = v2?.persisted.keyRequiredStore.toSnapshot().chats ?? [:]
        var chats: [SecurityAuditFacts.ChatFacts] = []
        for chatId in chatIds {
            guard let kind = kindOf(chatId, ownUserId: ownUserId) else { continue }
            let hasKey = hasUsableKey?(chatId) ?? defaultHasUsableKey(ring: ring, v2: v2, chatId: chatId, kind: kind)
            let v2Part = kind == .privateChat || kind == .saved ? v2Facts(v2, chatId: chatId) : (nil, nil, nil)
            let isPasswordOn = kind == .group && ring.isGroupPasswordOn(chatId)
            chats.append(SecurityAuditFacts.ChatFacts(
                chatId: chatId,
                kind: kind,
                hasKey: hasKey,
                v1Pairing: pairings[chatId].map { SecurityAuditFacts.V1Pairing(state: $0.state.rawValue, verified: $0.verified) },
                v2Binding: v2Part.0,
                v2Transaction: v2Part.1,
                v2Invite: v2Part.2,
                groupKeyCreatedMs: kind == .group ? ring.auditKeyCreatedAtMs(chatId) : nil,
                groupPassword: isPasswordOn ? (active: true, unlocked: ring.isGroupPasswordPolicyUnlocked(chatId)) : nil,
                keyRequired: keyRequired[chatId].map { SecurityAuditFacts.KeyRequiredFacts(isOn: $0.enabled, offHadKey: $0.manualOffKeyId != nil) },
                plaintextOnDisk: false))
        }
        return SecurityAuditFacts.RuntimePart(
            chats: chats,
            localCiphertext: ring.getLocalCiphertext(),
            wipePhraseSet: !(ring.getWipeCustomPhrase() ?? "").isEmpty,
            wipeListens: ring.getWipeListensToPhrase(),
            lastKeyChangeMs: lastKeyChangeMs(ring: ring, v2: v2, chatIds: chatIds))
    }

    /// Every chat this device knows anything encrypted about, sorted (code-unit order) so the page is stable.
    public static func candidateChatIds(ring: KeyRing, v2: V2Runtime?) -> [String] {
        var ids = Set(ring.listKeyedChatIds())
        ids.formUnion(ring.listChatPairings().keys)
        ids.formUnion(ring.auditGroupPasswordChatIds())
        if let v2 = v2 {
            ids.formUnion(v2.persisted.keyRequiredStore.toSnapshot().chats.keys)
            ids.formUnion(v2.pairing.bindingStore.allChatIdsWithCurrentBinding())
            // v2 groups (PLAN.md 3.34): a device whose only encrypted chats are v2 groups still gets checks 3 and 7
            ids.formUnion(v2.persisted.groupStateStore.allGroupIds())
            ids.formUnion(v2.persisted.incomingInviteStore.toSnapshot().wires.keys)
            ids.formUnion(v2.persisted.pendingTxnStore.values().filter { $0.phase != .done }.map { $0.localChatId })
        }
        return ids.sorted { SecurityAudit.compareCodeUnits($0, $1) < 0 }
    }

    /// private / group / saved from the shared chat id (PLAN.md 3.21's `SharedChatId`); nil for anything else.
    public static func kindOf(_ chatId: String, ownUserId: String) -> SecurityAudit.ChatKind? {
        guard let decoded = SharedChatId.decode(chatId) else { return nil }
        switch decoded.kind {
        case .user: return chatId == ownUserId ? .saved : .privateChat
        case .basicGroup, .channel: return .group
        }
    }

    /// 3.41.2's "usable send key", read-only: v2 first (as the send path), then a v1 master on file or unlocked.
    /// Never `ring.currentKey` — that walks a forward-secrecy ratchet forward, drops older masters and persists the
    /// keyring; a check-up must not change what it reads (as Web's and Android's readers).
    static func defaultHasUsableKey(ring: KeyRing, v2: V2Runtime?, chatId: String, kind: SecurityAudit.ChatKind) -> Bool {
        if let v2 = v2 {
            if kind == .group, v2.group.canSend(chatId) { return true }
            if kind == .privateChat, v2.pairing.bindingStore.canSend(chatId) { return true }
        }
        return ring.auditHasMaster(chatId)
    }

    /// The v2 binding, a live transaction without a binding, and a live cached INVITE — judged the way
    /// `V2PairingStatus.of` judges them for the lock menu.
    static func v2Facts(_ v2: V2Runtime?, chatId: String) -> (SecurityAuditFacts.V2Binding?, SecurityAuditFacts.V2Transaction?, SecurityAuditFacts.V2Invite?) {
        guard let v2 = v2 else { return (nil, nil, nil) }
        let pairing = v2.pairing
        let binding = pairing.bindingStore.current(chatId)
        let bindingFacts = binding.map { b in
            SecurityAuditFacts.V2Binding(verified: b.verified, suspended: b.suspended, mismatch: b.mismatch,
                                         mismatchOverride: b.mismatchOverride,
                                         cloned: isClonedBinding(b))
        }

        var transaction: SecurityAuditFacts.V2Transaction?
        var isLiveTxn = false
        if let txnId = pairing.currentTransactionForChat(chatId), let phase = pairing.phaseOf(txnId), phase != .done,
           !pairing.isOwnInviteExpired(txnId) {
            isLiveTxn = true
            if binding == nil { transaction = phase == .conflict ? .conflict : .waiting }
        }

        var invite: SecurityAuditFacts.V2Invite?
        // An invite this device is already answering (a live transaction) is not "waiting for you" any more
        if let wire = v2.persisted.incomingInviteStore.get(chatId), !pairing.isInviteExpired(wire), !(isLiveTxn && binding == nil) {
            let parsed = V2Messages.parseInvite(wire)
            let isNewer = binding.map { V2PairingDispatch.isInviteNewer(thanBindingInstalledAtMs: $0.installedAtMs, inviteWire: wire) } ?? true
            let isUnknown: Bool
            if let binding = binding, let parsed = parsed {
                // PLAN.md 3.43: an invite from an identity this binding has never seen
                isUnknown = !binding.deviceKeys.values.contains { $0.identityPk == parsed.body.identityPk }
            } else {
                isUnknown = false
            }
            invite = SecurityAuditFacts.V2Invite(isNewerThanBinding: isNewer, isUnknownIdentity: isUnknown)
        }
        return (bindingFacts, transaction, invite)
    }

    /// The newest key this device made or received, any chat: a keyring master or a v2 binding. A forward-secrecy
    /// (ratchet) chat is left out — each epoch step stores a freshly derived master, but any backup that holds the
    /// chain derives it forward, so a step is not a key change the backup has missed.
    static func lastKeyChangeMs(ring: KeyRing, v2: V2Runtime?, chatIds: [String]) -> Int64? {
        var times = chatIds.filter { ring.chatRatchet($0) == nil }.compactMap { ring.auditKeyCreatedAtMs($0) }
        if let v2 = v2 {
            times += v2.pairing.bindingStore.toSnapshot().current.map { $0.installedAtMs }
        }
        return times.max()
    }
}

extension KeyRing {
    /// When the chat's current master was stored on this device (ms); nil without one. The precise time behind
    /// `keyAgeDays`, which check 7 needs to compare with the last backup.
    public func auditKeyCreatedAtMs(_ chatId: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard let masterId = state.chatMasters[chatId] else { return nil }
        return state.masterCreatedAt[masterId]
    }

    /// A v1 master on file for the chat, or the one its group password opened this run — without touching a
    /// ratchet (unlike `currentKey`).
    public func auditHasMaster(_ chatId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.chatMasters[chatId] != nil || activeUnlockedMasterIdLocked(chatId) != nil
    }

    /// Every group whose password policy (PLAN.md 3.38.2) is on.
    public func auditGroupPasswordChatIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return state.chatGroupPasswordPolicies.filter { $0.value.isOn }.map { $0.key }
    }
}
