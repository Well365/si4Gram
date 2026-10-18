import Foundation

/// Masters keyed by master_id, per-chat sending master, per-chat encryption switch, the epoch label of the R1
/// that bound it (anti-rollback), the admin's Ed25519 public key per chat and members' X25519 keys.
/// Session keys are derived on demand and cached. Persistence goes through `KeyRingStorage`; the apps wrap it
/// with the Keychain. All methods are synchronous and serialised on an internal lock because the receive hook
/// runs inline in message parsing.
/// What `mergeSnapshot` changed, so the UI can report the import instead of silently overwriting (PLAN.md 3.14).
public struct KeyRingMergeResult: Equatable {
    public var addedMasters: Int = 0
    /// chats whose sending key now comes from the imported snapshot
    public var boundChats: [String] = []
    /// chats left alone because this device already had a newer binding
    public var skippedChats: [String] = []
    /// an existing, different identity was replaced by the imported one
    public var identityReplaced: Bool = false

    public init() {}
}

public final class KeyRing {
    /// Plain byte maps so any storage can serialise it.
    public struct Snapshot: Equatable {
        public var masters: [String: [UInt8]] = [:]
        public var chatMasters: [String: String] = [:]
        public var chatKeyLabels: [String: String] = [:]
        public var chatEncryption: [String: Bool] = [:]
        public var chatAdminPks: [String: [UInt8]] = [:]
        /// chatId → admin Ed25519 secret key, only on the device that created the chat's key
        public var chatAdminSks: [String: [UInt8]] = [:]
        /// chatId → userId → 32-byte X25519 public key
        public var memberPks: [String: [String: [UInt8]]] = [:]
        /// chatId → userId → Ed25519 public key (signs R1 in auto-paired chats)
        public var memberEdPks: [String: [String: [UInt8]]] = [:]
        public var identityX25519Pk: [UInt8]?
        public var identityX25519Sk: [UInt8]?
        public var identityEd25519Pk: [UInt8]?
        public var identityEd25519Sk: [UInt8]?
        /// chatId → one-to-one auto-pairing state (PLAN.md 3.7)
        public var chatPairings: [String: Pairing] = [:]
        /// masterId → when this device stored it (ms), for the rekey reminder
        public var masterCreatedAt: [String: Int64] = [:]
        /// chatId → forward-secrecy ratchet state (PLAN.md 3.8)
        public var chatRatchets: [String: Ratchet] = [:]
        /// chatId → how this device obtained the chat's key (PLAN.md 3.13)
        public var chatKeySources: [String: ChatKeySource] = [:]
        /// chatId → how this generation of the chat's key reaches members (PLAN.md 3.34.1).
        ///
        /// Travels with the key so both halves know what to do without asking anyone: a member's client knows
        /// whether to wait for the key or to go and scan for it, and a key-holding admin knows whether to hand
        /// it out automatically. Absent means `manual`, which is the half that waits for a person.
        public var chatKeyModes: [String: Rekey.KeyMode] = [:]
        /// chatId → `at` (unix seconds) of the last retire notice this device obeyed for the chat, or of its own
        /// rebuild (PLAN.md 3.34.3 rule 3, as amended 2026-09-19).
        ///
        /// The replay guard. A notice that does not name the key this device trusts is NOT thereby stale — a
        /// member who missed a generation, a member who never had a key, an admin who started over all meet
        /// one, and refusing those is what stopped auto mode from ever pairing anybody. What decides instead is
        /// whether the notice is NEWER than the last one obeyed. Travels with the key: a transferred keyring
        /// that forgot this would re-obey an old notice out of the history and unbind the key it just carried.
        public var chatNoticeAts: [String: Int64] = [:]
        /// group chatId → userId → level of the private chat the admin sent the key through (admin device only)
        public var groupOnlineInvites: [String: [String: OnlineInviteLevel]] = [:]
        /// PLAN.md 3.19: whether an encrypted chat keeps only the envelope on disk. A preference, not a secret,
        /// and on unless the user turned it off.
        public var localCiphertext: Bool = true

        // MARK: emergency-wipe preferences (PLAN.md 3.16 items 5-10, 3.22)
        // Preferences, not secrets, but the wipe clears them back to these defaults all the same —
        // a wiped device is a brand-new device and keeps no trace of how it was once configured
        // (PLAN.md 3.16 item 10). They ride along with the ring so they survive a relaunch.

        /// PLAN.md 3.16 item 5 (`wipeNeedsConfirmation`, default on): tapping the wipe row asks first.
        public var wipeNeedsConfirmation: Bool = true
        /// PLAN.md 3.16 item 7 / 3.22.2 (`wipeCustomPhrase`, default empty): an extra Saved Messages
        /// phrase this device also answers to. Additive — the built-in phrase is always armed too.
        /// Stored in the clear on purpose (3.22.2): Saved Messages is owner-only and the phrase is
        /// not a defence line; anyone who can read this file could press the wipe button anyway.
        public var wipeCustomPhrase: String = ""
        /// PLAN.md 3.16 item 8 / 3.22.4 (`wipeListensToPhrase`, default on): whether this device
        /// scans Saved Messages at all. Off means it cannot be triggered by another device.
        public var wipeListensToPhrase: Bool = true
        /// PLAN.md 3.16 item 9 / 3.22.6 (`wipeResetsAuthorizations`, default on): whether a local
        /// wipe also calls `auth.resetAuthorizations` to knock the other sessions offline at once.
        public var wipeResetsAuthorizations: Bool = true

        /// PLAN.md 3.0: chat keys whose encryption state this device knows it has lost track of.
        ///
        /// Put here by `ChannelKeyMigration` when an old snapshot held an entry that could be either this
        /// chat's or another's, so it refused to move it. The entry that exists keeps working; this set says
        /// "a key that may belong to this chat exists under a spelling we cannot confirm". `prepareOutgoing`
        /// reads it and refuses to send, because the alternative — treating a missing switch as "encryption
        /// was never on here" — turns a keyring puzzle into plaintext on the wire. Cleared the moment the
        /// user answers the question themselves by importing a key or setting the switch.
        public var encryptionLost: Set<String> = []

        /// PLAN.md 3.25.3/3.25.4: device_id → user-written label, top-level (not per-chat), same protection
        /// tier as `wipeCustomPhrase`. Local-only: never sent in E1/P1/R1/G1, only ever leaves the device
        /// inside an explicit K1 keyring transfer (PLAN.md 3.14).
        public var deviceLabels: [String: DeviceLabel] = [:]

        /// PLAN.md 3.38.1: group chatId → the password-locked key this device keeps INSTEAD of a master. The
        /// fields are stored exactly as they arrived (kdf/ops/mem/salt/wrap/hist); nothing in here opens without
        /// the password, and an older snapshot simply has none.
        public var chatGroupPasswords: [String: GroupPasswordRecord] = [:]
        /// PLAN.md 3.38.1: chatId → master_ids this device has bound for the chat, oldest first. Only what the
        /// group-password rebuild needs to rewrap the group's history and what adoption deletes; local-only.
        public var chatMasterHistory: [String: [String]] = [:]
        /// PLAN.md 3.38.2: group chatId → the newest group-password policy (`GP1`) adopted here. The gate only:
        /// nothing in it decrypts anything, and an older snapshot simply has none (every group reads as "off").
        public var chatGroupPasswordPolicies: [String: GroupPasswordPolicy] = [:]

