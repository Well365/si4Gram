import Foundation

/// v1.4 section 16's chat_binding and pair_tombstone tables — the two persistent records that decide
/// what a device does with an OLD message, as opposed to pair_txn which decides what to do with the
/// in-flight exchange itself. Ported from `src/secutg/v2/pairing/binding.ts` and
/// `org.telegram.secutg.v2.pairing.Binding`.
///
/// Split into two types for the same reason V2EventLog/V2SelectionCas are split: they answer
/// different questions. `V2BindingStore` answers "what key is this chat using right now, may it send,
/// and what did it use before". `V2TombstoneStore` answers "has this transaction or binding already
/// been finally settled" — v1.4 section 27's "a terminal record outranks pairing-phase recovery":
/// before a historical message is allowed to do ANYTHING, whichever of these two questions applies
/// must be checked first, because a cancelled/unbound target must not be revived by a stale message
/// arriving after the cancellation.
///
/// Both are in-memory here, matching store.ts's stated order: persistence is a later concern, added
/// once it is clear what actually needs to survive a reload — deferred on this port the same way it
/// was on Android's.
public struct V2Binding: Codable {
    public let chatId: String
    /// = transcript_hash (th) of the exchange that produced it — v1.4 section 8.
    public let bindingId: String
    public let epoch: Int
    public let deviceRoster: [String]
    /// device_id -> the two long-term keys a future ROSTER_COMMIT needs for that device.
    public let deviceKeys: [String: DeviceKeys]
    public let revision: Int
    public let txnId: String
    public let installedAtMs: Int64
    /// Out-of-band safety-code confirmation. Always false the moment a binding is installed.
    public let verified: Bool
    /// v1.4 section 9/33: intent=replace pauses sending on the binding being replaced immediately.
    public let suspended: Bool
    /// v1.4 section 9: an out-of-band safety-code comparison came back DIFFERENT.
    public let mismatch: Bool
    /// P-42: "continue sending" overrides mismatch for THIS bindingId only.
    public let mismatchOverride: Bool
    /// PLAN.md 3.39.4 step 3: present ONLY on a binding installed from a V2Q (`txnId` = `join:<bindingId>`) — the
    /// device identity the showing device minted for THIS chat, which every v2 operation on this binding acts under
    /// instead of the device's global identity (`V2OwnIdentity`). Absent on every binding P2 itself produced, and
    /// on every snapshot written before 3.39 (synthesized Codable reads a missing optional as nil).
    public let ownIdentity: OwnIdentity?
    /// PLAN.md 3.39.4 step 3: the safety code the V2Q carried — shown as-is, never recomputed (a joined device has no
    /// transcript to compute it from). nil on a binding this device paired itself.
    public let safetyCode: String?

    public struct DeviceKeys: Codable {
        public let identityPk: String
        public let encapsulationPk: String

        public init(identityPk: String, encapsulationPk: String) {
            self.identityPk = identityPk
            self.encapsulationPk = encapsulationPk
        }
    }

    /// PLAN.md 3.39.4: the per-binding identity a V2Q brings. All base64url; `deviceId` = `base64url(sha256(identityPk))`.
    /// Persisted with the binding (v2 state is encrypted at rest) and destroyed with it by the emergency wipe (3.39.7).
    public struct OwnIdentity: Codable, Equatable {
        public let deviceId: String
        public let identityPk: String
        public let identitySk: String
        public let encapsulationPk: String
        public let encapsulationSk: String

        public init(deviceId: String, identityPk: String, identitySk: String, encapsulationPk: String, encapsulationSk: String) {
            self.deviceId = deviceId
            self.identityPk = identityPk
            self.identitySk = identitySk
            self.encapsulationPk = encapsulationPk
            self.encapsulationSk = encapsulationSk
        }
    }

    public init(
        chatId: String, bindingId: String, epoch: Int, deviceRoster: [String], deviceKeys: [String: DeviceKeys],
        revision: Int, txnId: String, installedAtMs: Int64, verified: Bool, suspended: Bool, mismatch: Bool, mismatchOverride: Bool,
        ownIdentity: OwnIdentity? = nil, safetyCode: String? = nil
    ) {
        self.chatId = chatId
        self.bindingId = bindingId
        self.epoch = epoch
        self.deviceRoster = deviceRoster
        self.deviceKeys = deviceKeys
        self.revision = revision
        self.txnId = txnId
        self.installedAtMs = installedAtMs
        self.verified = verified
        self.suspended = suspended
        self.mismatch = mismatch
        self.mismatchOverride = mismatchOverride
        self.ownIdentity = ownIdentity
        self.safetyCode = safetyCode
    }

