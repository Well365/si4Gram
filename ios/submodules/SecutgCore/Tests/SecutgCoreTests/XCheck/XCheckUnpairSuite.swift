import Foundation
@testable import SecutgCore

/// PLAN.md 3.31.3 — the `U1` unpair notice.
///
/// The only suite here with two axes. `U1` is an encoding, like `e1` and `pairing`: five clients have to sign
/// the same bytes and put the same characters on the wire. It is also a set of verdicts, like `race`: given a
/// notice and a pairing, does this client destroy its keys or refuse, and for which reason. The second axis is
/// the one that matters. A `U1` is the one message in the whole design whose effect is to DESTROY key
/// material, so a client that accepts one it should have refused has handed anybody a button that wipes
/// somebody else's chat history.
///
/// Both defects this suite was written after were exactly the kind a single client's own tests cannot see,
/// because each client was self-consistent and wrong in company:
///
///  - the `at` upper bound disagreed. Web rejects anything above `Number.MAX_SAFE_INTEGER` because it cannot
///    round-trip one; two ports parsed to int64 max. The same message was well formed on three clients and
///    malformed on two, and every unit suite stayed green. On this client the bound is `Rekey.parseU1`'s
///    `maxSafeAt`, which `\d{1,20}` and `Int64` would otherwise happily let through.
///  - the own-echo line read "the other side unpaired this chat" on the sender's own outgoing message, on
///    three clients at once — the echo arrives every single time anybody unpairs.
///
/// Three `kind`s of case, all in `inputs.json`:
///
///  - `format`: build the notice for a given `userId`/`at`/signer and compare the signed text and the wire,
///    byte for byte, against the hand-written expectation.
///  - `reject`: a string parsing must refuse. A client that accepts one has widened the format on its own and
///    will take notices the other four throw away.
///  - `verdict`: start from a completed pairing, hand the client one notice, and compare both the ruling and
///    what is left in the keyring. `hasMaster` is the assertion the feature exists for: an accepted notice
///    destroys the key, it does not merely unbind the chat from it.
///
/// Nothing reads a clock. `pairedAt` is given, every notice carries its own `at`, and the pairing each verdict
/// case starts from is rebuilt from the two identities `inputs.json` names — so no key material travels in the
/// vector and the same case gives the same answer on any machine at any time.
struct XCheckUnpairSuite: XCheckSuite {
    let name = "unpair"

    /// What this client concluded about one notice: the ruling, then what the keyring was left holding.
    private struct Verdict {
        let ok: Bool
        let reason: String
        let paired: Bool
        let hasMaster: Bool
        let encrypted: Bool

        var fields: [String: Any] {
            return ["ok": ok, "reason": reason, "paired": paired, "hasMaster": hasMaster, "encrypted": encrypted]
        }
    }

    // MARK: the fixture

    private struct Fixture {
        let chatId: String
        let ownUserId: String
        let pairedAt: Int64
        /// Role (`own` / `peer` / `stranger`) to the identity `inputs.json` names for it. No new key material:
        /// these are `alice` / `bob` / `carol`, which every other suite already draws on.
        let identities: [String: KeyRing.Identity]
        let cases: [[String: Any]]
    }

    private func fixture(_ env: XCheckEnv) throws -> Fixture {
        let unpair = try env.section("unpair")
        var identities = [String: KeyRing.Identity]()
        for (role, value) in try unpair.object("identities") {
            guard let named = value as? String else {
                throw XCheckError.message("unpair.identities.\(role) is not an identity name")
            }
            let record = try env.identity(named)
            identities[role] = KeyRing.Identity(
                x25519Pk: try env.bytes(record, "x25519PkHex"), x25519Sk: try env.bytes(record, "x25519SkHex"),
                ed25519Pk: try env.bytes(record, "ed25519PkHex"), ed25519Sk: try env.bytes(record, "ed25519SkHex"))
        }
        return Fixture(chatId: try unpair.string("chatId"), ownUserId: try unpair.string("ownUserId"),
                       pairedAt: try unpair.int64("pairedAt"), identities: identities,
                       cases: try unpair.objects("cases"))
    }

    private func identity(_ fixture: Fixture, _ role: String) throws -> KeyRing.Identity {
        guard let value = fixture.identities[role] else {
            throw XCheckError.message("no unpair identity for the role \(role)")
        }
        return value
    }