        public init() {}
    }

    public struct CurrentKey: Equatable {
        public let keyId: String
        public let sessionKey: [UInt8]
    }

    public struct Identity: Equatable {
        public let x25519Pk: [UInt8]
        public let x25519Sk: [UInt8]
        public let ed25519Pk: [UInt8]
        public let ed25519Sk: [UInt8]
    }

    public typealias Clock = () -> Int64

    private static let maxSessionCache = 256

    /// Auto-pairing record (PLAN.md 3.7): `invited` (own P1 sent, waiting for the peer's), `paired` (master derived
    /// from both keys), `keyChanged` (the peer announced a different key after pairing, the user must confirm
    /// re-pairing) or `otherDevice` (another device of this account holds the pairing, rule 8: this one neither
    /// encrypts nor offers "accept" until the user re-pairs here).
    public struct Pairing: Equatable {
        public enum State: String { case invited, paired, keyChanged = "key_changed", otherDevice = "other_device" }
        public let peerId: String
        public let state: State
        /// The user compared the safety code with the peer
        public let verified: Bool
        /// Unix seconds: when this device sent its own P1 (invite / accept)
        public let startedAt: Int64?
        /// Unix seconds: server date of the peer's P1 that completed the pairing (or local time when unknown)
        public let pairedAt: Int64?
        /// PLAN.md 3.25.3: `device_id` (never the public key) of whichever of *this account's own* devices holds
        /// the pairing — this device's own id when `state` isn't `otherDevice`, otherwise the accept race's
        /// winner, learned only from that device's own P1 echoing back into the chat.
        public let ownDeviceId: String?
        /// PLAN.md 3.25.3: `device_id` of the peer's currently-bound key, kept even across `keyChanged`
        public let peerDeviceId: String?
        /// PLAN.md 3.25.3: every peer `device_id` this chat has ever seen, first-seen order, capped at
        /// `DeviceIdentity.maxSeenDeviceIds` (oldest dropped) — a lower bound on how many devices the peer has
        /// used here, never a count.
        public let peerSeenDeviceIds: [String]?

        public init(peerId: String, state: State, verified: Bool, startedAt: Int64? = nil, pairedAt: Int64? = nil,
                    ownDeviceId: String? = nil, peerDeviceId: String? = nil, peerSeenDeviceIds: [String]? = nil) {
            self.peerId = peerId
            self.state = state
            self.verified = verified
            self.startedAt = startedAt
            self.pairedAt = pairedAt
            self.ownDeviceId = ownDeviceId
            self.peerDeviceId = peerDeviceId
            self.peerSeenDeviceIds = peerSeenDeviceIds
        }

        public var isValid: Bool {
            guard !peerId.isEmpty else { return false }
            if let ownDeviceId = ownDeviceId, !DeviceIdentity.isValidDeviceId(ownDeviceId) { return false }
            if let peerDeviceId = peerDeviceId, !DeviceIdentity.isValidDeviceId(peerDeviceId) { return false }
            if let seen = peerSeenDeviceIds {
                guard seen.count <= DeviceIdentity.maxSeenDeviceIds, seen.allSatisfy(DeviceIdentity.isValidDeviceId) else { return false }
            }
            return true
        }

        /// Copy with another state, everything else kept
        public func with(state: State) -> Pairing {
            return Pairing(peerId: peerId, state: state, verified: verified, startedAt: startedAt, pairedAt: pairedAt,
                            ownDeviceId: ownDeviceId, peerDeviceId: peerDeviceId, peerSeenDeviceIds: peerSeenDeviceIds)
        }

        /// Copy with another verification flag, everything else kept
        public func with(verified: Bool) -> Pairing {
            return Pairing(peerId: peerId, state: state, verified: verified, startedAt: startedAt, pairedAt: pairedAt,
                            ownDeviceId: ownDeviceId, peerDeviceId: peerDeviceId, peerSeenDeviceIds: peerSeenDeviceIds)
        }

        /// PLAN.md 3.25.3 rule 1: copy with the device_id of whichever of this account's own devices now holds
        /// the pairing, everything else kept — written only from `RekeyProcessor`'s own-P1 echo handler.
        public func with(ownDeviceId: String) -> Pairing {
            return Pairing(peerId: peerId, state: state, verified: verified, startedAt: startedAt, pairedAt: pairedAt,
                            ownDeviceId: ownDeviceId, peerDeviceId: peerDeviceId, peerSeenDeviceIds: peerSeenDeviceIds)
        }

        /// PLAN.md 3.25.3 rule 2: copy with another `peerSeenDeviceIds`, everything else kept — used when a
        /// duplicate P1 (a losing accept race, or a history replay) is folded in without disturbing the pairing.
        public func with(peerSeenDeviceIds: [String]?) -> Pairing {
            return Pairing(peerId: peerId, state: state, verified: verified, startedAt: startedAt, pairedAt: pairedAt,
                            ownDeviceId: ownDeviceId, peerDeviceId: peerDeviceId, peerSeenDeviceIds: peerSeenDeviceIds)
        }

        /// PLAN.md 3.25.3 rule 3: the peer announced a different key — moves to `keyChanged` with the new
        /// device_id bound and the displaced one folded into `peerSeenDeviceIds`; `ownDeviceId` is untouched.
        public func withPeerKeyChanged(peerDeviceId: String, peerSeenDeviceIds: [String]?) -> Pairing {
            return Pairing(peerId: peerId, state: .keyChanged, verified: verified, startedAt: startedAt, pairedAt: pairedAt,
                            ownDeviceId: ownDeviceId, peerDeviceId: peerDeviceId, peerSeenDeviceIds: peerSeenDeviceIds)
        }
    }

    /// PLAN.md 3.25.3 / 3.25.4: a user-written name for a device, keyed by that device's `device_id` at the
    /// keyring snapshot's top level (not per-chat — the same device can appear in several chats and the user
    /// only writes the name once). Local-only: never sent in E1 / P1 / R1 / G1, only ever leaves the device
    /// inside an explicit K1 keyring transfer (PLAN.md 3.14).
    public struct DeviceLabel: Equatable {
        /// Trimmed, at most `DeviceIdentity.labelMaxChars` characters, plain text — never parsed as markup
        public let label: String
        /// Unix ms; the later `updatedAt` wins when two devices' labels for the same id are merged (3.14)
        public let updatedAt: Int64
        public init(label: String, updatedAt: Int64) {
            self.label = label
            self.updatedAt = updatedAt
        }
        public var isValid: Bool {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && label.count <= DeviceIdentity.labelMaxChars
        }
    }

    /// Forward-secrecy ratchet: the current label and the masters still kept per label
    public struct Ratchet: Equatable {
        public let label: String
        public let masters: [String: String]
        public init(label: String, masters: [String: String]) { self.label = label; self.masters = masters }
        public var isValid: Bool {
            return KeyDerivation.parseEpochLabel(label) != nil && masters[label] != nil
                && masters.allSatisfy { KeyDerivation.parseEpochLabel($0.key) != nil && $0.value.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil }
        }
    }

