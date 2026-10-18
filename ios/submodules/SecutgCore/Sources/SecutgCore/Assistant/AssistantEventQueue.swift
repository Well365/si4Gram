import Foundation

/// Where the queue's files live. The macOS glue backs it with `queue/<seq>.json` (0600) in the assistant directory;
/// tests back it with memory. Every method may throw; the queue never swallows a failed write.
public protocol AssistantQueueStorage: AnyObject {
    func listSeqs() throws -> [Int64]
    func write(seq: Int64, data: Data) throws
    func read(seq: Int64) throws -> Data
    func remove(seq: Int64) throws
}

/// PLAN.md 3.45.2 "不漏" / implementation plan C1.6: the durable event queue.
///
/// - `seq` is monotonic and survives restarts: the caller persists `lastSeq` (watermarks.json) after every append,
///   and a crash between the file write and that save is recovered from the files themselves on the next start.
/// - An event is written to its file BEFORE `append` returns, so nothing can be pushed that is not on disk.
/// - `ack(N)` removes every file ≤ N.
/// - At most `cap` files: the oldest go first and are counted in `dropped`.
///
/// Not thread-safe; the owner serialises access (the glue's one assistant queue).
public final class AssistantEventQueue {
    public static let defaultCap = 5000

    public let cap: Int
    public private(set) var lastSeq: Int64
    public private(set) var dropped: Int64
    public private(set) var pending: [Int64]
    private let storage: AssistantQueueStorage

    public init(storage: AssistantQueueStorage, cap: Int = AssistantEventQueue.defaultCap, lastSeq: Int64, dropped: Int64) throws {
        self.storage = storage
        self.cap = max(1, cap)
        let found = try storage.listSeqs().filter { $0 > 0 }.sorted()
        self.pending = found
        self.lastSeq = max(lastSeq, found.last ?? 0)
        self.dropped = max(0, dropped)
    }

    public var pendingCount: Int { return pending.count }

    public struct Appended: Equatable {
        public let seq: Int64
        public let data: Data
        public let evicted: [Int64]
    }

    /// Allocates the next seq, asks `build` for the bytes to store under it, writes them, then evicts past the
    /// cap. The seq is only consumed when the write succeeded.
    public func append(_ build: (Int64) throws -> Data) throws -> Appended {
        let seq = lastSeq + 1
        let data = try build(seq)
        try storage.write(seq: seq, data: data)
        lastSeq = seq
        pending.append(seq)
        // Only a file that is really gone counts as dropped: one that refuses to go stays pending (over the cap
        // for now, tried again on the next append) instead of coming back from the disk after a restart as an
        // event already reported dropped.
        var evicted: [Int64] = []
        while pending.count > cap, let oldest = pending.first, (try? storage.remove(seq: oldest)) != nil {
            pending.removeFirst()
            evicted.append(oldest)
        }
        dropped += Int64(evicted.count)
        return Appended(seq: seq, data: data, evicted: evicted)
    }

    /// Replaces a still-pending event's stored bytes (a `mention.update` folding `context_after` in). False when
    /// the event was already acknowledged or evicted.
    @discardableResult
    public func replace(seq: Int64, data: Data) throws -> Bool {
        guard pending.contains(seq) else { return false }
        try storage.write(seq: seq, data: data)
        return true
    }

    /// Removes every pending event ≤ `seq`; returns the seqs removed. A file that refuses to go stays pending
    /// (and is offered again on the next subscribe) rather than being forgotten while still on disk.
    @discardableResult
    public func ack(_ seq: Int64) -> [Int64] {
        var removed: [Int64] = []
        var kept: [Int64] = []
        for value in pending {
            if value <= seq, (try? storage.remove(seq: value)) != nil {
                removed.append(value)
            } else {
                kept.append(value)
            }
        }
        pending = kept
        return removed
    }

    /// Pending seqs after `since`, oldest first — what a `subscribe(since)` replays.
    public func pending(after since: Int64) -> [Int64] {
        return pending.filter { $0 > since }
    }

    public func read(seq: Int64) -> Data? {
        guard pending.contains(seq) else { return nil }
        return try? storage.read(seq: seq)
    }
}

/// In-memory storage: the tests' backing, and a reference for what the file-backed one must do.
public final class AssistantMemoryQueueStorage: AssistantQueueStorage {
    public private(set) var files: [Int64: Data] = [:]
    /// Every operation in order, e.g. `write:3`, `remove:1` — lets a test assert write-before-push.
    public private(set) var log: [String] = []
    public var failWrites = false
    public var failRemoves = false

    public init() {}

    public func listSeqs() throws -> [Int64] { return Array(files.keys) }

    public func write(seq: Int64, data: Data) throws {
        if failWrites { throw AssistantFailure(.internal, "write failed") }
        files[seq] = data
        log.append("write:\(seq)")
    }

    public func read(seq: Int64) throws -> Data {
        guard let data = files[seq] else { throw AssistantFailure(.notFound, "no such event") }
        return data
    }

    public func remove(seq: Int64) throws {
        if failRemoves { throw AssistantFailure(.internal, "remove failed") }
        files[seq] = nil
        log.append("remove:\(seq)")
    }

    public func note(_ entry: String) { log.append(entry) }
}
