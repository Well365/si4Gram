import Foundation

/// v1.4 section 27/30's sync gate: sync_checkpoint plus the CATCHING_UP / SYNCED state door that
/// section 27's own figure calls out by name ("online sync and business sending use independent state
/// gating"). Ported from `src/secutg/v2/sync.ts` and `org.telegram.secutg.v2.SyncGate`.
///
/// What this gate is NOT: a transport client. It does not fetch anything, page through history, or
/// know what a "cursor" points into. It is the STATE a real sync loop is responsible for driving —
/// `beginCatchUp` when a connection opens, `recordGap`/`closeGap` as the real loop discovers and fills
/// holes, `markSynced` when a full pass with no open gaps has completed — and the one question
/// anything else in this codebase is allowed to ask it: `isSynced`. v1.4 section 27: "a transport sync
/// marker only proves the client completed one round of sync on that interface, it does not prove the
/// server withheld nothing" — so this gate is deliberately not a source of confidence beyond that one
/// narrow claim.
public final class V2SyncGate {
    public enum State {
        case catchingUp, synced
    }

    private var state: State = .catchingUp
    private var openGaps: Set<String> = []

    public init() { }

    /// A fresh connection, or a reconnect — always re-enters CATCHING_UP, never assumes yesterday
    /// still holds.
    public func beginCatchUp() {
        state = .catchingUp
    }

    /// The real sync loop found a hole in the transport's incremental cursor.
    public func recordGap(_ gapId: String) {
        openGaps.insert(gapId)
        state = .catchingUp
    }

    /// That hole has now been backfilled and verified.
    public func closeGap(_ gapId: String) {
        openGaps.remove(gapId)
    }

    /// The pass is complete AND no gap is still open. v1.4 section 27: "only after paging fully
    /// completes and known gaps are backfilled...publish the final UI state" — `markSynced` is that
    /// one publish, and it refuses to fire while a gap remains, so a caller cannot accidentally flip
    /// the door open by calling this at the wrong moment.
    @discardableResult
    public func markSynced() -> Bool {
        guard openGaps.isEmpty else { return false }
        state = .synced
        return true
    }

    public var isSynced: Bool {
        return state == .synced
    }

    public var hasOpenGaps: Bool {
        return !openGaps.isEmpty
    }
}