    /// `at` is a JSON number in one case and a JSON string in the other, and that is the point: the upper bound
    /// case sits exactly where JavaScript stops being able to write one, so `inputs.json` writes it as text
    /// rather than rely on five JSON parsers agreeing about it. Both spellings mean the same integer here.
    private func at(_ item: [String: Any]) throws -> Int64 {
        if let number = (item["at"] as? NSNumber)?.int64Value { return number }
        if let text = item["at"] as? String, let value = Int64(text) { return value }
        throw XCheckError.message("no usable at in \(item["id"] ?? "an unpair case")")
    }

    // MARK: running one case

    /// The state every `verdict` case starts from: this account and the peer completed a pairing, with
    /// `pairedAt` as the server date of the `P1` that completed it.
    ///
    /// Built by exchanging a real `P1` rather than by writing records into the ring, for the same reason the
    /// rest of this harness does: a client that derives the pairing master differently must not be able to
    /// agree with itself here and disagree on the wire.
    private func pairedRing(_ env: XCheckEnv, _ fixture: Fixture) throws -> KeyRing {
        let now = try env.nowMs()
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { now },
                           epochDays: try env.epochDays(), epochTolerance: try env.epochTolerance())
        try ring.setIdentity(try identity(fixture, "own"))
        let processor = RekeyProcessor(ring: ring, clock: { now })
        // (chatId, peerId). In a private chat the chat id IS the peer's user id, which is why both
        // arguments are the same value — the same call `race` makes.
        _ = try processor.startPairing(chatId: fixture.chatId, peerId: fixture.chatId)
        let peer = try identity(fixture, "peer")
        _ = processor.handle(text: try Rekey.buildP1(userId: fixture.chatId, x25519Pk: peer.x25519Pk,
                                                     ed25519Pk: peer.ed25519Pk, ed25519Sk: peer.ed25519Sk),
                             chatId: fixture.chatId, senderId: fixture.chatId, ownUserId: fixture.ownUserId,
                             messageDate: fixture.pairedAt)
        return ring
    }

    private func runVerdict(_ env: XCheckEnv, _ fixture: Fixture, _ item: [String: Any],
                            wire: String) throws -> Verdict {
        let ring = try pairedRing(env, fixture)
        let now = try env.nowMs()
        let result = RekeyProcessor(ring: ring, clock: { now }).handle(
            text: wire, chatId: try item.string("chatId"), senderId: try item.string("senderId"),
            ownUserId: fixture.ownUserId)
        // The case's `chatId` is the group only for the one case that is about groups; everything the keyring is
        // asked about afterwards is the private chat, which is where the keys that must survive a refusal live.
        return Verdict(ok: result?.ok ?? false, reason: result?.reason ?? "",
                       paired: ring.chatPairing(fixture.chatId) != nil,
                       hasMaster: ring.chatMasterId(fixture.chatId) != nil,
                       encrypted: ring.isChatEncrypted(fixture.chatId))
    }

    /// What this client produces for one case, whatever its kind.
    private func runCase(_ env: XCheckEnv, _ fixture: Fixture, _ item: [String: Any]) throws -> [String: Any] {
        switch try item.string("kind") {
        case "format":
            let signer = try identity(fixture, try item.string("signer"))
            let wire = try Rekey.buildU1(userId: try item.string("userId"), at: try at(item),
                                         ed25519Sk: signer.ed25519Sk)
            let parsed = Rekey.parseU1(wire)
            return ["wire": wire, "signedText": parsed?.signedText ?? "", "parsedBack": parsed != nil]
        case "reject":
            return ["parsed": Rekey.parseU1(try item.string("wire")) != nil]
        case "verdict":
            return ["verdict": try runVerdict(env, fixture, item, wire: try item.string("wire")).fields]
        case let kind:
            throw XCheckError.message("unknown unpair case kind \(kind)")
        }
    }

    // MARK: produce

    func produce(_ env: XCheckEnv) throws -> [[String: Any]] {
        let fixture = try self.fixture(env)
        return try fixture.cases.map { item in
            var one: [String: Any] = ["id": try item.string("id")]
            for (key, value) in try runCase(env, fixture, item) { one[key] = value }
            return one
        }
    }

    // MARK: consume

    /// The file as a whole: every case `inputs.json` defines has to be in it. A producer that quietly dropped
    /// the six `reject` cases would otherwise score full marks on the nine it kept.
    func consumeFile(_ env: XCheckEnv, producer: String, cases: [[String: Any]], results: XCheckResults) throws {
        let produced = Set(cases.compactMap { $0["id"] as? String })
        for item in try fixture(env).cases {
            let id = try item.string("id")
            guard !produced.contains(id) else { continue }
            results.error(producer: producer, suite: name, caseId: id,
                          detail: "\(producer) did not emit this case")
        }
    }

    func consume(_ env: XCheckEnv, producer: String, vectorCase: [String: Any], results: XCheckResults) throws {
        let fixture = try self.fixture(env)
        let id = try vectorCase.string("id")
        let check = results.begin(producer: producer, suite: name, caseId: id)
        guard let item = fixture.cases.first(where: { ($0["id"] as? String) == id }) else {
            check.isTrue("\(id) is not a case in inputs.json's unpair block", false)
            check.end()
            return
        }
        let kind = try item.string("kind")

        let mine: [String: Any]
        if kind == "verdict" {
            // A `verdict` case is replayed against the PRODUCER's own wire when it emitted one, so a client that
            // cannot verify another's signature never passes by re-deriving its own notice and agreeing with itself.
            let theirWire = try (vectorCase["wire"] as? String) ?? item.string("wire")
            mine = ["verdict": try runVerdict(env, fixture, item, wire: theirWire).fields]
        } else {
            mine = try runCase(env, fixture, item)
        }

        // `id` is the envelope's, not part of what the two clients are being compared on.
        var theirs = vectorCase
        theirs.removeValue(forKey: "id")

        if let problem = rejectProblem(kind, mine, "this client") { check.isTrue(problem, false) }
        if let problem = rejectProblem(kind, theirs, producer) { check.isTrue(problem, false) }

        // Where the two clients first diverge, which is the one line worth reading on a red row
        if let difference = firstDifference(mine: mine, theirs: theirs) {
            check.isTrue("this client and \(producer) differ at " + difference, false)
        }

        // Both sides against PLAN.md, never only against each other: five clients sharing one misreading would
        // otherwise agree in all twenty-five cells.
        try expectations(check, "mine", item, mine)
        try expectations(check, "\(producer)'s", item, theirs)
        check.end()
    }

    /// A `reject` case has one right answer and it is `false`. Stated separately from `inputs.json`'s
    /// expectations because it is the invariant, not one case's number: anything this suite calls malformed
    /// must be malformed, and a client that parses it has widened the wire format alone.
    private func rejectProblem(_ kind: String, _ emitted: [String: Any], _ whose: String) -> String? {
        guard kind == "reject", XCheckCanonical.canonical(emitted["parsed"]) == "true" else { return nil }
        return "\(whose) parsed a notice this suite calls malformed — the wire format has been widened on one "
            + "client alone"
    }

    /// Every case states its expectation the way the rest of this harness does: a list of JSON pointers into
    /// what the suite emits, each with the value PLAN.md says belongs there. That form is why `consume` can
    /// check the producer's output against the plan as well as against this client's.
    private func expectations(_ check: XCheckCase, _ label: String, _ item: [String: Any],
                              _ emitted: [String: Any]) throws {
        let tree = XCheckCanonical.normalize(emitted)
        for one in try item.objects("expect") {
            let path = try one.string("path")
            check.eq("\(label) \(path)", one["equals"], XCheckCanonical.get(tree, path),
                     unordered: one.flag("unordered"))
        }
    }

    // MARK: comparing two emissions

    /// The first path at which what this client produced and what the producer sent disagree. The emitted shape
    /// differs per `kind`, so unlike `race` there is no fixed field list to walk — the whole tree is compared.
    private func firstDifference(mine: Any?, theirs: Any?) -> String? {
        return difference(XCheckCanonical.normalize(mine), XCheckCanonical.normalize(theirs), "")
    }

    private func difference(_ mine: Any, _ theirs: Any, _ path: String) -> String? {
        let left = XCheckCanonical.render(mine)
        let right = XCheckCanonical.render(theirs)
        if left == right { return nil }
        if let a = mine as? [String: Any], let b = theirs as? [String: Any] {
            for key in Set(a.keys).union(b.keys).sorted() {
                guard let one = a[key] else { return "\(path)/\(key), which this client did not produce" }
                guard let other = b[key] else { return "\(path)/\(key), which the producer left out" }
                if let deeper = difference(one, other, "\(path)/\(key)") { return deeper }
            }
        }
        if let a = mine as? [Any], let b = theirs as? [Any] {
            if a.count != b.count { return "\(path): mine has \(a.count) entries, theirs \(b.count)" }
            for (index, one) in a.enumerated() {
                if let deeper = difference(one, b[index], "\(path)/\(index)") { return deeper }
            }
        }
        return "\(path.isEmpty ? "<root>" : path): mine \(clip(left)), theirs \(clip(right))"
    }

    private func clip(_ text: String) -> String {
        return text.count <= 160 ? text : String(text.prefix(160)) + "…"
    }
}
