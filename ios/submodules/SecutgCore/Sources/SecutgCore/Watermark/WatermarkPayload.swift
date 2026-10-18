import Foundation

/// Time, the one payload field that is not an identity (PLAN.md 3.21.1).
/// Ported from Web A `src/secutg/watermark/payload.ts`.
public enum WatermarkPayload {
    /// How coarse the time in a payload is.
    public static let bucketMinutes = 10

    /// The window the screen is being looked at in, not the date of any message.
    ///
    /// One payload covers the whole conversation area, so a crop spanning several messages holds one coherent field
    /// rather than two overlapping ones — which is what makes a fragment readable at all. That forces the time to be
    /// about the viewing rather than about a message, and it is the more useful answer anyway: it says when the leak
    /// was taken. Coarse enough that the pattern rarely changes under a reader's eyes, fine enough to place a leak
    /// within an evening.
    public static func timeBucket(nowSeconds: Int64) -> Int {
        let period = Int64(60 * bucketMinutes)
        // Floor division, so a clock set before 1970 does not round towards zero and change the phase mid-screen.
        let quotient = nowSeconds / period
        let floored = (nowSeconds % period != 0 && nowSeconds < 0) ? quotient - 1 : quotient
        return Int(floored)
    }
}