    private static let maxRatchetSteps = 400
    private static let dayMs: Int64 = 86_400_000

    public let epochDays: Int
    public let epochTolerance: Int
    /// Days a master may stay in use before the UI nags to rotate (crypto.rekey_reminder_days)
    public var rekeyReminderDays: Int = 7
    private let storage: KeyRingStorage
    private let clock: Clock
    // Internal rather than private since PLAN.md 3.38.1: `KeyRing+GroupPassword.swift` works on the same state.
    let lock = NSLock()
    var state: Snapshot
    var sessionCache: [String: [UInt8]] = [:]
    var sessionOrder: [String] = []
    /// PLAN.md 3.38.1: the session unlock table — group chatId → the masters its password opened. MEMORY ONLY:
    /// never persisted, never exported, emptied by `destroyAllKeys` and gone when the process ends.
    var unlockedGroups: [String: GroupPasswordUnlocked] = [:]
    /// PLAN.md 3.38.2: the policy unlock table — group chatId → the exact policy the password was checked
    /// against in this run. Keyed by the policy, so a changed password (new salt) is locked again by itself.
    /// MEMORY ONLY, like `unlockedGroups`.
    var unlockedPolicies: [String: GroupPasswordPolicyParams] = [:]

    public init(storage: KeyRingStorage, clock: @escaping Clock, epochDays: Int, epochTolerance: Int) {
        self.storage = storage
        self.clock = clock
        self.epochDays = max(1, epochDays)
        self.epochTolerance = max(0, epochTolerance)
        self.state = KeyRing.sanitize(storage.load() ?? Snapshot())
    }

    // MARK: masters

    @discardableResult
    public func addMaster(_ masterKey: [UInt8]) throws -> String {
        let masterId = try KeyDerivation.computeMasterId(masterKey)
        lock.lock(); defer { lock.unlock() }
        if state.masters[masterId] == nil {
            state.masters[masterId] = masterKey
            state.masterCreatedAt[masterId] = clock()
            persist()
        }
        return masterId
    }

    public func removeMaster(_ masterId: String) {
        lock.lock(); defer { lock.unlock() }
        removeMasterLocked(masterId)
    }

    private func removeMasterLocked(_ masterId: String) {
        guard state.masters.removeValue(forKey: masterId) != nil else { return }
        state.masterCreatedAt.removeValue(forKey: masterId)
        for (chat, id) in state.chatMasters where id == masterId {
            state.chatMasters.removeValue(forKey: chat)
            state.chatKeyLabels.removeValue(forKey: chat)
        }
        for key in sessionCache.keys where key.hasPrefix(masterId + ".") { sessionCache.removeValue(forKey: key) }
        sessionOrder.removeAll { $0.hasPrefix(masterId + ".") }
        persist()
    }

    // MARK: rekey reminder

    /// Whole days since the chat's current master was stored on this device; nil without a key
    public func keyAgeDays(_ chatId: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let masterId = state.chatMasters[chatId], let created = state.masterCreatedAt[masterId] else { return nil }
        return max(0, Int((clock() - created) / KeyRing.dayMs))
    }

    public func isRekeyDue(_ chatId: String) -> Bool {
        guard let age = keyAgeDays(chatId) else { return false }
        return age >= rekeyReminderDays
    }

    // MARK: key provenance and the two group security levels (PLAN.md 3.13)

    public func setChatKeySource(chatId: String, _ source: ChatKeySource) throws {
        guard source.isValid else { throw SecutgCryptoError.invalidKey }
        lock.lock(); defer { lock.unlock() }
        state.chatKeySources[chatId] = source
        persist()
    }

    public func chatKeySource(_ chatId: String) -> ChatKeySource? {
        lock.lock(); defer { lock.unlock() }
        return state.chatKeySources[chatId]
    }

    public func listChatKeySources() -> [String: ChatKeySource] {
        lock.lock(); defer { lock.unlock() }
        return state.chatKeySources
    }

    /// PLAN.md 3.34.1: how this generation of the chat's key reaches members.
    ///
    /// Defaults to `manual` wherever it is unknown — a key imported by an older build, or one whose payload
    /// carried no mode. Guessing `auto` would leave a member waiting for a key nobody is going to send;
    /// guessing `manual` only tells them to go and ask, which is never wrong, only slower.
    public func setChatKeyMode(chatId: String, _ mode: Rekey.KeyMode) {
        lock.lock(); defer { lock.unlock() }
        guard state.chatKeyModes[chatId] != mode else { return }
        state.chatKeyModes[chatId] = mode
        persist()
    }

    public func chatKeyMode(_ chatId: String) -> Rekey.KeyMode {
        lock.lock(); defer { lock.unlock() }
        return state.chatKeyModes[chatId] ?? .manual
    }

    public func listChatKeyModes() -> [String: Rekey.KeyMode] {
        lock.lock(); defer { lock.unlock() }
        return state.chatKeyModes
    }

    /// PLAN.md 3.34.3 rule 3 (2026-09-19): the `at` of the last retire notice obeyed for `chatId` — or of this
    /// device's own rebuild, so a co-holder's OLDER notice arriving afterwards cannot undo it.
    ///
    /// Never lowered. A notice is only ever obeyed when it is newer than this, so the value is monotonic by
    /// construction, and a caller handing in something older is a caller that has the order wrong. A negative
    /// time is not a time; it is dropped here rather than stored as an anchor nothing can ever beat.
    ///
    /// Deliberately NOT part of `clearChatProvenanceLocked`: the mode is a property of the key and goes when
    /// the key does, but the anchor is a property of what this device has already been told, and unbinding a
    /// master must not make an old notice obeyable again.
    public func setChatNoticeAt(chatId: String, _ at: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard at >= 0 else { return }
        if let current = state.chatNoticeAts[chatId], at <= current { return }
        state.chatNoticeAts[chatId] = at
        persist()
    }

    /// nil means no notice obeyed yet, which is what an older snapshot also reads as: the first notice this
    /// device meets is the newest one it knows of, so it applies.
    public func chatNoticeAt(_ chatId: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return state.chatNoticeAts[chatId]
    }

    public func listChatNoticeAts() -> [String: Int64] {
        lock.lock(); defer { lock.unlock() }
        return state.chatNoticeAts
    }

    /// Admin side: remembers that `userId` got this group's key through a private chat of the given level
    public func recordOnlineInvite(chatId: String, userId: String, level: OnlineInviteLevel) {
        lock.lock(); defer { lock.unlock() }
        var members = state.groupOnlineInvites[chatId] ?? [:]
        members[userId] = level
        state.groupOnlineInvites[chatId] = members
        persist()
    }

    public func onlineInvites(chatId: String) -> [String: OnlineInviteLevel] {
        lock.lock(); defer { lock.unlock() }
        return state.groupOnlineInvites[chatId] ?? [:]
    }

    public func listOnlineInvites() -> [String: [String: OnlineInviteLevel]] {
        lock.lock(); defer { lock.unlock() }
        return state.groupOnlineInvites
    }

