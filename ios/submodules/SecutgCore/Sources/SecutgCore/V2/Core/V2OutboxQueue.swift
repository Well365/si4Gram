import Foundation

/// v1.4 section 16's outbox table (event_id; bytes; status; next_retry, rule: "only send already-
/// committed records") plus section 28's outbox recovery pass. Ported from
/// `src/secutg/v2/outbox.ts` and `org.telegram.secutg.v2.OutboxQueue`.
///
/// v1.4: "commit locks the session revision, generates the event and ciphertext, saves the key
/// reference/state/dedup/outbox, THEN commits, refreshes the UI, sends asynchronously. Before commit
/// there is no network effect; after commit an unsent item is retried by outbox. A send that succeeds
/// but whose receipt is lost is still resent under the SAME event_id." `enqueue` IS that commit step:
/// a caller only calls it once it has already durably decided to send — there is no OTHER status an
/// item could start in. Resending on a lost receipt is just calling `recoverPending` again; it never
/// re-signs or regenerates anything, only replays the exact `bytes` already enqueued.
public final class V2OutboxQueue {
    public enum Status: Codable {
        case pending, sent, cancelled
    }

    public struct Item: Codable {
        public let eventId: String
        /// The exact wire bytes to send — frozen at enqueue time, never regenerated on retry.
        public let bytes: String
        /// v1.4 section 28's ordering families: INVITE/ACCEPT/SELECT/CONFIRM/READY for P2's own
        /// dependency chain; any other string sorts after those five, in enqueue order.
        public let family: String
        public let status: Status
        public let cancelReason: String?
    }

    /// v1.4 section 28: "recover in dependency order: INVITE -> ACCEPT -> SELECT -> CONFIRM -> READY".
    private static let familyOrder = ["INVITE", "ACCEPT", "SELECT", "CONFIRM", "READY"]

    private static func familyRank(_ family: String) -> Int {
        return familyOrder.firstIndex(of: family) ?? familyOrder.count
    }

    public struct ValidityCheck {
        public let valid: Bool
        /// Only set when `!valid` — v1.4 section 28: "if not satisfied, cancel the pending item and
        /// save the reason".
        public let reason: String?

        public static func valid() -> ValidityCheck {
            return ValidityCheck(valid: true, reason: nil)
        }

        public static func invalid(_ reason: String) -> ValidityCheck {
            return ValidityCheck(valid: false, reason: reason)
        }
    }

    private var items: [String: Item] = [:]
    private var insertionOrder: [String] = []

    public init() { }

    /// v1.4: "only send already-committed records" — the only way an item enters this queue, already
    /// committed.
    public func enqueue(eventId: String, bytes: String, family: String) {
        // v1.4 section 7 "never regenerate on retry": a repeat enqueue of the same event_id is a no-op.
        guard items[eventId] == nil else { return }
        items[eventId] = Item(eventId: eventId, bytes: bytes, family: family, status: .pending, cancelReason: nil)
        insertionOrder.append(eventId)
    }

    /// v1.4: "a send that succeeds but whose receipt is lost is still resent under the SAME event_id"
    /// — this only fires once an actual send+ack round trip is confirmed.
    public func markSent(_ eventId: String) {
        guard let item = items[eventId], item.status == .pending else { return }
        items[eventId] = Item(eventId: item.eventId, bytes: item.bytes, family: item.family, status: .sent, cancelReason: nil)
    }

    public func cancel(eventId: String, reason: String) {
        guard let item = items[eventId], item.status == .pending else { return }
        items[eventId] = Item(eventId: item.eventId, bytes: item.bytes, family: item.family, status: .cancelled, cancelReason: reason)
    }

    public func get(_ eventId: String) -> Item? {
        return items[eventId]
    }

    /// Pending items in v1.4 section 28's dependency order (family rank, then enqueue order within a
    /// family).
    public func pending() -> [Item] {
        var out: [Item] = []
        for id in insertionOrder {
            if let item = items[id], item.status == .pending { out.append(item) }
        }
        out.sort { V2OutboxQueue.familyRank($0.family) < V2OutboxQueue.familyRank($1.family) }
        return out
    }

    /// v1.4 section 28's whole recovery pass, minus the parts that are the caller's own business logic
    /// (revoking, re-checking authorization) rather than this queue's — supplied via `isValid` since
    /// this queue has no way to know any of it itself. Items are visited in dependency order; a
    /// failing check cancels the item (with its reason recorded) and the survivors — still PENDING,
    /// never mutated otherwise — are returned for the caller to actually resend, verbatim bytes,
    /// unchanged eventId.
    public func recoverPending(isValid: (Item) -> ValidityCheck) -> [Item] {
        var survivors: [Item] = []
        for item in pending() {
            let check = isValid(item)
            if check.valid {
                survivors.append(item)
            } else {
                cancel(eventId: item.eventId, reason: check.reason ?? "")
            }
        }
        return survivors
    }

    /// Exposed for tests and a future persistence layer, not for protocol logic.
    public var size: Int {
        return items.count
    }

    // MARK: persistence (Web integration draft 1/4)

    /// Every field is already JSON-safe (strings only) — a plain structural copy, preserving
    /// insertion order, mirroring `outbox.ts`'s own `toSnapshot`.
    public struct Snapshot: Codable {
        public var items: [Item]
    }

    public func toSnapshot() -> Snapshot {
        return Snapshot(items: insertionOrder.compactMap { items[$0] })
    }

    public static func fromSnapshot(_ snapshot: Snapshot) -> V2OutboxQueue {
        let queue = V2OutboxQueue()
        for item in snapshot.items {
            queue.items[item.eventId] = item
            queue.insertionOrder.append(item.eventId)
        }
        return queue
    }
}
