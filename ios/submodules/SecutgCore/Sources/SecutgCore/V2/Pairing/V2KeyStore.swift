import Foundation

/// P2's local record of which generation's master THIS device actually holds — the private-chat
/// analog of `V2GroupKeyStore`, needed for the same reason: actually SENDING/RECEIVING E2 business
/// messages needs SOME local record of "do I have this generation's key". Ported from
/// `src/secutg/v2/pairing/keystore.ts` and `org.telegram.secutg.v2.pairing.KeyStore`.
///
/// Keyed by (bindingId, epoch) rather than a group's single state_hash key: a private-chat bindingId
/// is FIXED across the binding's entire life (unlike a group's per-generation state_hash), so epoch is
/// what actually distinguishes one generation's master from another within the SAME binding.
public enum V2KeyStore {
    public enum Status: Codable {
        case current, historical, missing, conflict
    }

    public struct Record: Codable {
        public let bindingId: String
        public let epoch: Int
        public let status: Status
        public let master: [UInt8]?

        public init(bindingId: String, epoch: Int, status: Status, master: [UInt8]?) {
            self.bindingId = bindingId
            self.epoch = epoch
            self.status = status
            self.master = master
        }
    }

    public final class BindingKeyStore {
        private var byBinding: [String: [Int: Record]] = [:]

        public init() { }

        public func set(_ record: Record) {
            byBinding[record.bindingId, default: [:]][record.epoch] = record
        }

        public func get(_ bindingId: String, _ epoch: Int) -> Record? {
            return byBinding[bindingId]?[epoch]
        }

        public func all(_ bindingId: String) -> [Record] {
            return byBinding[bindingId].map { Array($0.values) } ?? []
        }

        /// Every generation currently marked MISSING for this binding — what a caller would drive a
        /// re-request retry loop from.
        public func missing(_ bindingId: String) -> [Record] {
            return all(bindingId).filter { $0.status == .missing }
        }

        /// Demotes whatever WAS CURRENT for this binding to HISTORICAL — the same "exactly one
        /// current at a time" invariant group.KeyStore also enforces.
        public func demoteCurrentToHistorical(_ bindingId: String) {
            for r in all(bindingId) where r.status == .current {
                set(Record(bindingId: r.bindingId, epoch: r.epoch, status: .historical, master: r.master))
            }
        }

        /// Demotes whatever was current, then installs this generation as the new (sole) current one.
        public func installCurrent(bindingId: String, epoch: Int, master: [UInt8]) {
            demoteCurrentToHistorical(bindingId)
            set(Record(bindingId: bindingId, epoch: epoch, status: .current, master: master))
        }

        /// Raw removal, no policy — a P-38-equivalent confirm-before-delete check, if built, lives
        /// elsewhere.
        public func remove(bindingId: String, epoch: Int) {
            byBinding[bindingId]?.removeValue(forKey: epoch)
        }

        /// Every bindingId this store holds any record for.
        public func allBindingIds() -> [String] {
            return Array(byBinding.keys)
        }

        // MARK: persistence (Web integration draft 1/4)

        /// Flat list of every record across every binding — `pairing/keystore.ts`'s own
        /// `toSnapshot` shape, just without the base64url re-wrap (`master` is already a plain
        /// `[UInt8]?`, which Codable already knows how to serialise).
        public struct Snapshot: Codable {
            public var records: [Record]
        }

        public func toSnapshot() -> Snapshot {
            return Snapshot(records: allBindingIds().flatMap { all($0) })
        }

        public static func fromSnapshot(_ snapshot: Snapshot) -> BindingKeyStore {
            let store = BindingKeyStore()
            for record in snapshot.records { store.set(record) }
            return store
        }
    }
}
