import Foundation

/// PLAN.md 3.39.2's capacity rule, as a pure function so every client can run the same decision on the same inputs
/// (see `vectors-v2clone.json`'s `fit` cases). Mirrors Web A `src/secutg/v2/join/capacity.ts`; the order is 3.39.12's,
/// kept by 3.39.13 for the clone payload.
///
/// QR byte mode, version 40: 2331 bytes at error correction M, 2953 at L. For k = 0, 1, … oldest history masters
/// dropped (the code page then says `SecutgQuickSharePartial {n}`):
///   1. fits M → M;
///   2. else fits L → L;
///   3. else drop one more;
/// and when even the current master alone does not fit L → `tooLarge` (`SecutgQuickShareTooLarge`).
/// So every history master that CAN ride along does, at the cost of L's weaker correction; M is taken whenever the
/// same set of keys happens to fit it.
public enum V2JoinCapacity {
    public enum ErrorCorrection: String, Equatable {
        case m = "M"
        case l = "L"
    }

    public static let maxBytes: [ErrorCorrection: Int] = [.m: 2331, .l: 2953]
    private static let order: [ErrorCorrection] = [.m, .l]

    public enum Fit: Equatable {
        /// `historyKept`: how many of the history entries went in (newest first).
        case fits(text: String, ecc: ErrorCorrection, bytes: Int, historyKept: Int, historyDropped: Int)
        case tooLarge
    }

    /// The V2Q text is pure ASCII (Crockford + base64url), so its byte length is its length — counted in UTF-8 anyway.
    public static func byteLength(_ text: String) -> Int {
        return text.utf8.count
    }

    /// `historyNewestFirst` is the binding's earlier masters, newest first; `render(kept)` builds the complete V2Q
    /// text for the current master plus `kept` (always a prefix of the history). Rendering encrypts, but the length
    /// depends only on the plaintext, so the search is deterministic.
    public static func fit<T>(
        historyNewestFirst: [T], maxBytes: [ErrorCorrection: Int] = maxBytes, render: ([T]) throws -> String
    ) rethrows -> Fit {
        var kept = historyNewestFirst.count
        while kept >= 0 {
            let text = try render(Array(historyNewestFirst.prefix(kept)))
            let bytes = byteLength(text)
            for ecc in order {
                guard let limit = maxBytes[ecc], bytes <= limit else { continue }
                return .fits(text: text, ecc: ecc, bytes: bytes, historyKept: kept, historyDropped: historyNewestFirst.count - kept)
            }
            kept -= 1
        }
        return .tooLarge
    }
}