    /// What `V2BindingStore.install` fills in itself rather than trusting a caller with — every one
    /// of these MUST start fresh (P-34/P-35). Callers use this to build the "fresh" fields a new
    /// binding needs before `install` fixes verified/suspended/mismatch/mismatchOverride to false
    /// regardless of what is passed.
    public static func freshTemplate(
        chatId: String, bindingId: String, epoch: Int, deviceRoster: [String], deviceKeys: [String: DeviceKeys],
        revision: Int, txnId: String, installedAtMs: Int64, ownIdentity: OwnIdentity? = nil, safetyCode: String? = nil
    ) -> V2Binding {
        return V2Binding(
            chatId: chatId, bindingId: bindingId, epoch: epoch, deviceRoster: deviceRoster, deviceKeys: deviceKeys,
            revision: revision, txnId: txnId, installedAtMs: installedAtMs, verified: false, suspended: false,
            mismatch: false, mismatchOverride: false, ownIdentity: ownIdentity, safetyCode: safetyCode
        )
    }

    /// A copy with the named fields replaced and EVERYTHING else — including the two 3.39 fields — carried over.
    /// Every patch below goes through this so a new field can never be dropped by one of them.
    func updating(
        epoch: Int? = nil, deviceRoster: [String]? = nil, deviceKeys: [String: DeviceKeys]? = nil, revision: Int? = nil,
        verified: Bool? = nil, suspended: Bool? = nil, mismatch: Bool? = nil, mismatchOverride: Bool? = nil
    ) -> V2Binding {
        return V2Binding(
            chatId: chatId, bindingId: bindingId, epoch: epoch ?? self.epoch, deviceRoster: deviceRoster ?? self.deviceRoster,
            deviceKeys: deviceKeys ?? self.deviceKeys, revision: revision ?? self.revision, txnId: txnId, installedAtMs: installedAtMs,
            verified: verified ?? self.verified, suspended: suspended ?? self.suspended, mismatch: mismatch ?? self.mismatch,
            mismatchOverride: mismatchOverride ?? self.mismatchOverride, ownIdentity: ownIdentity, safetyCode: safetyCode
        )
    }

    public final class BindingStore {
        private var current: [String: V2Binding] = [:]
        private var historical: [String: [V2Binding]] = [:]

        public init() { }

        /// Installs a new binding for chatId. Whatever was current before moves to historical —
        /// v1.4 section 9: "a new binding is only turned historical once it commits" — so the ONLY
        /// caller of this is the pairing processor's own completion path, never a historical-message
        /// replay.
        ///
        /// verified/suspended/mismatch/mismatchOverride always start false here regardless of what
        /// `binding` carries — call `freshTemplate` to build the input so this is obvious at the call
        /// site too, not just enforced here.
        public func install(_ binding: V2Binding) {
            let fresh = binding.updating(verified: false, suspended: false, mismatch: false, mismatchOverride: false)
            if let previous = current[fresh.chatId], previous.bindingId != fresh.bindingId {
                historical[fresh.chatId, default: []].append(previous)
            }
            current[fresh.chatId] = fresh
        }

        public func current(_ chatId: String) -> V2Binding? {
            return current[chatId]
        }

        /// v1.4 section 9: "unpairing clears only active_binding and send eligibility, history keys
        /// stay".
        public func deactivate(_ chatId: String) {
            guard let previous = current[chatId] else { return }
            historical[chatId, default: []].append(previous)
            current.removeValue(forKey: chatId)
        }

        public func historical(_ chatId: String) -> [V2Binding] {
            return historical[chatId] ?? []
        }

        /// Every chat this device currently holds an active binding for — P-35's "all this device's
        /// auto-pairing chats".
        public func allChatIdsWithCurrentBinding() -> [String] {
            return Array(current.keys)
        }

        private func updateCurrent(_ chatId: String, _ patch: (V2Binding) -> V2Binding) {
            guard let c = current[chatId] else { return }
            current[chatId] = patch(c)
        }

        /// v1.4 section 9/33: pauses sending on chatId's CURRENT binding immediately.
        public func suspend(_ chatId: String) {
            updateCurrent(chatId) { $0.updating(suspended: true) }
        }

        /// Marks bindingId verified — a no-op if it is not chatId's CURRENT binding.
        public func markVerified(chatId: String, bindingId: String) {
            updateCurrent(chatId) { b in
                guard b.bindingId == bindingId else { return b }
                return b.updating(verified: true)
            }
        }

        /// P-42: an out-of-band comparison came back different. Clears verified too, and any earlier
        /// override.
        public func markMismatch(chatId: String, bindingId: String) {
            updateCurrent(chatId) { b in
                guard b.bindingId == bindingId else { return b }
                return b.updating(verified: false, mismatch: true, mismatchOverride: false)
            }
        }

