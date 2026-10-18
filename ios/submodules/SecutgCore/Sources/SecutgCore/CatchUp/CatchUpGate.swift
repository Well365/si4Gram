import Foundation

/// PLAN.md 3.47 point 1: one catch-up pass at a time per account, and a trigger that arrives while one is running
/// is not lost — it buys exactly one more pass after the current one ends, however many triggers arrived.
///
/// A pass that ran out of its time budget with work left also asks for another pass, so a backlog drains without
/// waiting for the next time the app comes to the foreground; `CatchUp.maxChainedPasses` bounds that chain so a
/// chat that can never be finished (a scan that keeps finding work) cannot keep the database busy forever. A real
/// trigger always resets the chain.
///
/// Thread-safe; the caller runs the pass wherever it likes and reports back with `finish`.
public final class CatchUpGate {
    private let lock = NSLock()
    private var running = false
    private var rerunRequested = false
    private var chained = 0
    private let maxChained: Int

    public init(maxChainedPasses: Int = CatchUp.maxChainedPasses) {
        self.maxChained = max(0, maxChainedPasses)
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// A trigger (runtime start, app foreground). true = start a pass now; false = one is running and will be
    /// followed by another.
    public func request() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running {
            rerunRequested = true
            return false
        }
        running = true
        chained = 0
        return true
    }

    /// The pass ended. `moreWork`: it stopped on its budget with chats or messages left. true = start the next pass
    /// now (the gate stays held); false = the gate is released.
    public func finish(moreWork: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard running else { return false }
        if rerunRequested {
            rerunRequested = false
            chained = 0
            return true
        }
        if moreWork && chained < maxChained {
            chained += 1
            return true
        }
        running = false
        chained = 0
        return false
    }
}