    /// The key's provenance goes with the key: cleared when the chat's master is unbound, kept across rekeys
    func clearChatProvenanceLocked(_ chatId: String) -> Bool {
        let hadSource = state.chatKeySources.removeValue(forKey: chatId) != nil
        let hadInvites = state.groupOnlineInvites.removeValue(forKey: chatId) != nil
        // PLAN.md 3.34.1: the mode is a property of the key, so it goes when the key does. A retire notice
        // writes the new one back afterwards, which is why `handleN1` does that strictly after unbinding.
        let hadMode = state.chatKeyModes.removeValue(forKey: chatId) != nil
        return hadSource || hadInvites || hadMode
    }

    // MARK: forward-secrecy ratchet (PLAN.md 3.8)

    public func setChatRatchet(chatId: String, label: String, masterId: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard KeyDerivation.parseEpochLabel(label) != nil, state.masters[masterId] != nil else { throw SecutgCryptoError.invalidKeyId }
        state.chatRatchets[chatId] = Ratchet(label: label, masters: [label: masterId])
        persist()
    }

    public func clearChatRatchet(_ chatId: String) {
        lock.lock(); defer { lock.unlock() }
        guard state.chatRatchets.removeValue(forKey: chatId) != nil else { return }
        persist()
    }

    public func chatRatchet(_ chatId: String) -> Ratchet? {
        lock.lock(); defer { lock.unlock() }
        return state.chatRatchets[chatId]
    }

