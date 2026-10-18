import Foundation

/// PLAN.md 3.15 #4: every guide step must fit within the screen/window's available height — no vertical
/// scrolling. "指南本来就是'一步一屏'的翻页形式，一步还要滚，等于这一步没讲完就先让人操作。" Compression proceeds
/// through a fixed, ordered sequence of levels and stops at the first level whose content fits, so a step is
/// never compressed more than it has to be:
///
///   1. `tightSpacing` — tighten the gaps between elements and the body text's line height. Font sizes and the
///      phone illustration are untouched.
///   2. `scaledPhone`  — additionally scale the phone illustration down, uniformly (locked aspect ratio, never
///      cropped — PLAN.md 3.15: "窗口特别矮时配图可以整体等比缩小，但不许裁切").
///   3. `smallerBody`  — additionally shrink the body text's *font size* (never its wording: the guide's text
///      content has exactly one source, `secutg-guide.json`, and nothing at render time may truncate or
///      rewrite it — PLAN.md 3.15: "这里说的是缩小字号，不是删减文字").
///
/// The phone illustration and the body text are shrunk only as the last two resorts, in that order, because
/// PLAN.md 3.15 says both are worth more than blank space: the illustration is what a step is checked
/// against, the text is what explains it.
///
/// This file is intentionally self-contained: it does not reference `SecutgGuideModel` or `SecutgPhoneLayout`
/// (whose two client ports have already diverged — the iOS and macOS copies of this package were written
/// independently for PLAN.md 3.15 rules 1-3/5 and are no longer byte-identical), so this decision's own
/// arithmetic can stay byte-for-byte identical between iOS and macOS regardless. It has no UIKit/AppKit
/// dependency: each renderer measures its own fonts and metrics and passes the results in, which is also what
/// keeps this file testable with a plain `swift test`.
public enum SecutgGuideFit {
    /// One compression level, from `normal` (no compression) to `smallerBody` (maximum). Order matters:
    /// `allCases` is walked from least to most compressed, and `level(availableHeight:heightForLevel:)` stops
    /// at the first one whose content fits.
    public enum Level: Int, CaseIterable, Comparable {
        case normal = 0
        case tightSpacing = 1
        case scaledPhone = 2
        case smallerBody = 3

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// The spacing multipliers a renderer applies at one level, shared so iOS and macOS tighten by the same
    /// amount instead of guessing independently. `lineHeightScale` is deliberately less aggressive than
    /// `gapScale`: squeezing the gaps *between* elements has no readability cost, but squeezing line height
    /// much further than this starts crowding lines of text into each other.
    public struct Style: Equatable {
        /// Multiplies the vertical gaps between elements (and the top inset before the first one).
        public let gapScale: Double
        /// Multiplies the body text's line height / paragraph line spacing.
        public let lineHeightScale: Double

        public init(gapScale: Double, lineHeightScale: Double) {
            self.gapScale = gapScale
            self.lineHeightScale = lineHeightScale
        }
    }

    /// Below this the phone illustration stops reading as a picture of a real screen — PLAN.md 3.15's "整体
    /// 等比缩小" still needs a floor.
    public static let minimumPhoneScale: Double = 0.55
    /// Below this the body text stops being comfortably readable on a phone.
    public static let minimumBodyFontScale: Double = 0.8

    /// `tightSpacing`'s gap/line-height multipliers carry forward unchanged into `scaledPhone` and
    /// `smallerBody`: each level only ever adds one more *kind* of compression on top of the levels before
    /// it, it never re-loosens what an earlier level already tightened.
    public static func style(for level: Level) -> Style {
        switch level {
        case .normal:
            return Style(gapScale: 1.0, lineHeightScale: 1.0)
        case .tightSpacing, .scaledPhone, .smallerBody:
            return Style(gapScale: 0.6, lineHeightScale: 0.88)
        }
    }

    /// Picks the least-compressed level whose content fits `availableHeight`. `heightForLevel` is supplied by
    /// the caller: for `.scaledPhone` and `.smallerBody` it should be the *best case* height at that level —
    /// i.e. with the phone illustration (respectively, the body font) already shrunk to its floor — since
    /// that is what determines whether the level can work at all; once a level is chosen, the caller dials
    /// back from the floor with `fitScale` so it uses no more compression than the level actually needs.
    /// Evaluated in order and stops at the first match, so a caller may compute heights lazily. Falls back to
    /// the most compressed level when nothing fits: a step must never scroll, so the smallest achievable
    /// height is still the best available choice even when it does not fully fit.
    public static func level(availableHeight: Double, heightForLevel: (Level) -> Double) -> Level {
        for level in Level.allCases {
            if heightForLevel(level) <= availableHeight {
                return level
            }
        }
        return Level.allCases.last!
    }

    /// Finds the largest scale in `[minimumScale, 1.0]` whose measured height fits `available`, assuming
    /// `heightAtScale` is non-increasing as scale decreases (shrinking never makes content taller). Used for
    /// both the phone illustration and the body font, so neither is shrunk more than the chosen level
    /// actually needs. Returns `minimumScale` when even that does not fit — the caller must still show
    /// something, and the smallest allowed size is the least-bad option — and `1.0` when no shrinking is
    /// needed at all.
    public static func fitScale(available: Double, minimumScale: Double, heightAtScale: (Double) -> Double) -> Double {
        guard heightAtScale(1.0) > available else { return 1.0 }
        guard heightAtScale(minimumScale) <= available else { return minimumScale }
        var lo = minimumScale
        var hi = 1.0
        for _ in 0..<10 {
            let mid = (lo + hi) / 2.0
            if heightAtScale(mid) <= available {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }
}
