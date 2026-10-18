import Foundation

/// First-successful-write-wins CAS on a named slot (v1.4 section 6's own paragraph on races). Ported
/// from `src/secutg/v2/store.ts` and `org.telegram.secutg.v2.SelectionCas`.
///
/// Deliberately NOT a general key-value store: `select` is the only write operation, it never updates
/// an existing slot, and there is no delete. A slot answering "who won" must go on answering the same
/// thing for its whole life — v1.4 section 6 never describes a losing candidate becoming the winner
/// later, only new slots (a new txn_id after an explicit CANCEL/replace) starting fresh.
public final class V2SelectionCas<TId: Codable> {
    public struct SelectResult {
        public let won: Bool
        public let selected: TId
    }

    private var slots: [String: TId] = [:]

    public init() { }

    /// Claims `slotKey` for `candidateId`. If the slot is empty, this candidate wins and `selected`
    /// equals `candidateId`. If it is already taken — by this same candidate (a retry) or by a
    /// different one (a genuine race) — `selected` is whoever actually holds it, and `won` says which
    /// case this is.
    public func select(slotKey: String, candidateId: TId) -> SelectResult {
        if let existing = slots[slotKey] {
            return SelectResult(won: false, selected: existing)
        }
        slots[slotKey] = candidateId
        return SelectResult(won: true, selected: candidateId)
    }

    public func get(_ slotKey: String) -> TId? {
        return slots[slotKey]
    }

    public func has(_ slotKey: String) -> Bool {
        return slots[slotKey] != nil
    }

    /// Forcibly replaces whatever `slotKey` holds — the "new slot starting fresh" case this class's
    /// own doc names (a new txn_id after an explicit CANCEL/replace) but `select` cannot itself
    /// perform, being permanently-once-set by design. The caller must have independently confirmed the
    /// previous winner is no longer live before calling this.
    public func forceReplace(slotKey: String, candidateId: TId) {
        slots[slotKey] = candidateId
    }

    // MARK: persistence (fix E1: chat-slot CAS now survives a reload — see `V2PersistedState`'s
    // own doc comment for why this was excluded before and why the sole real instantiation,
    // `V2Processor.PairingProcessor`'s `chatSlot: V2SelectionCas<String>`, is now included).

    public struct Snapshot: Codable {
        public var slots: [String: TId]
    }

    public func toSnapshot() -> Snapshot {
        return Snapshot(slots: slots)
    }

    public static func fromSnapshot(_ snapshot: Snapshot) -> V2SelectionCas<TId> {
        let cas = V2SelectionCas<TId>()
        cas.slots = snapshot.slots
        return cas
    }
}
