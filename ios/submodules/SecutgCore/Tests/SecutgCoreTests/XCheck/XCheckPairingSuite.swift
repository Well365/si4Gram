import Foundation
@testable import SecutgCore

/// One-to-one auto pairing (PLAN.md 3.7): the derived master and the safety code, from both sides.
///
/// The existing `pairing.json` carries one safety code computed in one direction. That can never catch
/// the failure that matters, which is not a wrong digest but a wrong **ordering rule** — sorting the two
/// public keys by bytes versus by user id gives two different twelve-digit codes, both stable, both
/// self-consistent, and the two users read different numbers to each other and conclude they are being
/// attacked. So every case here is computed twice with the roles swapped, and both halves have to land
/// on the same string.
struct XCheckPairingSuite: XCheckSuite {
    let name = "pairing"

    func produce(_ env: XCheckEnv) throws -> [[String: Any]] {
        return try env.list("pairing").map { spec in
            let a = try env.identity(try spec.string("a"))
            let b = try env.identity(try spec.string("b"))
            let aPk = try env.bytes(a, "x25519PkHex")
            let aSk = try env.bytes(a, "x25519SkHex")
            let bPk = try env.bytes(b, "x25519PkHex")
            let bSk = try env.bytes(b, "x25519SkHex")
            let master = try Pairing.deriveMaster(ownX25519Sk: aSk, ownX25519Pk: aPk, peerX25519Pk: bPk)
            return [
                "id": try spec.string("id"),
                "a": try spec.string("a"),
                "b": try spec.string("b"),
                "masterHex": Hex.encode(master[...]),
                "masterFromBHex": Hex.encode(try Pairing.deriveMaster(ownX25519Sk: bSk, ownX25519Pk: bPk, peerX25519Pk: aPk)[...]),
                "masterId": try KeyDerivation.computeMasterId(master),
                "safetyCode": try Pairing.safetyCode(aPk, bPk),
                "safetyCodeSwapped": try Pairing.safetyCode(bPk, aPk),
            ]
        }
    }

    func consume(_ env: XCheckEnv, producer: String, vectorCase: [String: Any], results: XCheckResults) throws {
        let check = results.begin(producer: producer, suite: name, caseId: try vectorCase.string("id"))
        let a = try env.identity(try vectorCase.string("a"))
        let b = try env.identity(try vectorCase.string("b"))
        let aPk = try env.bytes(a, "x25519PkHex")
        let aSk = try env.bytes(a, "x25519SkHex")
        let bPk = try env.bytes(b, "x25519PkHex")
        let bSk = try env.bytes(b, "x25519SkHex")

        let forward = Hex.encode(try Pairing.deriveMaster(ownX25519Sk: aSk, ownX25519Pk: aPk, peerX25519Pk: bPk)[...])
        let reverse = Hex.encode(try Pairing.deriveMaster(ownX25519Sk: bSk, ownX25519Pk: bPk, peerX25519Pk: aPk)[...])
        check.eq("master derived from A's side", try vectorCase.string("masterHex"), forward)
        check.eq("master derived from B's side", try vectorCase.string("masterHex"), reverse)
        if let fromB = vectorCase["masterFromBHex"] as? String {
            check.eq("the two sides of the agreement", try vectorCase.string("masterHex"), fromB)
        }
        if let masterId = vectorCase["masterId"] as? String, let bytes = Hex.decode(forward) {
            check.eq("master_id of the paired master", masterId, try KeyDerivation.computeMasterId(bytes))
        }
        if let swapped = vectorCase["safetyCodeSwapped"] as? String {
            check.eq("safety code with the roles swapped", try vectorCase.string("safetyCode"), swapped)
        }

        let codeAB = try Pairing.safetyCode(aPk, bPk)
        let codeBA = try Pairing.safetyCode(bPk, aPk)
        check.eq("safety code as A reads it", try vectorCase.string("safetyCode"), codeAB)
        // The whole point: swapping the roles must not change a single digit.
        check.eq("safety code as B reads it", try vectorCase.string("safetyCode"), codeBA)
        check.isTrue("safety code is not 'dddd dddd dddd': \(codeAB)",
                     codeAB.range(of: "^\\d{4} \\d{4} \\d{4}$", options: .regularExpression) != nil)
        check.end()
    }
}
