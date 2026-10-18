import Foundation

/// v1.4 section 13's group state chain (group_id/genesis_id/epoch/mode/admin_acl/device_roster/
/// key_commitment) and its key_commitment formula. Deliberately does NOT hold the group master key
/// itself — the same split `V2Binding` uses: the master is returned to the CALLER by whichever
/// `V2GroupProcessor` method installs it (genesis/handleWelcome), never stored inside this module.
/// Where that master then lives long-term (a key_record table, v1.4 section 38) is DATA-01's job.
/// Ported from `src/secutg/v2/group/state.ts` and `org.telegram.secutg.v2.group.GroupState`.
public struct V2GroupState: Codable {
    public enum Mode: Codable {
        case auto, manual
    }

    public struct AdminAclEntry: Equatable, Codable {
        public let deviceId: String
        public let identityPk: String

        public init(deviceId: String, identityPk: String) {
            self.deviceId = deviceId
            self.identityPk = identityPk
        }
    }

    public struct DeviceKeys: Codable {
        public let identityPk: String
        public let encapsulationPk: String

        public init(identityPk: String, encapsulationPk: String) {
            self.identityPk = identityPk
            self.encapsulationPk = encapsulationPk
        }
    }

    public let groupId: String
    /// Fixed for the group's entire lifetime — never changes across COMMIT/rebuild.
    public let genesisId: String
    /// base64url digest of the wire event (GENESIS, or later a winning COMMIT) that produced this
    /// state.
    public let stateHash: String
    public let epoch: Int
    public let mode: Mode
    public let adminAcl: [AdminAclEntry]
    /// device_ids with a valid permit for THIS epoch — who a WELCOME/COMMIT master reaches.
    public let deviceRoster: [String]
    /// Every device ever registered (JOIN_REQUEST approved), including ones no longer in
    /// deviceRoster — mirrors Binding.deviceKeys's "grown, never shrunk" precedent.
    public let deviceKeys: [String: DeviceKeys]
    public let keyCommitment: String
    /// v1.4 section 12 (G-36/G-37): a mode switch (either direction) changes the group's trust
    /// boundary and needs a deliberate user confirmation before sending resumes — false the moment a
    /// switch_mode COMMIT is installed, true for every OTHER state (GENESIS, an ordinary rekey, a
    /// roster change).
    public let modeConfirmed: Bool

    public init(
        groupId: String, genesisId: String, stateHash: String, epoch: Int, mode: Mode, adminAcl: [AdminAclEntry],
        deviceRoster: [String], deviceKeys: [String: DeviceKeys], keyCommitment: String, modeConfirmed: Bool
    ) {
        self.groupId = groupId
        self.genesisId = genesisId
        self.stateHash = stateHash
        self.epoch = epoch
        self.mode = mode
        self.adminAcl = adminAcl
        self.deviceRoster = deviceRoster
        self.deviceKeys = deviceKeys
        self.keyCommitment = keyCommitment
        self.modeConfirmed = modeConfirmed
    }

    private func with(deviceRoster: [String], deviceKeys: [String: DeviceKeys]) -> V2GroupState {
        return V2GroupState(groupId: groupId, genesisId: genesisId, stateHash: stateHash, epoch: epoch, mode: mode, adminAcl: adminAcl, deviceRoster: deviceRoster, deviceKeys: deviceKeys, keyCommitment: keyCommitment, modeConfirmed: modeConfirmed)
    }

    private func with(modeConfirmed: Bool) -> V2GroupState {
        return V2GroupState(groupId: groupId, genesisId: genesisId, stateHash: stateHash, epoch: epoch, mode: mode, adminAcl: adminAcl, deviceRoster: deviceRoster, deviceKeys: deviceKeys, keyCommitment: keyCommitment, modeConfirmed: modeConfirmed)
    }

    public final class GroupStateStore {
        private var current: [String: V2GroupState] = [:]
        private var historical: [String: [V2GroupState]] = [:]

        public init() { }

        /// GENESIS happens exactly once per group — a second attempt for the same groupId is
        /// refused, not overwritten.
        @discardableResult
        public func installGenesis(_ state: V2GroupState) -> Bool {
            guard current[state.groupId] == nil else { return false }
            current[state.groupId] = state
            return true
        }

        public func current(_ groupId: String) -> V2GroupState? {
            return current[groupId]
        }

        public func historical(_ groupId: String) -> [V2GroupState] {
            return historical[groupId] ?? []
        }

