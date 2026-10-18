import XCTest
@testable import SecutgCore

/// Checks every other client's vectors — and this client's own, which is the baseline that says whether
/// a red row is the producer's fault or the consumer's.
///
/// Gated on `SECUTG_VECTOR_IN`, so an ordinary test run is untouched. Two rules are deliberate and both
/// exist because a cross-client harness fails silently by default:
///
/// - A vector whose `inputsId` differs from this run's `inputs.json` is **refused**, not tolerated.
///   Otherwise a stale vector from last week passes against today's inputs.
/// - A missing vector file is a recorded failure, never an absence. "Nothing to check" must never look
///   like "everything checked out".
final class XCheckConsumerTests: XCTestCase {
    func testChecksEveryClientsVectors() throws {
        guard let input = XCheckEnv.inRoot() else {
            throw XCTSkip("SECUTG_VECTOR_IN is not set — cross-client consumption is off")
        }
        let env = try XCheckEnv.load(input)
        let results = XCheckResults()
        let suites = try XCheckSuites.selected()

        for producer in try producers(input) {
            // A suite this client cannot check must be a red row, not silence. The loop below only ever looks
            // for files whose names it already knows, so a producer that emits a suite this client has never
            // heard of would otherwise contribute nothing at all to the matrix — and a gap that prints nothing
            // reads exactly like a gap that is not there.
            for name in unknownSuites(input, producer: producer) {
                results.error(producer: producer, suite: name, caseId: name + ".unknownSuite",
                              detail: "\(producer) produced a \(name) suite this client does not implement")
            }
            for suite in suites {
                let file = input.appendingPathComponent(producer).appendingPathComponent(suite.name + ".json")
                guard FileManager.default.fileExists(atPath: file.path) else {
                    results.error(producer: producer, suite: suite.name, caseId: suite.name + ".fileMissing",
                                  detail: "no vector file at \(file.path)")
                    continue
                }
                let envelope = try XCheckEnv.read(file)
                guard (envelope["format"] as? NSNumber)?.intValue == XCheckEnv.format else {
                    results.error(producer: producer, suite: suite.name, caseId: suite.name + ".format",
                                  detail: "envelope format \(envelope["format"] ?? "nil"), this client speaks \(XCheckEnv.format)")
                    continue
                }
                guard envelope["suite"] as? String == suite.name else {
                    results.error(producer: producer, suite: suite.name, caseId: suite.name + ".suite",
                                  detail: "file says suite \(envelope["suite"] ?? "nil")")
                    continue
                }
                guard envelope["inputsId"] as? String == env.inputsId else {
                    results.error(producer: producer, suite: suite.name, caseId: suite.name + ".inputsId",
                                  detail: "vector was generated against \(envelope["inputsId"] ?? "nil"), "
                                        + "this run reads \(env.inputsId)")
                    continue
                }
                let cases = (envelope["cases"] as? [[String: Any]]) ?? []
                guard !cases.isEmpty else {
                    results.error(producer: producer, suite: suite.name, caseId: suite.name + ".empty",
                                  detail: "no cases in \(file.path)")
                    continue
                }
                do {
                    try suite.consumeFile(env, producer: producer, cases: cases, results: results)
                } catch {
                    results.error(producer: producer, suite: suite.name, caseId: suite.name + ".file",
                                  detail: "threw \(error)")
                }
                for (index, vectorCase) in cases.enumerated() {
                    let id = (vectorCase["id"] as? String) ?? "case[\(index)]"
                    do {
                        try suite.consume(env, producer: producer, vectorCase: vectorCase, results: results)
                    } catch {
                        results.error(producer: producer, suite: suite.name, caseId: id, detail: "threw \(error)")
                    }
                }
            }
        }

        // Written before the assertion so the runner's table is complete even on a red run.
        try results.write(to: XCheckEnv.resultsDir(input), client: XCheckEnv.client, inputsId: env.inputsId)
        XCTAssertEqual(results.failed, 0, results.summary)
    }

    /// Suite files in a producer's directory that this client has no suite for at all. A suite left out of a
    /// `SECUTG_VECTOR_SUITE` run is not one of them: this client has it, the run simply did not ask for it.
    private func unknownSuites(_ input: URL, producer: String) -> [String] {
        let dir = input.appendingPathComponent(producer)
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let implemented = Set(XCheckSuites.all.map { $0.name })
        return entries.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !implemented.contains($0) }
            .sorted()
    }

    private func producers(_ input: URL) throws -> [String] {
        let entries = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: [.isDirectoryKey])
        var out = [String]()
        for entry in entries {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let name = entry.lastPathComponent
            if name.hasPrefix("_") || name.hasPrefix(".") || name == "results" { continue }
            out.append(name)
        }
        if out.isEmpty { throw XCheckError.message("no producer directories under \(input.path)") }
        return out.sorted()
    }
}
