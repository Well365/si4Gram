import XCTest
@testable import SecutgCore

/// Writes this client's answers to the shared inputs, for the other four to check.
///
/// Gated on `SECUTG_VECTOR_OUT` so a plain `swift test --package-path …/SecutgCore` runs exactly what it
/// ran before — this test then skips and nothing is written. The vectors are produced by calling the
/// same functions the app calls; a standalone dump tool would drift away from the shipped code paths,
/// quietly, and then certify the drift.
final class XCheckProducerTests: XCTestCase {
    func testWritesEverySuite() throws {
        guard let out = XCheckEnv.outRoot() else {
            throw XCTSkip("SECUTG_VECTOR_OUT is not set — cross-client production is off")
        }
        let env = try XCheckEnv.load(out)
        for suite in try XCheckSuites.selected() {
            try env.write(suite: suite.name, cases: try suite.produce(env))
        }
    }
}