        /// The state (current or historical) with this exact stateHash — used to validate a COMMIT's
        /// parent_hash reference against ANY state this device has ever held, not just the current
        /// one (v1.4 section 14's trustedState(event.parent_hash)).
        public func findByStateHash(groupId: String, stateHash: String) -> V2GroupState? {
            if let c = current[groupId], c.stateHash == stateHash { return c }
            return historical(groupId).first { $0.stateHash == stateHash }
        }

        /// v1.4 section 15's E2 header carries (genesis_or_binding, epoch), not a state_hash directly
        /// — a recipient resolves the SPECIFIC generation's state_hash (the actual HKDF salt) by
        /// looking up which locally-known state has this genesisId and epoch.
        public func findByGenesisAndEpoch(groupId: String, genesisId: String, epoch: Int) -> V2GroupState? {
            if let c = current[groupId], c.genesisId == genesisId, c.epoch == epoch { return c }
            return historical(groupId).first { $0.genesisId == genesisId && $0.epoch == epoch }
        }

        /// v1.4 section 11/section 35 (G-06+): admin rekey. A COMMIT genuinely produces a NEW,
        /// distinct stateHash each time — the OLD current state moves to historical (still readable,
        /// section 38's HISTORICAL_READ_ONLY), never discarded. A no-op if groupId has no current
        /// state at all.
        public func applyCommit(groupId: String, newState: V2GroupState) {
            guard let c = current[groupId] else { return }
            historical[groupId, default: []].append(c)
            current[groupId] = newState
        }

        /// v1.4 section 10/section 34 (G-02/G-03/G-05): adds a newly-permitted device to the
        /// CURRENT state, without touching epoch or stateHash. A device already on file is left
        /// untouched (G-03: "a new public key must not silently overwrite the original device key").
        @discardableResult
        public func addDevice(groupId: String, deviceId: String, keys: DeviceKeys) -> Bool {
            guard let c = current[groupId] else { return false }
            guard c.deviceKeys[deviceId] == nil else { return false }
            var newRoster = c.deviceRoster
            newRoster.append(deviceId)
            newRoster.sort()
            var newDeviceKeys = c.deviceKeys
            newDeviceKeys[deviceId] = keys
            current[groupId] = c.with(deviceRoster: newRoster, deviceKeys: newDeviceKeys)
            return true
        }

        /// v1.4 section 12 (G-36/G-37): the user has explicitly accepted the mode change — a no-op
        /// if the current state was already confirmed.
        public func confirmModeSwitch(_ groupId: String) {
            guard let c = current[groupId] else { return }
            current[groupId] = c.with(modeConfirmed: true)
        }

        public func allGroupIds() -> [String] {
            return Array(current.keys)
        }

        // MARK: persistence (Web integration draft 1/4)

        /// Every field of `V2GroupState` is already JSON-safe — a plain structural copy, mirroring
        /// `group/state.ts`'s own `toSnapshot`.
        public struct Snapshot: Codable {
            public var current: [V2GroupState]
            public var historical: [String: [V2GroupState]]
        }

        public func toSnapshot() -> Snapshot {
            return Snapshot(current: Array(current.values), historical: historical)
        }

        public static func fromSnapshot(_ snapshot: Snapshot) -> GroupStateStore {
            let store = GroupStateStore()
            for state in snapshot.current { store.current[state.groupId] = state }
            for (groupId, list) in snapshot.historical { store.historical[groupId] = list }
            return store
        }
    }

    private static let keyCommitmentDomain = "secuTG/v2/group-key"

    /// v1.4 section 13: SHA256(UTF8("secuTG/v2/group-key") || genesis_id raw bytes || epoch as
    /// 8-byte big-endian || master). nil only if genesisIdB64 fails to decode.
    public static func computeKeyCommitment(genesisIdB64: String, epoch: Int, master: [UInt8]) -> [UInt8]? {
        guard let genesisIdBytes = Base64Url.decode(genesisIdB64) else { return nil }
        var epochBytes = [UInt8](repeating: 0, count: 8)
        var value = UInt64(epoch)
        for i in stride(from: 7, through: 0, by: -1) {
            epochBytes[i] = UInt8(value & 0xff)
            value >>= 8
        }
        return V2Suite.sha256(V2Suite.concatBytes(V2Suite.utf8(keyCommitmentDomain), genesisIdBytes, epochBytes, master))
    }
}
