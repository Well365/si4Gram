import Foundation
@testable import SecutgCore

/// Which of the two import dialogs a pasted text belongs to (PLAN.md 3.6 / 3.14).
///
/// This suite exists because of a real mistake a real user made: the offline "import key" dialog and the
/// K1 "import keyring" dialog have titles that read the same in zh-Hans — literally the same characters —
/// and pasting a `K1:` file into the offline one answers with a generic "not a valid payload" that points
/// nowhere.
///
/// Fixing the message is the easy half. The hard half is that five clients cannot agree on what to say
/// about a text until they agree on what the text **is**, and nothing until now made them agree. So
/// classification is a pure function, and these are its cross-client vectors: the same nine texts, the
/// same three answers, everywhere.
struct XCheckClassifySuite: XCheckSuite {
    let name = "classify"

    func produce(_ env: XCheckEnv) throws -> [[String: Any]] {
        return try env.list("classify").map { spec in
            let text = try spec.string("text")
            return ["id": try spec.string("id"), "text": text, "kind": ImportText.classify(text).rawValue]
        }
    }

    func consume(_ env: XCheckEnv, producer: String, vectorCase: [String: Any], results: XCheckResults) throws {
        let check = results.begin(producer: producer, suite: name, caseId: try vectorCase.string("id"))
        let text = try vectorCase.string("text")
        check.eq("classification", try vectorCase.string("kind"), ImportText.classify(text).rawValue)
        // The expectation in inputs.json is the signed-off answer; the producer's is only a report of
        // what one client thinks. Both have to agree with this client, or the case fails.
        for spec in try env.list("classify") where (spec["id"] as? String) == (vectorCase["id"] as? String) {
            check.eq("classification agreed in inputs.json", try spec.string("expect"),
                     ImportText.classify(try spec.string("text")).rawValue)
        }
        check.end()
    }
}