        /// P-42: "continue sending" — authorizes sending under THIS bindingId despite the mismatch,
        /// nothing more.
        public func overrideMismatch(chatId: String, bindingId: String) {
            updateCurrent(chatId) { b in
                guard b.bindingId == bindingId, b.mismatch else { return b }
                return b.updating(mismatchOverride: true)
            }
        }

        /// The one question everything above exists to answer: may this chat send right now.
        public func canSend(_ chatId: String) -> Bool {
            guard let b = current[chatId], !b.suspended else { return false }
            return !b.mismatch || b.mismatchOverride
        }

        /// P-35: this device's OWN identity was replaced. Every chat under it needs its safety code
        /// re-checked, but sending is not paused.
        public func markAllUnverified() {
            for chatId in Array(current.keys) {
                updateCurrent(chatId) { $0.updating(verified: false) }
            }
        }

        /// v1.4 section 33's REKEY/ADD_DEVICE/REMOVE_DEVICE (P-43-46): rotates the master's epoch/
        /// roster/deviceKeys on the SAME binding — bindingId never changes. NOT `install`: that
        /// method's logic is keyed on "a DIFFERENT bindingId means a different binding", which would
        /// incorrectly historicize the binding on every single rekey. verified/suspended/mismatch/
        /// mismatchOverride are all left exactly as they were, deliberately unlike install. A no-op if
        /// chatId has no current binding at all.
        public func applyRosterCommit(chatId: String, epoch: Int, deviceRoster: [String], deviceKeys: [String: DeviceKeys]) {
            updateCurrent(chatId) { b in
                b.updating(epoch: epoch, deviceRoster: deviceRoster, deviceKeys: deviceKeys, revision: b.revision + 1)
            }
        }

        /// True when txnId is the one that produced the chat's CURRENT binding, or one of its
        /// historical ones. P-25's replay guard: 100 replays of a completed exchange must never call
        /// install again.
        public func alreadyInstalledFor(chatId: String, txnId: String) -> Bool {
            if let c = current[chatId], c.txnId == txnId { return true }
            return historical(chatId).contains { $0.txnId == txnId }
        }

        // MARK: persistence (Web integration draft 1/4)

        /// Every field of `V2Binding` is already JSON-safe (device keys are base64url strings, never
        /// raw bytes save for the underlying `[UInt8]` fields Codable already knows how to encode) —
        /// a plain structural copy, mirroring `pairing/binding.ts`'s own `toSnapshot`.
        public struct Snapshot: Codable {
            public var current: [V2Binding]
            public var historical: [String: [V2Binding]]
        }

        public func toSnapshot() -> Snapshot {
            return Snapshot(current: Array(current.values), historical: historical)
        }

        public static func fromSnapshot(_ snapshot: Snapshot) -> BindingStore {
            let store = BindingStore()
            for binding in snapshot.current { store.current[binding.chatId] = binding }
            for (chatId, list) in snapshot.historical { store.historical[chatId] = list }
            return store
        }
    }

    public enum TombstoneReason: Codable {
        case cancelled, unpaired
    }

    public struct Tombstone: Codable {
        public let reason: TombstoneReason
        public let eventId: String
        public let atMs: Int64
    }

    public final class TombstoneStore {
        private var byTxn: [String: Tombstone] = [:]
        private var byBinding: [String: Tombstone] = [:]

        public init() { }

        public func recordCancelled(txnId: String, eventId: String, atMs: Int64) {
            // A terminal record is written once and never overwritten.
            if byTxn[txnId] == nil { byTxn[txnId] = Tombstone(reason: .cancelled, eventId: eventId, atMs: atMs) }
        }

        public func recordUnpaired(bindingId: String, eventId: String, atMs: Int64) {
            if byBinding[bindingId] == nil { byBinding[bindingId] = Tombstone(reason: .unpaired, eventId: eventId, atMs: atMs) }
        }

        public func cancelledFor(_ txnId: String) -> Tombstone? {
            return byTxn[txnId]
        }

        public func unpairedFor(_ bindingId: String) -> Tombstone? {
            return byBinding[bindingId]
        }

        // MARK: persistence (Web integration draft 1/4)

        public struct Snapshot: Codable {
            public var byTxn: [String: Tombstone]
            public var byBinding: [String: Tombstone]
        }

        public func toSnapshot() -> Snapshot {
            return Snapshot(byTxn: byTxn, byBinding: byBinding)
        }

        public static func fromSnapshot(_ snapshot: Snapshot) -> TombstoneStore {
            let store = TombstoneStore()
            store.byTxn = snapshot.byTxn
            store.byBinding = snapshot.byBinding
            return store
        }
    }
}
