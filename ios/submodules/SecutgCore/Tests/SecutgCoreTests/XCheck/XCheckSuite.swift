import Foundation

/// One cross-client suite, in both directions.
///
/// `produce` writes what this client's real code paths actually do with the shared inputs; `consume`
/// takes another client's answer and checks it against this client's own. Both live in the same type on
/// purpose — a suite whose producer and consumer drift apart is a suite that proves nothing, and keeping
/// them side by side makes that drift visible in review.
protocol XCheckSuite {
    var name: String { get }
    func produce(_ env: XCheckEnv) throws -> [[String: Any]]
    func consume(_ env: XCheckEnv, producer: String, vectorCase: [String: Any], results: XCheckResults) throws

    /// The producer's file as a whole, before its cases are read one by one. Only a suite whose case list comes
    /// from `inputs.json` can say anything here — it is where "the producer left this case out" becomes a red
    /// row instead of an absence. The default checks nothing, which is right for every suite that derives its
    /// cases from the vector itself.
    func consumeFile(_ env: XCheckEnv, producer: String, cases: [[String: Any]], results: XCheckResults) throws
}

extension XCheckSuite {
    func consumeFile(_ env: XCheckEnv, producer: String, cases: [[String: Any]], results: XCheckResults) throws {}
}

enum XCheckSuites {
    static let all: [XCheckSuite] = [
        XCheckIdsSuite(), XCheckE1Suite(), XCheckPairingSuite(), XCheckKeyringSuite(), XCheckK1Suite(),
        XCheckClassifySuite(), XCheckRaceSuite(), XCheckUnpairSuite(), XCheckN1Suite(),
    ]

    /// The suites this run should touch: all of them, or the subset `SECUTG_VECTOR_SUITE` names (the runner's
    /// `--suite`). A name this client does not implement throws rather than narrowing the run to nothing: a
    /// filtered run that checked nothing must never be indistinguishable from a filtered run that passed.
    static func selected() throws -> [XCheckSuite] {
        guard let names = XCheckEnv.selectedSuites() else { return all }
        let known = Set(all.map { $0.name })
        let unknown = names.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw XCheckError.message(
                "SECUTG_VECTOR_SUITE names \(unknown.joined(separator: ", ")), which this client does not "
                + "implement; it has \(all.map { $0.name }.sorted().joined(separator: ", "))")
        }
        return all.filter { names.contains($0.name) }
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) throws -> String {
        guard let value = self[key] as? String else { throw XCheckError.message("no string at \(key)") }
        return value
    }

    func int64(_ key: String) throws -> Int64 {
        guard let value = (self[key] as? NSNumber)?.int64Value else { throw XCheckError.message("no number at \(key)") }
        return value
    }

    func int(_ key: String) throws -> Int {
        guard let value = (self[key] as? NSNumber)?.intValue else { throw XCheckError.message("no number at \(key)") }
        return value
    }

    func bool(_ key: String) throws -> Bool {
        guard let value = (self[key] as? NSNumber)?.boolValue else { throw XCheckError.message("no bool at \(key)") }
        return value
    }

    func object(_ key: String) throws -> [String: Any] {
        guard let value = self[key] as? [String: Any] else { throw XCheckError.message("no object at \(key)") }
        return value
    }

    func objects(_ key: String) throws -> [[String: Any]] {
        guard let value = self[key] as? [[String: Any]] else { throw XCheckError.message("no array at \(key)") }
        return value
    }

    /// An optional boolean, false when absent — `"unordered": true` on an expectation item.
    func flag(_ key: String) -> Bool {
        return (self[key] as? NSNumber)?.boolValue == true
    }

    func strings(_ key: String) throws -> [String] {
        guard let value = self[key] as? [String] else { throw XCheckError.message("no string array at \(key)") }
        return value
    }
}
