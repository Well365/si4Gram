import Foundation

/// PLAN.md 3.45.2 subscribe / push / ack over the durable queue (implementation plan C1.6), with the socket left
/// out: `push` is whatever writes a line to a connection. Ordering rules this type owns:
/// - `publish`: the event is in its queue file BEFORE any subscriber is pushed it (an event nobody hears is still
///   on disk for the next subscribe); a failed write pushes nothing.
/// - `subscribe(since)`: the answer `{replaying, last_event_seq}` first, then every still-pending event after
///   `since` oldest first — as currently stored, so a `mention.update` already folded in is part of it — and only
///   then live events. Everything runs on the owner's one serial queue, so nothing interleaves.
/// - `publishUpdate`: the stored copy is rewritten if still pending, then `mention.update` is pushed.
///
/// Not thread-safe; the owner serialises access.
public final class AssistantEventHub {
    public typealias Subscriber = Int

    public let queue: AssistantEventQueue
    public private(set) var subscribers: [Subscriber] = []
    private let push: (Subscriber, String) -> Void

    public init(queue: AssistantEventQueue, push: @escaping (Subscriber, String) -> Void) {
        self.queue = queue
        self.push = push
    }

    public func subscribe(_ subscriber: Subscriber, requestId: AssistantJSON, since: Int64) {
        let replay = queue.pending(after: since)
        push(subscriber, AssistantLine.ok(id: requestId, result: AssistantResults.subscribe(replaying: replay.count, lastEventSeq: queue.lastSeq)))
        for seq in replay {
            guard let data = queue.read(seq: seq), let line = String(data: data, encoding: .utf8) else { continue }
            push(subscriber, line.trimmingCharacters(in: .newlines))
        }
        if !subscribers.contains(subscriber) { subscribers.append(subscriber) }
    }

    public func unsubscribe(_ subscriber: Subscriber) {
        subscribers.removeAll { $0 == subscriber }
    }

    public struct Published<Event: AssistantQueuedEvent & Equatable>: Equatable {
        public let event: Event
        public let evicted: [Int64]
    }

    /// Stores the event `build` makes for the next seq, then pushes it to every subscriber. Throws (and pushes
    /// nothing, consumes no seq) when the file cannot be written. A `mention` and a `command` (PLAN.md 3.45.7)
    /// share the one counter and the one queue.
    public func publish<Event: AssistantQueuedEvent & Equatable>(_ build: (Int64) -> Event) throws -> Published<Event> {
        var built: Event?
        let appended = try queue.append { seq in
            let event = build(seq)
            built = event
            return Data((event.line + "\n").utf8)
        }
        guard let event = built else { throw AssistantFailure(.internal, "event was not built") }
        for subscriber in subscribers { push(subscriber, event.line) }
        return Published(event: event, evicted: appended.evicted)
    }

    public func publishUpdate(_ event: AssistantMentionEvent) {
        _ = try? queue.replace(seq: event.seq, data: Data((event.line + "\n").utf8))
        for subscriber in subscribers { push(subscriber, event.updateLine) }
    }

    @discardableResult
    public func ack(_ seq: Int64) -> [Int64] {
        return queue.ack(seq)
    }
}
