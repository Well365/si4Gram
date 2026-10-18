import Foundation

/// PLAN.md 3.45.2 / 3.45.7 "按消息 id 去重": which messages the capture is already building an event for.
///
/// A message can reach the capture several ways, all on the assistant queue: the sent-message tap and the server's
/// echo of the same message (either first), another device's message through the incoming hook, and the offline
/// rescan. The rule that keeps it to one event per message id is split between two places:
///
/// - this gate — at most one build in flight per message: `begin` says no while one is running (a tap and its echo,
///   a second live sighting) or when the watermarks already judged / emitted the message; `end` when the build is
///   over, whether it produced an event or not;
/// - `AssistantWatermarks` — right before publishing, `shouldConsider` is asked again on the same queue, and after the
///   queue file is written `markEmitted` records the id. So the rescan (which does not look at the gate) and a live
///   build racing on the same id publish once: whichever comes second sees the id emitted.
///
/// A crash after the queue file was written but before the watermarks were saved re-emits the message after the
/// restart under a new seq but the same `event_id` (`c-<chat>-<id>` / `m-<chat>-<id>`); the assistant stores events by
/// `event_id` and drops the repeat. The capture never promises more than that.
public struct AssistantCaptureGate: Equatable {
    public struct Key: Hashable {
        public let chat: Int64
        public let namespace: Int32
        public let messageId: Int32

        public init(chat: Int64, namespace: Int32, messageId: Int32) {
            self.chat = chat
            self.namespace = namespace
            self.messageId = messageId
        }
    }

    public private(set) var inflight: Set<Key>

    public init() {
        self.inflight = []
    }

    public func isInflight(_ key: Key) -> Bool {
        return inflight.contains(key)
    }

    /// Start building an event for `key`? False while a build for it is in flight, or when the watermarks say the
    /// message predates capture, was scanned already or was emitted already. True reserves it until `end`.
    public mutating func begin(_ key: Key, date: Int32, marks: AssistantWatermarks) -> Bool {
        guard !inflight.contains(key), marks.shouldConsider(chat: key.chat, messageId: key.messageId, date: date) else { return false }
        inflight.insert(key)
        return true
    }

    /// The build for `key` is over (published, judged not an event, or given up).
    public mutating func end(_ key: Key) {
        inflight.remove(key)
    }

    /// Capture stopped or restarted: builds still scheduled are dropped by their generation check.
    public mutating func reset() {
        inflight.removeAll()
    }
}