    public func listRatchetChatIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(state.chatRatchets.keys)
    }

    /// Walks the chat's ratchet forward to `targetLabel`, binds the new master and destroys masters older than the tolerance window
    @discardableResult
    public func advanceRatchet(chatId: String, targetLabel: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return advanceRatchetLocked(chatId: chatId, targetLabel: targetLabel)
    }

    private func advanceRatchetLocked(chatId: String, targetLabel: String) -> String? {
        guard let ratchet = state.chatRatchets[chatId], let targetDay = KeyDerivation.parseEpochLabel(targetLabel),
              let currentDay = KeyDerivation.parseEpochLabel(ratchet.label) else { return nil }
        if targetDay <= currentDay { return ratchet.masters[targetLabel] ?? state.chatMasters[chatId] }
        let steps = Int((Double(targetDay - currentDay) / Double(epochDays)).rounded())
        guard steps > 0, steps <= KeyRing.maxRatchetSteps, var master = ratchet.masters[ratchet.label].flatMap({ state.masters[$0] }) else { return nil }
        var kept = ratchet.masters
        var day = currentDay
        var label = ratchet.label
        for _ in 0..<steps {
            guard let next = try? KeyDerivation.deriveRatchetNext(master), let id = try? KeyDerivation.computeMasterId(next) else { return nil }
            master = next
            day += Int64(epochDays)
            label = KeyDerivation.toEpochLabel(nowMs: day * KeyRing.dayMs, epochDays: epochDays)
            if state.masters[id] == nil { state.masters[id] = next; state.masterCreatedAt[id] = clock() }
            kept[label] = id
        }
        let masterId = kept[label]!
        state.chatMasters[chatId] = masterId
        state.chatKeyLabels[chatId] = label
        let cutoffDay = day - Int64(epochTolerance * epochDays)
        for (oldLabel, oldId) in kept where (KeyDerivation.parseEpochLabel(oldLabel) ?? 0) < cutoffDay {
            kept.removeValue(forKey: oldLabel)
            state.masters.removeValue(forKey: oldId)
            state.masterCreatedAt.removeValue(forKey: oldId)
            for key in sessionCache.keys where key.hasPrefix(oldId + ".") { sessionCache.removeValue(forKey: key) }
        }
        state.chatRatchets[chatId] = Ratchet(label: label, masters: kept)
        persist()
        return masterId
    }

    /// An unknown master_id may be a future day of a ratchet chat: the chat whose chain produces it at that label
    private func matchRatchetLocked(masterId: String, label: String) -> String? {
        guard let targetDay = KeyDerivation.parseEpochLabel(label) else { return nil }
        for (chatId, ratchet) in state.chatRatchets {
            guard let currentDay = KeyDerivation.parseEpochLabel(ratchet.label), targetDay > currentDay else { continue }
            let steps = Int((Double(targetDay - currentDay) / Double(epochDays)).rounded())
            guard steps > 0, steps <= KeyRing.maxRatchetSteps, var master = ratchet.masters[ratchet.label].flatMap({ state.masters[$0] }) else { continue }
            for i in 0..<steps {
                guard let next = try? KeyDerivation.deriveRatchetNext(master) else { break }
                master = next
                if (try? KeyDerivation.computeMasterId(next)) == masterId {
                    if i == steps - 1 { return chatId }
                    break
                }
            }
        }
        return nil
    }

    public func masterKey(for masterId: String) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return state.masters[masterId]
    }

    public func listMasterIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(state.masters.keys)
    }

    // MARK: per-chat bindings

    /// Binds the chat's sending master; label records the epoch of the R1 that did it.
    public func setChatMaster(chatId: String, masterId: String, label: String?) throws {
        lock.lock(); defer { lock.unlock() }
        guard state.masters[masterId] != nil else { throw SecutgCryptoError.invalidKey }
        state.chatMasters[chatId] = masterId
        noteMasterHistoryLocked(chatId: chatId, masterId: masterId)
        if let label = label { state.chatKeyLabels[chatId] = label }
        // PLAN.md 3.0: a key arriving for this chat is the answer the quarantine was waiting for.
        state.encryptionLost.remove(chatId)
        persist()
    }

    public func chatMasterId(_ chatId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return state.chatMasters[chatId]
    }

    public func chatKeyLabel(_ chatId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return state.chatKeyLabels[chatId]
    }

    /// Every chat this device holds a sending key for. The re-decrypt pass of PLAN.md 3.17 uses it after a keyring
    /// transfer, where the key that arrived can belong to any chat: these are the only chats whose stored ciphertext
    /// can possibly open, so they are the only ones worth walking.
    public func listKeyedChatIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(state.chatMasters.keys)
    }

    public func setChatEncryption(chatId: String, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.chatEncryption[chatId] = enabled
        // PLAN.md 3.0: the user has now said what this chat does, so there is nothing left to be unsure of —
        // including when they say "off", which is the one answer that lets plaintext out again.
        state.encryptionLost.remove(chatId)
        persist()
    }

    /// PLAN.md 3.0: is this chat's encryption switch missing rather than off?
    ///
    /// Two shapes of the same failure, and the send path treats both as "refuse", never as "send in the clear":
    ///
    /// * the channel-key migration found an entry it could not safely claim for this chat, or
    /// * this chat holds a sending key while carrying no switch at all. Every path that binds a key also
    ///   writes the switch, so the two disagreeing means the record was damaged, not that the user chose.
    ///
    /// An explicit `false` is a decision and is not this: it returns false, and the message goes out in
    /// the clear exactly as the user asked.
    public func isEncryptionStateUnknown(_ chatId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if state.encryptionLost.contains(chatId) { return true }
        return state.chatEncryption[chatId] == nil && state.chatMasters[chatId] != nil
    }

    public func isChatEncrypted(_ chatId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.chatEncryption[chatId] == true
    }

    // MARK: local ciphertext (PLAN.md 3.19)

    public func getLocalCiphertext() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.localCiphertext
    }

    public func setLocalCiphertext(_ isEnabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.localCiphertext = isEnabled
        persist()
    }

    /// PLAN.md 3.19: does this chat keep only the envelope on disk? Only a chat that encrypts, and only while the
    /// setting is on. A chat that does not encrypt is stored exactly as it always was, search and all.
    public func keepsCiphertextLocally(_ chatId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // PLAN.md 3.38.2: forced on for a group whose password policy is on, whatever the setting — and whether or
        // not this run has unlocked it: the disk outlives the run, so words written while unlocked would read
        // unmasked from the cache in the next, locked one (same rule as the Web reference).
        if state.chatGroupPasswordPolicies[chatId]?.isOn == true { return true }
        // PLAN.md 3.38.1 member rule 2: also forced on for a legacy password-locked group record.
        return (state.localCiphertext || state.chatGroupPasswords[chatId] != nil)
            && state.chatEncryption[chatId] == true
    }

    // MARK: emergency-wipe preferences (PLAN.md 3.16 / 3.22)

    public func getWipeNeedsConfirmation() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.wipeNeedsConfirmation
    }

    public func setWipeNeedsConfirmation(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.wipeNeedsConfirmation = value
        persist()
    }

    /// The stored custom phrase, or nil when none is set (empty string means unset).
    public func getWipeCustomPhrase() -> String? {
        lock.lock(); defer { lock.unlock() }
        return state.wipeCustomPhrase.isEmpty ? nil : state.wipeCustomPhrase
    }

    /// Sets or (with an empty/whitespace string) clears the custom phrase, enforcing the 3.22.2
    /// rules. Returns the rejection when the phrase is refused, so the dialog can say which rule
    /// it broke; on success the trimmed phrase is stored.
    @discardableResult
    public func setWipeCustomPhrase(_ raw: String) -> WipePhrase.PhraseRejection? {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lock.lock(); defer { lock.unlock() }
            state.wipeCustomPhrase = ""
            persist()
            return nil
        }
        switch WipePhrase.validateCustomPhrase(raw) {
        case let .accepted(phrase):
            lock.lock(); defer { lock.unlock() }
            state.wipeCustomPhrase = phrase
            persist()
            return nil
        case let .rejected(reason):
            return reason
        }
    }

    public func getWipeListensToPhrase() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.wipeListensToPhrase
    }

    public func setWipeListensToPhrase(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.wipeListensToPhrase = value
        persist()
    }

    public func getWipeResetsAuthorizations() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.wipeResetsAuthorizations
    }

    public func setWipeResetsAuthorizations(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        state.wipeResetsAuthorizations = value
        persist()
    }

    // MARK: emergency wipe (PLAN.md 3.16 step ①)

    /// Destroys every key and every wipe preference this device holds, in memory and on disk, and
    /// resets to a brand-new ring (PLAN.md 3.16 step ①, item 10). This is the instant, purely-local,
    /// cannot-fail part of the wipe: identity keys, group keys, private-chat keys, pairings, member
    /// public keys, provenance, the encryption switches and every wipe preference all go, replaced
    /// by a fresh empty `Snapshot`. The `KeyRingStorage` is asked to `save` that fresh snapshot; the
    /// runtime additionally deletes the on-disk blob (PLAN.md 3.16 item 1: "delete, not overwrite
    /// with empty") — clearing the in-memory state here guarantees no key survives even if the file
    /// deletion loses a race.
    public func destroyAllKeys() {
        lock.lock(); defer { lock.unlock() }
        state = Snapshot()
        sessionCache.removeAll()
        sessionOrder.removeAll()
        // PLAN.md 3.38.1: the emergency wipe empties the unlock table too.
        unlockedGroups.removeAll()
        unlockedPolicies.removeAll() // PLAN.md 3.38.2
        // Delete the backing store outright (PLAN.md 3.16 item 1), not overwrite it with an empty
        // snapshot. In-memory state is already cleared above, so no key survives either way.
        storage.wipe()
    }

    public func setChatAdminPk(chatId: String, _ pk: [UInt8]) throws {
        guard pk.count == 32 else { throw SecutgCryptoError.invalidKey }
        lock.lock(); defer { lock.unlock() }
        state.chatAdminPks[chatId] = pk
        persist()
    }

    public func chatAdminPk(_ chatId: String) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return state.chatAdminPks[chatId]
    }

    public func setChatAdminSk(chatId: String, _ sk: [UInt8]) throws {
        guard sk.count == 64 else { throw SecutgCryptoError.invalidKey }
        lock.lock(); defer { lock.unlock() }
        state.chatAdminSks[chatId] = sk
        persist()
    }

    public func chatAdminSk(_ chatId: String) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return state.chatAdminSks[chatId]
    }

    // MARK: members and identity

    public func listMemberIds(chatId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(state.memberPks[chatId]?.keys ?? [:].keys)
    }

    public func setMemberEdPk(chatId: String, userId: String, _ pk: [UInt8]) throws {
        guard pk.count == 32 else { throw SecutgCryptoError.invalidKey }
        lock.lock(); defer { lock.unlock() }
        var members = state.memberEdPks[chatId] ?? [:]
        members[userId] = pk
        state.memberEdPks[chatId] = members
        persist()
    }

    public func memberEdPk(chatId: String, userId: String) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return state.memberEdPks[chatId]?[userId]
    }

    public func removeMember(chatId: String, userId: String) {
        lock.lock(); defer { lock.unlock() }
        let hadX = state.memberPks[chatId]?.removeValue(forKey: userId) != nil
        let hadEd = state.memberEdPks[chatId]?.removeValue(forKey: userId) != nil
        if hadX || hadEd { persist() }
    }

    /// Unbinds the chat's sending master; masters stay so old messages still decrypt
    public func clearChatMaster(_ chatId: String) {
        lock.lock(); defer { lock.unlock() }
        let hadMaster = state.chatMasters.removeValue(forKey: chatId) != nil
        let hadLabel = state.chatKeyLabels.removeValue(forKey: chatId) != nil
        let hadProvenance = clearChatProvenanceLocked(chatId)
        if hadMaster || hadLabel || hadProvenance { persist() }
    }

    public func setMemberPk(chatId: String, userId: String, _ pk: [UInt8]) throws {
        guard pk.count == 32 else { throw SecutgCryptoError.invalidKey }
        lock.lock(); defer { lock.unlock() }
        var members = state.memberPks[chatId] ?? [:]
        members[userId] = pk
        state.memberPks[chatId] = members
        persist()
    }

    public func memberPk(chatId: String, userId: String) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return state.memberPks[chatId]?[userId]
    }

    public func setChatPairing(chatId: String, _ pairing: Pairing) throws {
        guard pairing.isValid else { throw SecutgCryptoError.invalidKey }
        lock.lock(); defer { lock.unlock() }
        state.chatPairings[chatId] = pairing
        persist()
    }

    public func clearChatPairing(_ chatId: String) {
        lock.lock(); defer { lock.unlock() }
        guard state.chatPairings.removeValue(forKey: chatId) != nil else { return }
        persist()
    }

    public func chatPairing(_ chatId: String) -> Pairing? {
        lock.lock(); defer { lock.unlock() }
        return state.chatPairings[chatId]
    }

    public func listChatPairings() -> [String: Pairing] {
        lock.lock(); defer { lock.unlock() }
        return state.chatPairings
    }

    // MARK: device identification and labels (PLAN.md 3.25)

    /// This device's own `device_id` / `device_code` (PLAN.md 3.25.2), or nil without an identity yet.
    public func ownDeviceIdentity() -> DeviceIdentity.Identity? {
        lock.lock(); defer { lock.unlock() }
        guard let pk = state.identityX25519Pk else { return nil }
        return try? DeviceIdentity.derive(x25519Pk: pk)
    }

    /// An empty (or whitespace-only) label clears it. Text is trimmed and capped at
    /// `DeviceIdentity.labelMaxChars` (PLAN.md 3.25.3).
    public func setDeviceLabel(deviceId: String, label: String) throws {
        guard DeviceIdentity.isValidDeviceId(deviceId) else { throw SecutgCryptoError.invalidKeyId }
        let trimmed = DeviceIdentity.normalizeLabel(label)
        lock.lock(); defer { lock.unlock() }
        if trimmed.isEmpty {
            state.deviceLabels.removeValue(forKey: deviceId)
        } else {
            state.deviceLabels[deviceId] = DeviceLabel(label: trimmed, updatedAt: clock())
        }
        persist()
    }

    public func deviceLabel(_ deviceId: String) -> DeviceLabel? {
        lock.lock(); defer { lock.unlock() }
        return state.deviceLabels[deviceId]
    }

    public func listDeviceLabels() -> [String: DeviceLabel] {
        lock.lock(); defer { lock.unlock() }
        return state.deviceLabels
    }

    public func setIdentity(_ identity: Identity) throws {
        guard identity.x25519Pk.count == 32, identity.x25519Sk.count == 32,
              identity.ed25519Pk.count == 32, identity.ed25519Sk.count == 64 else { throw SecutgCryptoError.invalidKey }
        lock.lock(); defer { lock.unlock() }
        state.identityX25519Pk = identity.x25519Pk
        state.identityX25519Sk = identity.x25519Sk
        state.identityEd25519Pk = identity.ed25519Pk
        state.identityEd25519Sk = identity.ed25519Sk
        persist()
    }

    public var identity: Identity? {
        lock.lock(); defer { lock.unlock() }
        guard let xPk = state.identityX25519Pk, let xSk = state.identityX25519Sk,
              let edPk = state.identityEd25519Pk, let edSk = state.identityEd25519Sk else { return nil }
        return Identity(x25519Pk: xPk, x25519Sk: xSk, ed25519Pk: edPk, ed25519Sk: edSk)
    }

    // MARK: session keys

    /// key_id + session key to encrypt with right now, or nil when the chat has no master.
    public func currentKey(chatId: String) -> CurrentKey? {
        lock.lock(); defer { lock.unlock() }
        let label = KeyDerivation.toEpochLabel(nowMs: clock(), epochDays: epochDays)
        if state.chatRatchets[chatId] != nil { _ = advanceRatchetLocked(chatId: chatId, targetLabel: label) }
        // PLAN.md 3.38.1 member rule 5: a locked group sends under the master its password opened this run.
        guard let masterId = state.chatMasters[chatId] ?? activeUnlockedMasterIdLocked(chatId) else { return nil }
        let keyId = KeyDerivation.buildKeyId(masterId: masterId, label: label)
        guard let sessionKey = lookupLocked(keyId) else { return nil }
        return CurrentKey(keyId: keyId, sessionKey: sessionKey)
    }

    /// Session key for any key_id whose master is known and whose epoch is not in the far future.
    public func lookupSessionKey(_ keyId: String) -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return lookupLocked(keyId)
    }

    private func lookupLocked(_ keyId: String) -> [UInt8]? {
        if let cached = sessionCache[keyId] { return cached }
        guard let parsed = KeyDerivation.parseKeyId(keyId),
              KeyDerivation.isLabelAcceptable(parsed.label, nowMs: clock(), epochTolerance: epochTolerance) else { return nil }
        if state.masters[parsed.masterId] == nil, let chatId = matchRatchetLocked(masterId: parsed.masterId, label: parsed.label) {
            _ = advanceRatchetLocked(chatId: chatId, targetLabel: parsed.label)
        }
        // PLAN.md 3.38.1: a locked group's masters are only in the unlock table.
        guard let master = state.masters[parsed.masterId] ?? unlockedMasterLocked(parsed.masterId),
              let sessionKey = try? KeyDerivation.deriveSessionKey(masterKey: master, label: parsed.label) else { return nil }
        sessionCache[keyId] = sessionKey
        sessionOrder.append(keyId)
        if sessionOrder.count > KeyRing.maxSessionCache {
            sessionCache.removeValue(forKey: sessionOrder.removeFirst())
        }
        return sessionKey
    }

    /// Masters to try for a rotate payload: the chat's current one first.
    public func candidateMasters(chatId: String) -> [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        let current = state.chatMasters[chatId]
        var out = [[UInt8]]()
        if let current = current, let key = state.masters[current] { out.append(key) }
        for (id, key) in state.masters where id != current { out.append(key) }
        return out
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    // MARK: transfer between this user's own devices (PLAN.md 3.14)

    /// Everything this device holds; the caller wraps it in a `K1` container before it leaves the device.
    /// PLAN.md 3.25.4 rule 2, scope=all: `deviceLabels` travels unless the export dialog's "不包含设备备注"
    /// checkbox is on.
    public func exportSnapshot(includeDeviceLabels: Bool = true) -> Snapshot {
        var out = snapshot()
        if !includeDeviceLabels { out.deviceLabels = [:] }
        return out
    }

    /// The slice of the keyring that belongs to `chatIds`, optionally carrying this device's identity key pair.
    /// PLAN.md 3.25.4 rule 2, scope=chat: `deviceLabels` is filtered to only the device ids these chats
    /// actually reference — this device's own identity plus every `ownDeviceId` / `peerDeviceId` /
    /// `peerSeenDeviceIds` the exported pairings mention — never the whole table, or a single-chat transfer
    /// would leak "which other devices this user recognises" well beyond that chat.
    public func exportChatsSnapshot(chatIds: [String], withIdentity: Bool, includeDeviceLabels: Bool = true) -> Snapshot {
        let wanted = Set(chatIds)
        lock.lock(); defer { lock.unlock() }
        var out = Snapshot()
        out.chatMasters = state.chatMasters.filter { wanted.contains($0.key) }
        out.chatKeyLabels = state.chatKeyLabels.filter { wanted.contains($0.key) }
        out.chatEncryption = state.chatEncryption.filter { wanted.contains($0.key) }
        out.chatAdminPks = state.chatAdminPks.filter { wanted.contains($0.key) }
        out.chatAdminSks = state.chatAdminSks.filter { wanted.contains($0.key) }
        out.memberPks = state.memberPks.filter { wanted.contains($0.key) }
        out.memberEdPks = state.memberEdPks.filter { wanted.contains($0.key) }
        out.chatPairings = state.chatPairings.filter { wanted.contains($0.key) }
        out.chatRatchets = state.chatRatchets.filter { wanted.contains($0.key) }
        out.chatKeySources = state.chatKeySources.filter { wanted.contains($0.key) }
        out.chatKeyModes = state.chatKeyModes.filter { wanted.contains($0.key) }
        out.chatNoticeAts = state.chatNoticeAts.filter { wanted.contains($0.key) }
        out.groupOnlineInvites = state.groupOnlineInvites.filter { wanted.contains($0.key) }
        // Every master those chats ever used stays in, so imported history keeps decrypting
        var keep = Set(out.chatMasters.values)
        for (_, ratchet) in out.chatRatchets { keep.formUnion(ratchet.masters.values) }
        out.masters = state.masters.filter { keep.contains($0.key) }
        out.masterCreatedAt = state.masterCreatedAt.filter { keep.contains($0.key) }
        if withIdentity {
            out.identityX25519Pk = state.identityX25519Pk
            out.identityX25519Sk = state.identityX25519Sk
            out.identityEd25519Pk = state.identityEd25519Pk
            out.identityEd25519Sk = state.identityEd25519Sk
        }
        // This device's own identity is always consulted, not just when the export carries the secret identity
        // keys: a label the user wrote for this very machine should travel with a single-chat file too. Gating it
        // on `withIdentity` dropped it exactly when the chat has no `ownDeviceId` of its own to fall back on —
        // `invited` (not paired yet) or `other_device` (another of this account's devices holds the pairing).
        // Web / Android / Windows have always passed the identity unconditionally here.
        if includeDeviceLabels {
            out.deviceLabels = KeyRing.relevantDeviceLabels(
                state.deviceLabels, ownX25519Pk: state.identityX25519Pk, pairings: out.chatPairings)
        }
        return out
    }

    /// PLAN.md 3.25.4 rule 2, scope=chat: only the device ids these chats' pairings (and this device's own
    /// identity, always) actually mention — never the whole table.
    private static func relevantDeviceLabels(
        _ all: [String: DeviceLabel], ownX25519Pk: [UInt8]?, pairings: [String: Pairing]
    ) -> [String: DeviceLabel] {
        var wanted = Set<String>()
        if let ownX25519Pk = ownX25519Pk, let own = try? DeviceIdentity.derive(x25519Pk: ownX25519Pk) {
            wanted.insert(own.deviceId)
        }
        for (_, pairing) in pairings {
            if let id = pairing.ownDeviceId { wanted.insert(id) }
            if let id = pairing.peerDeviceId { wanted.insert(id) }
            pairing.peerSeenDeviceIds?.forEach { wanted.insert($0) }
        }
        return all.filter { wanted.contains($0.key) }
    }

    /// Merges a snapshot exported by another device of the same user (PLAN.md 3.14 rule 2): masters are
    /// deduplicated by id, a chat binding is only taken over when this device has none or the incoming epoch
    /// label is not older (the 3.9 anti-rollback rule), and everything else merges per chat. The identity is
    /// adopted when this device has none, and otherwise only when `replaceIdentity` says so.
    @discardableResult
    public func mergeSnapshot(_ incoming: Snapshot?, replaceIdentity: Bool = false) -> KeyRingMergeResult {
        let clean = KeyRing.sanitize(incoming ?? Snapshot())
        var result = KeyRingMergeResult()
        lock.lock(); defer { lock.unlock() }

        for (masterId, key) in clean.masters where state.masters[masterId] == nil {
            state.masters[masterId] = key
            state.masterCreatedAt[masterId] = clean.masterCreatedAt[masterId] ?? clock()
            result.addedMasters += 1
        }

        for (chatId, masterId) in clean.chatMasters {
            let incomingLabel = clean.chatKeyLabels[chatId]
            let incomingDay = incomingLabel.flatMap(KeyDerivation.parseEpochLabel)
            let currentDay = state.chatKeyLabels[chatId].flatMap(KeyDerivation.parseEpochLabel)
            let isOlder = currentDay != nil && incomingDay != nil && incomingDay! < currentDay!
            if state.chatMasters[chatId] != nil && (isOlder || incomingLabel == nil) {
                if state.chatMasters[chatId] != masterId { result.skippedChats.append(chatId) }
                continue
            }
            state.chatMasters[chatId] = masterId
            if let label = incomingLabel { state.chatKeyLabels[chatId] = label }
            result.boundChats.append(chatId)
        }

        // PLAN.md 3.0: an imported keyring answers this device's open questions but never asks new ones —
        // its own `encryptionLost` is about its own snapshot puzzle and is deliberately not carried over,
        // exactly like the 3.19 / 3.16 preferences below it.
        for (chatId, value) in clean.chatEncryption {
            state.chatEncryption[chatId] = value
            state.encryptionLost.remove(chatId)
        }
        for chatId in result.boundChats { state.encryptionLost.remove(chatId) }
        for (chatId, value) in clean.chatAdminPks { state.chatAdminPks[chatId] = value }
        for (chatId, value) in clean.chatAdminSks { state.chatAdminSks[chatId] = value }
        for (chatId, value) in clean.chatPairings { state.chatPairings[chatId] = value }
        for (chatId, value) in clean.chatRatchets { state.chatRatchets[chatId] = value }
        for (chatId, value) in clean.chatKeySources { state.chatKeySources[chatId] = value }
        for (chatId, value) in clean.chatKeyModes { state.chatKeyModes[chatId] = value }
        // PLAN.md 3.34.3 rule 3: the later of the two anchors wins, whichever side it came from — the device
        // that obeyed the more recent notice is the one that knows more, and taking the incoming value flat
        // could hand this device an older anchor and make a replay obeyable again.
        for (chatId, value) in clean.chatNoticeAts {
            state.chatNoticeAts[chatId] = max(value, state.chatNoticeAts[chatId] ?? 0)
        }
        for (chatId, members) in clean.memberPks {
            state.memberPks[chatId] = (state.memberPks[chatId] ?? [:]).merging(members) { _, new in new }
        }
        for (chatId, members) in clean.memberEdPks {
            state.memberEdPks[chatId] = (state.memberEdPks[chatId] ?? [:]).merging(members) { _, new in new }
        }
        for (chatId, members) in clean.groupOnlineInvites {
            state.groupOnlineInvites[chatId] = (state.groupOnlineInvites[chatId] ?? [:]).merging(members) { _, new in new }
        }
        // PLAN.md 3.38.1: the newer locked record wins, like the anchor above.
        for (chatId, record) in clean.chatGroupPasswords where (state.chatGroupPasswords[chatId]?.at ?? -1) < record.at {
            state.chatGroupPasswords[chatId] = record
        }
        // PLAN.md 3.38.2: the newer policy wins; an unlock of the one it replaced no longer matches.
        for (chatId, policy) in clean.chatGroupPasswordPolicies where (state.chatGroupPasswordPolicies[chatId]?.at ?? -1) < policy.at {
            state.chatGroupPasswordPolicies[chatId] = policy
        }
        for (chatId, ids) in clean.chatMasterHistory {
            let merged = (state.chatMasterHistory[chatId] ?? []) + ids.filter { !(state.chatMasterHistory[chatId] ?? []).contains($0) }
            state.chatMasterHistory[chatId] = Array(merged.suffix(KeyRing.maxMasterHistory))
        }

        if clean.identityEd25519Sk != nil {
            let hadIdentity = state.identityEd25519Pk != nil
            let isSame = hadIdentity && state.identityEd25519Pk == clean.identityEd25519Pk
                && state.identityX25519Pk == clean.identityX25519Pk
            if !hadIdentity || replaceIdentity {
                result.identityReplaced = hadIdentity && !isSame
                state.identityX25519Pk = clean.identityX25519Pk
                state.identityX25519Sk = clean.identityX25519Sk
                state.identityEd25519Pk = clean.identityEd25519Pk
                state.identityEd25519Sk = clean.identityEd25519Sk
            }
        }

        // PLAN.md 3.14 rule 2 / 3.25.4 rule 2: same device_id on both sides keeps whichever label is newer
        for (deviceId, label) in clean.deviceLabels {
            let current = state.deviceLabels[deviceId]
            if current == nil || label.updatedAt >= current!.updatedAt { state.deviceLabels[deviceId] = label }
        }

        sessionCache.removeAll()
        sessionOrder.removeAll()
        persist()
        return result
    }

    func persist() {
        storage.save(state)
    }

    /// Storage is untrusted input: drop malformed records instead of failing later.
    static func sanitize(_ raw: Snapshot) -> Snapshot {
        var clean = Snapshot()
        for (id, key) in raw.masters where id.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil && key.count == KeyDerivation.masterKeyBytes {
            clean.masters[id] = key
        }
        for (chat, id) in raw.chatMasters where clean.masters[id] != nil { clean.chatMasters[chat] = id }
        for (chat, label) in raw.chatKeyLabels where clean.chatMasters[chat] != nil && label.range(of: "^\\d{8}$", options: .regularExpression) != nil {
            clean.chatKeyLabels[chat] = label
        }
        clean.chatEncryption = raw.chatEncryption
        for (chat, pk) in raw.chatAdminPks where pk.count == 32 { clean.chatAdminPks[chat] = pk }
        for (chat, sk) in raw.chatAdminSks where sk.count == 64 { clean.chatAdminSks[chat] = sk }
        for (chat, members) in raw.memberPks { clean.memberPks[chat] = members.filter { $0.value.count == 32 } }
        for (chat, members) in raw.memberEdPks { clean.memberEdPks[chat] = members.filter { $0.value.count == 32 } }
        if let xPk = raw.identityX25519Pk, xPk.count == 32, let xSk = raw.identityX25519Sk, xSk.count == 32,
           let edPk = raw.identityEd25519Pk, edPk.count == 32, let edSk = raw.identityEd25519Sk, edSk.count == 64 {
            clean.identityX25519Pk = xPk; clean.identityX25519Sk = xSk
            clean.identityEd25519Pk = edPk; clean.identityEd25519Sk = edSk
        }
        clean.chatPairings = raw.chatPairings.filter { $0.value.isValid }
        // PLAN.md 3.25.7 rule 2: absent from an old snapshot (or malformed) sanitises to an empty table, not an error
        clean.deviceLabels = raw.deviceLabels.filter { DeviceIdentity.isValidDeviceId($0.key) && $0.value.isValid }
        clean.masterCreatedAt = raw.masterCreatedAt.filter { clean.masters[$0.key] != nil }
        clean.chatRatchets = raw.chatRatchets.filter { $0.value.isValid }
        clean.chatKeySources = raw.chatKeySources.filter { $0.value.isValid }
        // PLAN.md 3.34.1: an absent entry (an older snapshot) reads as `manual` at every reader. A `KeyMode`
        // cannot hold an unrecognised value in Swift, so what the decoder could not read never gets this far.
        clean.chatKeyModes = raw.chatKeyModes
        // PLAN.md 3.34.3 rule 3: absent (an older snapshot) means no notice obeyed yet. A negative time is
        // not a time — stored, it would be an anchor every real notice already beats, which is harmless, but
        // it is garbage and garbage in this table is what a replay guard is made of.
        clean.chatNoticeAts = raw.chatNoticeAts.filter { $0.value >= 0 }
        clean.groupOnlineInvites = raw.groupOnlineInvites.mapValues { $0.filter { !$0.key.isEmpty } }.filter { !$0.value.isEmpty }
        clean.localCiphertext = raw.localCiphertext
        // PLAN.md 3.38.1: a record that could never be opened is dropped rather than kept as a permanent gate.
        clean.chatGroupPasswords = raw.chatGroupPasswords.filter { $0.value.isValid }
        // PLAN.md 3.38.2: a policy no password could ever open is not kept as a permanent gate.
        clean.chatGroupPasswordPolicies = raw.chatGroupPasswordPolicies.filter { $0.key.hasPrefix("-") && $0.value.isValid }
        clean.chatMasterHistory = raw.chatMasterHistory
            .mapValues { Array($0.filter { $0.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil }.suffix(KeyRing.maxMasterHistory)) }
            .filter { !$0.value.isEmpty }
        // PLAN.md 3.0: a quarantined key that has since gained a switch or a master has already been answered,
        // so the mark is dropped here rather than nagging forever.
        clean.encryptionLost = raw.encryptionLost.filter { clean.chatEncryption[$0] == nil && clean.chatMasters[$0] == nil }
        clean.wipeNeedsConfirmation = raw.wipeNeedsConfirmation
        clean.wipeListensToPhrase = raw.wipeListensToPhrase
        clean.wipeResetsAuthorizations = raw.wipeResetsAuthorizations
        // A stored phrase that no longer meets the rule (e.g. a shorter minimum in an older build)
        // is dropped rather than kept as an un-editable, sub-standard trigger.
        let phrase = raw.wipeCustomPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .accepted(let accepted) = WipePhrase.validateCustomPhrase(phrase) {
            clean.wipeCustomPhrase = accepted
        }
        return clean
    }
}

public protocol KeyRingStorage: AnyObject {
    func load() -> KeyRing.Snapshot?
    func save(_ snapshot: KeyRing.Snapshot)
    /// PLAN.md 3.16 item 1: destroy the persisted keyring by *deleting* the backing store, not by
    /// overwriting it with an empty snapshot. `KeyRing.destroyAllKeys()` already clears the in-memory
    /// state and saves an empty snapshot; this additionally removes the on-disk artefact so nothing
    /// is left to recover. The default falls back to saving an empty snapshot for stores that have
    /// nothing to delete.
    func wipe()
}

public extension KeyRingStorage {
    func wipe() { save(KeyRing.Snapshot()) }
}

public final class MemoryKeyRingStorage: KeyRingStorage {
    public private(set) var saved: KeyRing.Snapshot?
    public init(_ initial: KeyRing.Snapshot? = nil) { saved = initial }
    public func load() -> KeyRing.Snapshot? { return saved }
    public func save(_ snapshot: KeyRing.Snapshot) { saved = snapshot }
    public func wipe() { saved = nil }
}
