import Foundation
@testable import SecutgCore

/// The keyring snapshot as it travels between clients (PLAN.md 3.14).
///
/// The load-bearing idea is `fieldsCovered`, and it is worth spelling out why. Every one of the five
/// decoders is deliberately lenient — Web's `|| {}`, Android's `optJSONObject`, this client's `?? [:]`,
/// Windows's `if (get(...))` — because a keyring file is untrusted input and silently dropping a field
/// it does not understand is the right runtime behaviour. In a conformance test it is fatal: a client
/// that understands *nothing* decodes to an empty snapshot, re-encodes to an empty snapshot, and a
/// round-trip assertion alone would call that a pass.
///
/// So the consumer never settles for "my output equals the vector". It asserts that every table the
/// vector carries is a table it produced too, and it re-reads `inputs.maximalSnapshot` itself, so that
/// five clients dropping the *same* field still fails.
struct XCheckKeyringSuite: XCheckSuite {
    let name = "keyring"

    func produce(_ env: XCheckEnv) throws -> [[String: Any]] {
        var cases = [[String: Any]]()

        let maximal = XCheckSnapshotWire.forVector(TransferSnapshotCodec.encode(try XCheckFixtures.rich(env)))
        cases.append([
            "id": "keyring.snapshot.maximal",
            "fieldsCovered": maximal.keys.sorted(),
            "snapshot": maximal,
        ])

        for spec in try env.list("keyringLegacy") {
            let decoded = XCheckSnapshotWire.forVector(TransferSnapshotCodec.encode(
                TransferSnapshotCodec.decode(XCheckSnapshotWire.forDecoder(try spec.object("snapshot")))))
            cases.append([
                "id": try spec.string("id"),
                "legacy": true,
                "fieldsCovered": decoded.keys.sorted(),
                "snapshot": decoded,
            ])
        }
        return cases
    }

    func consume(_ env: XCheckEnv, producer: String, vectorCase: [String: Any], results: XCheckResults) throws {
        let id = try vectorCase.string("id")
        let check = results.begin(producer: producer, suite: name, caseId: id)

        let incoming = try vectorCase.object("snapshot")
        let mine = XCheckSnapshotWire.forVector(TransferSnapshotCodec.encode(
            TransferSnapshotCodec.decode(XCheckSnapshotWire.forDecoder(incoming))))
        check.eq("snapshot survives decode and re-encode", incoming, mine)

        // Anti-lenience: every leaf the vector carries must be a leaf this client produced as well.
        let mineTree = XCheckCanonical.normalize(mine)
        for path in XCheckCanonical.leafPaths(XCheckCanonical.normalize(incoming), "") {
            check.isTrue("field dropped by this client's decoder: \(path)", XCheckCanonical.has(mineTree, path))
        }
        for table in (vectorCase["fieldsCovered"] as? [String]) ?? [] {
            check.isTrue("table missing from this client's encoder: \(table)", mine[table] != nil)
        }

        if id == "keyring.snapshot.maximal" {
            // Anchored on inputs.json, not only on the producer: if every client dropped the same field,
            // the round trip above would still agree and only this line would notice.
            let fromInputs = XCheckSnapshotWire.forVector(TransferSnapshotCodec.encode(
                TransferSnapshotCodec.decode(XCheckSnapshotWire.forDecoder(try env.section("maximalSnapshot")))))
            check.eq("maximal snapshot as this client reads inputs.maximalSnapshot", incoming, fromInputs)
            for table in (env.inputs["maximalFieldsCovered"] as? [String]) ?? [] {
                check.isTrue("table missing from this client's encoder: \(table)", mine[table] != nil)
            }
        }

        // The wire is the wire: local preferences (PLAN.md 3.19 / 3.16) and the 3.0 quarantine never travel.
        for key in (env.inputs["wireForbiddenKeys"] as? [String]) ?? [] {
            check.isFalse("local-only field \(key) present in the vector", incoming[key] != nil)
            check.isFalse("local-only field \(key) written by this client", mine[key] != nil)
        }

        if (vectorCase["legacy"] as? NSNumber)?.boolValue == true {
            let spec = try legacySpec(env, id)
            let tree = XCheckCanonical.normalize(mine)
            for one in try spec.objects("expect") {
                check.eq("frozen " + (try one.string("path")), one["equals"],
                         XCheckCanonical.get(tree, try one.string("path")),
                         unordered: one.flag("unordered"))
            }
            for path in (spec["absent"] as? [String]) ?? [] {
                check.isFalse("frozen snapshot invented \(path)", XCheckCanonical.has(tree, path))
            }
        }
        check.end()
    }

    private func legacySpec(_ env: XCheckEnv, _ id: String) throws -> [String: Any] {
        for spec in try env.list("keyringLegacy") where (spec["id"] as? String) == id { return spec }
        throw XCheckError.message("no frozen snapshot named \(id) in inputs.json")
    }
}
