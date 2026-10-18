import Foundation

/// v1.4 section 38's key_record — per (groupId, stateHash), whether THIS device currently holds the
/// master for that generation, and why not if it doesn't (TEST_MATRIX G-25-G-35, offline catch-up /
/// cross-generation). Deliberately separate from `V2GroupState.GroupStateStore`: a device can know a
/// state EXISTS without ever having gotten ITS key — that gap is what this file exists to record.
/// Ported from `src/secutg/v2/group/keystore.ts` and `org.telegram.secutg.v2.group.GroupKeyStore`.
public final class V2GroupKeyStore {
    public enum Status: Codable {
        case current, historical, missing, conflict
    }

    public struct KeyRecord: Codable {
        public let groupId: String
        public let stateHash: String
        public let epoch: Int
        public let status: Status
        public let master: [UInt8]?

        public init(groupId: String, stateHash: String, epoch: Int, status: Status, master: [UInt8]?) {
            self.groupId = groupId
            self.stateHash = stateHash
            self.epoch = epoch
            self.status = status
            self.master = master
        }
    }

    private var byGroup: [String: [String: KeyRecord]] = [:]

    public init() { }

    public func set(_ record: KeyRecord) {
        byGroup[record.groupId, default: [:]][record.stateHash] = record
    }

    public func get(_ groupId: String, _ stateHash: String) -> KeyRecord? {
        return byGroup[groupId]?[stateHash]
    }

    public func all(_ groupId: String) -> [KeyRecord] {
        return byGroup[groupId].map { Array($0.values) } ?? []
    }

    /// Every state currently marked MISSING for this group.
    public func missing(_ groupId: String) -> [KeyRecord] {
        return all(groupId).filter { $0.status == .missing }
    }

    /// Raw removal, no policy.
    public func remove(groupId: String, stateHash: String) {
        byGroup[groupId]?.removeValue(forKey: stateHash)
    }

    /// Every groupId this store holds any record for.
    public func allGroupIds() -> [String] {
        return Array(byGroup.keys)
    }

    // MARK: persistence (Web integration draft 1/4)

    /// Flat list of every record across every group — `group/keystore.ts`'s own `toSnapshot` shape,
    /// just without the base64url re-wrap (`master` is already a plain `[UInt8]?`).
    public struct Snapshot: Codable {
        public var records: [KeyRecord]
    }

    public func toSnapshot() -> Snapshot {
        return Snapshot(records: allGroupIds().flatMap { all($0) })
    }

    public static func fromSnapshot(_ snapshot: Snapshot) -> V2GroupKeyStore {
        let store = V2GroupKeyStore()
        for record in snapshot.records { store.set(record) }
        return store
    }
}
