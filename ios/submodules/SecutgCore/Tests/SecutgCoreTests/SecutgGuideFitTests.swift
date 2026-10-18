import XCTest
@testable import SecutgCore

/// PLAN.md 3.15 #4: unit coverage for the pure "which compression level fits" decision. No UIKit/AppKit
/// involved — the two renderers' own measurement code can only be checked by compiling each app, but the
/// decision arithmetic itself is fully exercised here.
final class SecutgGuideFitTests: XCTestCase {
    // MARK: Level

    func testLevelOrderIsFixed() {
        XCTAssertEqual(SecutgGuideFit.Level.allCases, [.normal, .tightSpacing, .scaledPhone, .smallerBody])
        XCTAssertTrue(SecutgGuideFit.Level.normal < .tightSpacing)
        XCTAssertTrue(SecutgGuideFit.Level.tightSpacing < .scaledPhone)
        XCTAssertTrue(SecutgGuideFit.Level.scaledPhone < .smallerBody)
    }

    // MARK: style(for:)

    func testNormalLevelIsUncompressed() {
        let style = SecutgGuideFit.style(for: .normal)
        XCTAssertEqual(style.gapScale, 1.0)
        XCTAssertEqual(style.lineHeightScale, 1.0)
    }

    func testCompressedLevelsShareTheSameSpacingAndAreTighterThanNormal() {
        let tight = SecutgGuideFit.style(for: .tightSpacing)
        let scaledPhone = SecutgGuideFit.style(for: .scaledPhone)
        let smallerBody = SecutgGuideFit.style(for: .smallerBody)
        XCTAssertEqual(tight, scaledPhone)
        XCTAssertEqual(tight, smallerBody)
        XCTAssertLessThan(tight.gapScale, 1.0)
        XCTAssertLessThan(tight.lineHeightScale, 1.0)
    }

    // MARK: level(availableHeight:heightForLevel:)

    private func heights(_ table: [SecutgGuideFit.Level: Double]) -> (SecutgGuideFit.Level) -> Double {
        return { level in table[level]! }
    }

    func testLevelPicksTheLeastCompressedThatFits() {
        let table: [SecutgGuideFit.Level: Double] = [.normal: 500, .tightSpacing: 400, .scaledPhone: 300, .smallerBody: 200]
        XCTAssertEqual(SecutgGuideFit.level(availableHeight: 1000, heightForLevel: heights(table)), .normal)
        XCTAssertEqual(SecutgGuideFit.level(availableHeight: 450, heightForLevel: heights(table)), .tightSpacing)
        XCTAssertEqual(SecutgGuideFit.level(availableHeight: 350, heightForLevel: heights(table)), .scaledPhone)
        XCTAssertEqual(SecutgGuideFit.level(availableHeight: 250, heightForLevel: heights(table)), .smallerBody)
    }

    func testLevelBoundaryIsInclusive() {
        let table: [SecutgGuideFit.Level: Double] = [.normal: 500, .tightSpacing: 400, .scaledPhone: 300, .smallerBody: 200]
        // Exactly enough room for tightSpacing (400) but not for normal (500): must not escalate further.
        XCTAssertEqual(SecutgGuideFit.level(availableHeight: 400, heightForLevel: heights(table)), .tightSpacing)
    }

    func testLevelFallsBackToMostCompressedWhenNothingFits() {
        let table: [SecutgGuideFit.Level: Double] = [.normal: 500, .tightSpacing: 400, .scaledPhone: 300, .smallerBody: 200]
        XCTAssertEqual(SecutgGuideFit.level(availableHeight: 50, heightForLevel: heights(table)), .smallerBody)
    }

    func testLevelStopsEvaluatingAtTheFirstMatch() {
        let table: [SecutgGuideFit.Level: Double] = [.normal: 500, .tightSpacing: 400, .scaledPhone: 300, .smallerBody: 200]
        var evaluated: [SecutgGuideFit.Level] = []
        let chosen = SecutgGuideFit.level(availableHeight: 450) { level in
            evaluated.append(level)
            return table[level]!
        }
        XCTAssertEqual(chosen, .tightSpacing)
        XCTAssertEqual(evaluated, [.normal, .tightSpacing])
    }

    // MARK: fitScale(available:minimumScale:heightAtScale:)

    func testFitScaleReturnsFullSizeWhenNoCompressionIsNeeded() {
        var calls: [Double] = []
        let scale = SecutgGuideFit.fitScale(available: 1000, minimumScale: 0.3) { s in
            calls.append(s)
            return 900 * s
        }
        XCTAssertEqual(scale, 1.0)
        // Only the full-size probe was needed — the floor was never even measured.
        XCTAssertEqual(calls, [1.0])
    }

    func testFitScaleReturnsFloorWhenEvenMinimumDoesNotFit() {
        let scale = SecutgGuideFit.fitScale(available: 100, minimumScale: 0.3) { s in 1000 * s }
        XCTAssertEqual(scale, 0.3)
    }

    func testFitScaleConvergesOnALinearRelationship() {
        // heightAtScale(s) = 1000 * s, so the ideal fit for available: 500 is scale 0.5.
        let scale = SecutgGuideFit.fitScale(available: 500, minimumScale: 0.2) { s in 1000 * s }
        XCTAssertEqual(scale, 0.5, accuracy: 0.01)
    }

    func testFitScaleResultAlwaysFitsWhenTheFloorAllowsIt() {
        // A step function (integer line counts behave like this): not strictly monotonic, but still
        // non-increasing as scale decreases. Whenever the floor itself fits, the chosen scale must too —
        // fitScale never leaves room on the table once a fit is possible at all.
        func heightAtScale(_ s: Double) -> Double {
            if s > 0.8 { return 300 }
            if s > 0.6 { return 220 }
            if s > 0.4 { return 150 }
            return 90
        }
        for available in stride(from: 90.0, through: 320.0, by: 17.0) {
            let scale = SecutgGuideFit.fitScale(available: available, minimumScale: 0.3, heightAtScale: heightAtScale)
            XCTAssertLessThanOrEqual(heightAtScale(scale), available, "available: \(available)")
        }
    }

    func testFitScaleFloorIsReturnedAsIsWhenNothingFits() {
        // Below the floor's own height, fitScale does not pretend to fit: it documents returning the floor
        // verbatim ("the caller must still show something, and the smallest allowed size is the least-bad
        // option"), not a smaller, artificially-fitting value.
        func heightAtScale(_ s: Double) -> Double { s > 0.4 ? 300 : 90 }
        XCTAssertEqual(SecutgGuideFit.fitScale(available: 50, minimumScale: 0.3, heightAtScale: heightAtScale), 0.3)
    }

    func testFitScaleNeverGoesBelowMinimum() {
        let scale = SecutgGuideFit.fitScale(available: 0, minimumScale: 0.55) { s in 1000 * s }
        XCTAssertGreaterThanOrEqual(scale, 0.55)
    }
}
