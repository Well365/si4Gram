import Foundation

/// Dedup by event_id (v1.4 section 16's event_log). Ported from `src/secutg/v2/store.ts` and
/// `org.telegram.secutg.v2.EventLog`.
///
/// v1.4 section 14's own pseudocode states the rule once for group COMMITs ("if identical verified
/// event already seen: return saved_result") but it is the general shape every family's receive path
/// needs: a retry resends the exact same signed bytes under the exact same event_id (v1.4 section 7:
/// never regenerate on retry), so the SAME event_id arriving twice with the SAME content is an
/// ordinary retry and must replay its saved result rather than redo the work. The SAME event_id
/// arriving with DIFFERENT content never happens for a legitimate retry, so it is reported as its own
/// outcome (CONFLICT) rather than silently treated as a replay or allowed to overwrite the first
/// result.
public final class V2EventLog<TResult> {
    public enum Kind {
        case first, replay, conflict
    }

    public struct RecordResult {
        public let kind: Kind
        public let result: TResult?
        /// Only set for CONFLICT — the PREVIOUS result, kept apart from the (non-existent) new one.
        public let existing: TResult?

        fileprivate static func first(_ result: TResult) -> RecordResult {
            return RecordResult(kind: .first, result: result, existing: nil)
        }

        fileprivate static func replay(_ result: TResult) -> RecordResult {
            return RecordResult(kind: .replay, result: result, existing: nil)
        }

        fileprivate static func conflict(_ existing: TResult) -> RecordResult {
            return RecordResult(kind: .conflict, result: nil, existing: existing)
        }
    }

    private struct Outcome {
        let contentHash: String
        let result: TResult
    }

    private var seen: [String: Outcome] = [:]

    public init() { }

    /// Records the result of handling `eventId` for the first time this instance has seen it, or
    /// reports what happened before if it has. Never overwrites a stored outcome — the caller decides
    /// what to do with a CONFLICT, this class does not silently pick one.
    public func record(eventId: String, contentHash: String, computeResult: () -> TResult) -> RecordResult {
        if let existing = seen[eventId] {
            if existing.contentHash == contentHash { return .replay(existing.result) }
            return .conflict(existing.result)
        }
        let result = computeResult()
        seen[eventId] = Outcome(contentHash: contentHash, result: result)
        return .first(result)
    }

    public func has(_ eventId: String) -> Bool {
        return seen[eventId] != nil
    }

    /// Exposed for tests and for a future persistence layer to snapshot from, not for protocol logic.
    public var size: Int {
        return seen.count
    }
}
