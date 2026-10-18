import Foundation

/// One verdict per (producer, suite, case), written to a file the runner reads.
///
/// A file rather than stdout on purpose: four native clients print four different things, and scraping
/// XCTest / JUnit / printf output is how a green run that ran nothing gets believed. A result row has to
/// be written for every case the runner knows about, and a missing row is a failure — never a silent
/// pass.
final class XCheckResults {
    private var rows = [[String: Any]]()
    private var failures = [String]()

    /// Starts a case; call `end()` on the returned check to record it.
    func begin(producer: String, suite: String, caseId: String) -> XCheckCase {
        return XCheckCase(results: self, producer: producer, suite: suite, caseId: caseId)
    }

    /// Records a case that could not even be attempted — always a failure, never a skip.
    func error(producer: String, suite: String, caseId: String, detail: String) {
        let check = begin(producer: producer, suite: suite, caseId: caseId)
        check.isTrue(detail, false)
        check.end()
    }

    fileprivate func record(producer: String, suite: String, caseId: String, problems: [String]) {
        rows.append([
            "producer": producer,
            "suite": suite,
            "case": caseId,
            "status": problems.isEmpty ? "pass" : "fail",
            "detail": problems.joined(separator: " | "),
        ])
        if !problems.isEmpty {
            failures.append("\(producer)/\(suite)/\(caseId): " + problems.joined(separator: " | "))
        }
    }

    var total: Int { return rows.count }
    var failed: Int { return failures.count }

    var summary: String {
        if failures.isEmpty { return "\(rows.count) cases, all pass" }
        return "\(failures.count) of \(rows.count) cases failed:\n  " + failures.joined(separator: "\n  ")
    }

    func write(to dir: URL, client: String, inputsId: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out: [String: Any] = [
            "format": XCheckEnv.format,
            "consumer": client,
            "inputsId": inputsId,
            "finishedAt": Int(Date().timeIntervalSince1970),
            "results": rows,
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: dir.appendingPathComponent(client + ".json"))
    }
}

/// The assertions of one case, collected so a case reports every problem rather than only the first.
final class XCheckCase {
    private let results: XCheckResults
    private let producer: String
    private let suite: String
    private let caseId: String
    private var problems = [String]()

    fileprivate init(results: XCheckResults, producer: String, suite: String, caseId: String) {
        self.results = results
        self.producer = producer
        self.suite = suite
        self.caseId = caseId
    }

    /// Canonical comparison: the only equality this project trusts across five JSON libraries.
    func eq(_ what: String, _ expected: Any?, _ actual: Any?, unordered: Bool = false) {
        let left = XCheckCanonical.canonical(expected, unordered: unordered)
        let right = XCheckCanonical.canonical(actual, unordered: unordered)
        if left != right { problems.append("\(what): expected \(clip(left)), got \(clip(right))") }
    }

    func isTrue(_ what: String, _ ok: Bool) {
        if !ok { problems.append(what) }
    }

    func isFalse(_ what: String, _ bad: Bool) {
        isTrue(what, !bad)
    }

    func end() {
        results.record(producer: producer, suite: suite, caseId: caseId, problems: problems)
    }

    private func clip(_ text: String) -> String {
        return text.count <= 400 ? text : String(text.prefix(400)) + "…(\(text.count) chars)"
    }
}
