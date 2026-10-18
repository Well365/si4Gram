import Foundation

/// PLAN.md 3.39.13 「必改项」 1: the P2 event ids THIS device built — what tells this device's own echo from a message
/// its clone sent. A clone (a device that imported a V2Q) acts in the chat under exactly the same device identity as
/// the device that showed the code, so `actor_device` can no longer say "I sent this": two machines sign with one key.
/// What only the sender knows is the `event_id` it drew — every P2 wire this device builds is recorded here at BUILD
/// time (`V2Runtime.noteSent`, before iOS / macOS run their own local copy back through `transformIncoming`), and an
/// outgoing P2 whose id is not here was sent by another device of the account. Mirrors Web A `pairing/ownEvents.ts`.
///
/// Bounded: the newest `capacity` ids by `created_ms`; an older one falls off. A message that old re-rendering after it
/// fell off — like every one this device built before 3.39.13 — is classified as the clone sibling's, which every
/// clone handler tolerates (each is idempotent and checks the binding / epoch / creation time first).
///
/// Persisted inside `V2PersistedState` (optional there, so a snapshot written before 3.39.13 decodes to an empty log;
/// the 3.39.12 `join_pending` record that used to sit beside it is simply no longer read).
public final class V2SentEventStore {
    /// How many ids are kept (Web A's `OWN_EVENT_LOG_CAPACITY`).
    public static let capacity = 512

    private var createdMsById: [String: Int64] = [:]

    public init() { }

    /// Records one event id this device built. Idempotent.
    public func record(eventId: String, createdMs: Int64) {
        createdMsById[eventId] = createdMs
        guard createdMsById.count > V2SentEventStore.capacity else { return }
        let evicted = createdMsById.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
            .prefix(createdMsById.count - V2SentEventStore.capacity)
        for (id, _) in evicted { createdMsById.removeValue(forKey: id) }
    }

    public func contains(_ eventId: String) -> Bool {
        return createdMsById[eventId] != nil
    }

    public var count: Int { return createdMsById.count }

    // MARK: persistence

    public struct Snapshot: Codable, Equatable {
        public var createdMsById: [String: Int64]
    }

    public func toSnapshot() -> Snapshot {
        return Snapshot(createdMsById: createdMsById)
    }

    public static func fromSnapshot(_ snapshot: Snapshot?) -> V2SentEventStore {
        let store = V2SentEventStore()
        guard let snapshot = snapshot else { return store }
        store.createdMsById = snapshot.createdMsById
        return store
    }
}
