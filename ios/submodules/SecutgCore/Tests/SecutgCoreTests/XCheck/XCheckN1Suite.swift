import Foundation
@testable import SecutgCore

/// PLAN.md 3.34.3 / 3.34.4 / 3.34.5 — the `N1` group key retire notice.
///
/// Two axes, like `unpair`, and for the same reason: `N1` is an encoding five clients have to agree on byte for
/// byte, and it is a set of verdicts about whether to stop using a key. It is the more dangerous of the two to
/// get wrong in the other direction, though. `U1` destroys, so the failure to guard against is accepting one
/// too readily. `N1` UNBINDS and must **never** destroy (3.34.5), so this suite has to pin both halves: that an
/// accepted notice takes the key out of use, and that the master itself is still in the ring afterwards —
/// because a port that "cleaned up" by destroying it would pass every test about the first half while making
/// the group's history permanently unopenable on every device that keeps ciphertext locally (3.19), and an
/// `N1` can be replayed.
///
/// Three `kind`s of case, all in `inputs.json`:
///
///  - `format`: build the notice and compare the signed text and the wire, byte for byte. The `mode` and the
///    empty `old` of a group's first key are in here because both are new segments, and a port that gets the
///    field order or the empty-segment spelling wrong produces a message the other four read as a different
///    notice, or as none.
///  - `reject`: a string parsing must refuse — including a mode nobody recognises, which is the one a client is
///    most likely to wave through by treating an unknown value as a default.
///  - `verdict`: give a member's device one notice and compare both the ruling and what the keyring is left
///    holding. `after.masterHeld` is 3.34.5. `adminPkHex` is 3.34.4: a device that accepted the notice must now
///    trust the key it announced, and a device that refused must still trust the old one.
///
/// Two conventions in the vector are worth naming, because collapsing either turns a case into a different one:
/// a verdict case's `chatId` is the chat the notice is **read in** while `noticeChatId`, when present, is what
/// the notice itself **names** (that difference is the whole of `wrongChat`); and `isSenderGroupAdmin: null` is
/// the third state of rule 1 — "the admin list has not loaded" — which must reach the processor as an absent
/// value, not as `false`. Written as `null` rather than omitted, because an omitted field looks exactly like a
/// case that forgot to fill it in.
///
/// Nothing reads a clock. Every notice carries its own `at`, the member's starting state is rebuilt from
/// `inputs.json`, and the admin's `P1` is exchanged for real rather than written into the ring — so a client
/// that registers announcements differently cannot agree with itself and disagree here.
///
/// A `verdict` case with a `then` list plays a short SEQUENCE instead of one notice (PLAN.md 3.34.7 item 4):
/// the notice parks because the admin list has not loaded, a `R1 welcome` sealed to this member arrives and has
/// to park too, then the list arrives and both are judged. The verdict is the notice's on the retry, plus what
/// each message was told on arrival and whether the replacement master ended up bound. The welcome is sealed
/// with a fresh ephemeral key, so its wire is not the same twice: the producer emits it as `welcomeWire` and
/// the consumer replays the producer's rather than its own — which is also where one client's welcome meets
/// another's parking and retry.
struct XCheckN1Suite: XCheckSuite {
    let name = "n1"

    /// The ruling, then what the member's keyring was left holding.
    private struct Verdict {
        let ok: Bool
        let reason: String
        let mode: String
        let userId: String
        let masterBound: Bool
        /// 3.34.5: the master itself, which an accepted notice must NOT destroy
        let masterHeld: Bool
        let adminPkHex: String
        let encrypted: Bool
        /// 3.34.3 rule 3 (2026-09-19): the replay anchor afterwards — the `at` last obeyed, 0 for none
        let noticeAt: Int64

        var fields: [String: Any] {
            return ["ok": ok, "reason": reason, "mode": mode, "userId": userId, "masterBound": masterBound,
                    "masterHeld": masterHeld, "adminPkHex": adminPkHex, "encrypted": encrypted,
                    "noticeAt": NSNumber(value: noticeAt)]
        }
    }

    /// A `then` case (PLAN.md 3.34.7 item 4). The verdict carries four more fields than a plain one:
    ///
    ///  - `noticeOnArrival` / `welcomeOnArrival`: what each was told when it arrived. Both must be `pending` —
    ///    a welcome refused on arrival is the exact failure two phones showed on 2026-09-19.
    ///  - `replacementBound`: whether the master the welcome carried is what the chat is bound to now, which is
    ///    only true if the parked welcome was judged again, in full, once the notice applied.
    ///  - `parkedRekeys`: what is still parked afterwards. Zero either way — applied, or refused and not parked
    ///    a second time.
    private struct SequenceVerdict {
        let base: Verdict
        let noticeOnArrival: String
        let welcomeOnArrival: String
        let replacementBound: Bool
        let parkedRekeys: Int

        var fields: [String: Any] {
            var out = base.fields
            out["noticeOnArrival"] = noticeOnArrival
            out["welcomeOnArrival"] = welcomeOnArrival
            out["replacementBound"] = replacementBound
            out["parkedRekeys"] = parkedRekeys
            return out
        }
    }

    // MARK: the fixture

    private struct Fixture {
        let groupChatId: String
        let ownUserId: String
        let master: String
        /// Role (`own` / `admin` / `outsider`) to the identity `inputs.json` names for it. No new key material:
        /// these are `alice` / `carol` / `bob`, which every other suite already draws on.
        let identities: [String: KeyRing.Identity]
        /// `old` / `new` to the admin signing key pair `inputs.json` names for it
        let adminKeys: [String: (pk: [UInt8], sk: [UInt8])]
        let cases: [[String: Any]]
    }

    private func fixture(_ env: XCheckEnv) throws -> Fixture {
        let n1 = try env.section("n1")
        var identities = [String: KeyRing.Identity]()
        for (role, value) in try n1.object("identities") {
            guard let named = value as? String else {
                throw XCheckError.message("n1.identities.\(role) is not an identity name")
            }
            let record = try env.identity(named)
            identities[role] = KeyRing.Identity(
                x25519Pk: try env.bytes(record, "x25519PkHex"), x25519Sk: try env.bytes(record, "x25519SkHex"),
                ed25519Pk: try env.bytes(record, "ed25519PkHex"), ed25519Sk: try env.bytes(record, "ed25519SkHex"))
        }
        let admins = try env.section("admins")
        var adminKeys = [String: (pk: [UInt8], sk: [UInt8])]()
        for (which, value) in try n1.object("adminKeys") {
            guard let named = value as? String, let record = admins[named] as? [String: Any] else {
                throw XCheckError.message("n1.adminKeys.\(which) names no key in inputs.json's admins block")
            }
            adminKeys[which] = (try env.bytes(record, "pkHex"), try env.bytes(record, "skHex"))
        }
        return Fixture(groupChatId: try n1.string("groupChatId"), ownUserId: try n1.string("ownUserId"),
                       master: try n1.string("master"), identities: identities, adminKeys: adminKeys,
                       cases: try n1.objects("cases"))
    }

    private func identity(_ fixture: Fixture, _ role: String) throws -> KeyRing.Identity {
        guard let value = fixture.identities[role] else {
            throw XCheckError.message("no n1 identity for the role \(role)")
        }
        return value
    }

    private func adminKey(_ fixture: Fixture, _ which: String) throws -> (pk: [UInt8], sk: [UInt8]) {
        guard let value = fixture.adminKeys[which] else {
            throw XCheckError.message("no n1 admin key named \(which)")
        }
        return value
    }

    /// `at` is a JSON number in most cases and a JSON string in the upper-bound one, which sits exactly where
    /// JavaScript stops being able to write one — so `inputs.json` writes it as text rather than rely on five
    /// JSON parsers agreeing about it. Both spellings mean the same integer here.
    private func at(_ item: [String: Any]) throws -> Int64 {
        if let number = (item["at"] as? NSNumber)?.int64Value { return number }
        if let text = item["at"] as? String, let value = Int64(text) { return value }
        throw XCheckError.message("no usable at in \(item["id"] ?? "an n1 case")")
    }

    // MARK: building one notice

    private func buildFor(_ env: XCheckEnv, _ fixture: Fixture, _ item: [String: Any]) throws -> String {
        guard let mode = Rekey.KeyMode(rawValue: try item.string("mode")) else {
            throw XCheckError.message("n1 case \(item["id"] ?? "?") names an unknown mode")
        }
        // What the notice NAMES, which is not always the chat it is read in — that difference is the whole of
        // the `wrongChat` case, and collapsing the two would quietly turn it into a valid notice.
        let noticeChatId = try (item["noticeChatId"] as? String) ?? item.string("chatId")
        let old = try item.string("old")
        let signerName = try item.string("signer")
        // `newAdminKey` is not a person: it is the new admin key signing its own announcement, which is exactly
        // what 3.34.3 forbids and what rule 2 has to catch.
        let signingKey = signerName == "newAdminKey"
            ? try adminKey(fixture, "new").sk
            : try identity(fixture, signerName).ed25519Sk
        return try Rekey.buildN1(
            chatId: noticeChatId, userId: try item.string("userId"), at: try at(item), mode: mode,
            oldAdminPk: old.isEmpty ? nil : try adminKey(fixture, old).pk,
            newAdminPk: try adminKey(fixture, try item.string("new")).pk,
            ed25519Sk: signingKey)
    }

    // MARK: running one case

    /// What a member's device looks like the moment before a notice arrives: it holds the group's key, trusts
    /// the admin's current signing key, is switched on, and has the admin's `P1` on file.
    ///
    /// `hasKey: false` is the other starting state a real group has — the one before its FIRST key exists,
    /// which is what a notice naming no old key applies to.
    ///
    /// `trusts` names the signing key this device currently believes in: `old` for a member whose key is still
    /// in force, `new` for one that has already obeyed a notice announcing the replacement — i.e. exactly the
    /// state an accepted `N1` leaves behind, which is what `already_applied` is about.
    private func memberRing(_ env: XCheckEnv, _ fixture: Fixture, hasKey: Bool, trusts: String?,
                            anchorAt: Int64?) throws -> KeyRing {
        let now = try env.nowMs()
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { now },
                           epochDays: try env.epochDays(), epochTolerance: try env.epochTolerance())
        try ring.setIdentity(try identity(fixture, "own"))
        if hasKey {
            let masterId = try ring.addMaster(try env.masterKey(fixture.master))
            try ring.setChatMaster(chatId: fixture.groupChatId, masterId: masterId, label: nil)
            ring.setChatEncryption(chatId: fixture.groupChatId, enabled: true)
        }
        if hasKey || trusts != nil {
            try ring.setChatAdminPk(chatId: fixture.groupChatId, try adminKey(fixture, trusts ?? "old").pk)
        }
        // `anchorAt` is the `at` of the last notice this device obeyed (3.34.3 rule 3): what a replayed older
        // notice is measured against. Absent means nothing obeyed yet, and the first notice read applies.
        if let anchorAt = anchorAt { ring.setChatNoticeAt(chatId: fixture.groupChatId, anchorAt) }
        // How the admin's identity key gets on file in real life: their announcement arrived in the group.
        let admin = try identity(fixture, "admin")
        let adminUserId = try env.section("n1").string("adminUserId")
        _ = RekeyProcessor(ring: ring, clock: { now }).handle(
            text: try Rekey.buildP1(userId: adminUserId, x25519Pk: admin.x25519Pk, ed25519Pk: admin.ed25519Pk,
                                    ed25519Sk: admin.ed25519Sk),
            chatId: fixture.groupChatId, senderId: adminUserId, ownUserId: fixture.ownUserId)
        return ring
    }

    /// `inputs.json` spells the third state of 3.34.3 — "the admin list has not loaded" — as JSON `null`. It
    /// reaches the processor as an absent value, which is what that state is: not known yet, as opposed to
    /// known to be false. Written as a lookup because `NSNull` is not a `Bool`.
    private func adminFlag(_ item: [String: Any]) -> Bool? {
        return (item["isSenderGroupAdmin"] as? NSNumber)?.boolValue
    }

    /// The ruling, plus what the member's keyring was left holding. Split out so a sequence can build one from
    /// the last ruling of the run rather than re-playing the notice.
    private func verdict(_ env: XCheckEnv, _ fixture: Fixture, _ ring: KeyRing,
                         _ result: RekeyProcessor.Result?) throws -> Verdict {
        let pk = ring.chatAdminPk(fixture.groupChatId)
        // Everything the keyring is asked about afterwards is the GROUP, even in the private-chat case: that is
        // where the key which must survive a refusal lives.
        let masterId = try KeyDerivation.computeMasterId(try env.masterKey(fixture.master))
        return Verdict(ok: result?.ok ?? false, reason: result?.reason ?? "",
                       mode: result?.mode?.rawValue ?? "", userId: result?.userId ?? "",
                       masterBound: ring.chatMasterId(fixture.groupChatId) != nil,
                       masterHeld: ring.listMasterIds().contains(masterId),
                       adminPkHex: pk.map { Hex.encode($0[...]) } ?? "",
                       encrypted: ring.isChatEncrypted(fixture.groupChatId),
                       noticeAt: ring.chatNoticeAt(fixture.groupChatId) ?? 0)
    }

    private func runVerdict(_ env: XCheckEnv, _ fixture: Fixture, _ item: [String: Any],
                            wire: String) throws -> Verdict {
        let hasKey = (item["hasKey"] as? NSNumber)?.boolValue ?? true
        let ring = try memberRing(env, fixture, hasKey: hasKey, trusts: item["trusts"] as? String,
                                  anchorAt: (item["anchorAt"] as? NSNumber)?.int64Value)
        let now = try env.nowMs()
        let result = RekeyProcessor(ring: ring, clock: { now }).handle(
            text: wire, chatId: try item.string("chatId"), senderId: try item.string("senderId"),
            ownUserId: fixture.ownUserId, isSenderGroupAdmin: adminFlag(item))
        return try verdict(env, fixture, ring, result)
    }

    /// The `R1 welcome` a `then` step describes: the named master, sealed to `own`, signed by `new` / `old`
    /// (the group's signing keys) or by that identity's own key — which is how a forgery is spelled.
    ///
    /// The fixed clock from `inputs.json`, so the epoch label is acceptable on every client on every day it
    /// runs. The seal draws a fresh ephemeral key each time, so this wire is never the same twice.
    private func buildWelcome(_ env: XCheckEnv, _ fixture: Fixture, _ spec: [String: Any]) throws -> String {
        let signerName = try spec.string("signer")
        let signer = signerName == "new" || signerName == "old"
            ? try adminKey(fixture, signerName).sk
            : try identity(fixture, signerName).ed25519Sk
        return try Rekey.buildWelcome(currentMaster: try env.masterKey(try spec.string("master")),
                                      newcomerX25519Pk: try identity(fixture, "own").x25519Pk,
                                      adminSk: signer, nowMs: try env.nowMs(),
                                      epochDays: try env.epochDays()).wire
    }

    /// Plays the sequence. `theirWelcome` is the producer's wire on the consuming side; on the producing side
    /// it is absent and the welcome is built here. Either way the one actually replayed is returned, so the two
    /// sides compare the same bytes.
    ///
    /// Where Web retries a parked notice out of the processor, this client keeps the row's wire in the message
    /// store and re-runs the receive hook over it once the list arrives — so here "the admins loaded" is the
    /// same notice handed in again with the answer the case gives. The road is identical either way, which is
    /// the property the vector is pinning.
    private func runSequence(_ env: XCheckEnv, _ fixture: Fixture, _ item: [String: Any], noticeWire: String,
                             theirWelcome: String?) throws -> (welcomeWire: String, verdict: SequenceVerdict) {
        let hasKey = (item["hasKey"] as? NSNumber)?.boolValue ?? true
        let ring = try memberRing(env, fixture, hasKey: hasKey, trusts: item["trusts"] as? String,
                                  anchorAt: (item["anchorAt"] as? NSNumber)?.int64Value)
        let now = try env.nowMs()
        let processor = RekeyProcessor(ring: ring, clock: { now })
        let chatId = try item.string("chatId")
        let senderId = try item.string("senderId")

        let onArrival = processor.handle(text: noticeWire, chatId: chatId, senderId: senderId,
                                         ownUserId: fixture.ownUserId, isSenderGroupAdmin: adminFlag(item))
        var ruling = onArrival
        var welcomeWire = theirWelcome
        var welcomeOnArrival = ""
        var replacement: String?
        for step in try item.objects("then") {
            if let spec = step["welcome"] as? [String: Any] {
                replacement = try spec.string("master")
                let wire: String
                if let existing = welcomeWire { wire = existing } else { wire = try buildWelcome(env, fixture, spec) }
                welcomeWire = wire
                welcomeOnArrival = processor.handle(text: wire, chatId: chatId, senderId: senderId,
                                                    ownUserId: fixture.ownUserId)?.reason ?? ""
            }
            if let loaded = (step["adminsLoaded"] as? NSNumber)?.boolValue {
                ruling = processor.handle(text: noticeWire, chatId: chatId, senderId: senderId,
                                          ownUserId: fixture.ownUserId, isSenderGroupAdmin: loaded) ?? ruling
            }
        }
        guard let played = welcomeWire else { throw XCheckError.message("a `then` case needs a welcome step") }
        let bound = ring.chatMasterId(fixture.groupChatId)
        let replacementBound = try replacement.map {
            bound == (try KeyDerivation.computeMasterId(try env.masterKey($0)))
        } ?? false
        return (played, SequenceVerdict(
            base: try verdict(env, fixture, ring, ruling),
            noticeOnArrival: onArrival?.reason ?? "", welcomeOnArrival: welcomeOnArrival,
            replacementBound: replacementBound,
            parkedRekeys: processor.parkedRekeyCount(chatId: fixture.groupChatId)))
    }

    /// What this client produces for one case, whatever its kind.
    private func runCase(_ env: XCheckEnv, _ fixture: Fixture, _ item: [String: Any]) throws -> [String: Any] {
        switch try item.string("kind") {
        case "format":
            let wire = try buildFor(env, fixture, item)
            let parsed = Rekey.parseN1(wire)
            return ["wire": wire, "signedText": parsed?.signedText ?? "", "parsedBack": parsed != nil]
        case "reject":
            return ["parsed": Rekey.parseN1(try item.string("wire")) != nil]
        case "verdict":
            // A verdict case names the notice by how to build it, so the bytes are this client's own — and
            // `consume` then replays the PRODUCER's, which is where cross-client signature checking happens.
            let wire = try buildFor(env, fixture, item)
            if item["then"] != nil {
                let played = try runSequence(env, fixture, item, noticeWire: wire, theirWelcome: nil)
                return ["wire": wire, "welcomeWire": played.welcomeWire, "verdict": played.verdict.fields]
            }
            return ["wire": wire, "verdict": try runVerdict(env, fixture, item, wire: wire).fields]
        case let kind:
            throw XCheckError.message("unknown n1 case kind \(kind)")
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
    /// the ten `reject` cases would otherwise score full marks on the nineteen it kept.
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
            check.isTrue("\(id) is not a case in inputs.json's n1 block", false)
            check.end()
            return
        }
        let kind = try item.string("kind")

        let mine: [String: Any]
        if kind == "verdict" {
            // Replayed against the PRODUCER's own wire, so a client that cannot verify another client's
            // signature never passes by re-deriving its own notice and agreeing with itself.
            let theirWire = try (vectorCase["wire"] as? String) ?? buildFor(env, fixture, item)
            if item["then"] != nil {
                // A sequence replays the producer's welcome too. If they emitted none, this side builds its own
                // and the comparison names the field they left out — never a pass by falling back quietly.
                let played = try runSequence(env, fixture, item, noticeWire: theirWire,
                                             theirWelcome: vectorCase["welcomeWire"] as? String)
                mine = ["wire": try buildFor(env, fixture, item), "welcomeWire": played.welcomeWire,
                        "verdict": played.verdict.fields]
            } else {
                mine = ["wire": try buildFor(env, fixture, item),
                        "verdict": try runVerdict(env, fixture, item, wire: theirWire).fields]
            }
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
    /// must be malformed, and a client that parses it has widened the wire format on its own.
    private func rejectProblem(_ kind: String, _ emitted: [String: Any], _ whose: String) -> String? {
        guard kind == "reject", XCheckCanonical.canonical(emitted["parsed"]) == "true" else { return nil }
        return "\(whose) parsed a notice this suite calls malformed — the wire format has been widened on one "
            + "client alone"
    }

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
    /// differs per `kind`, so the whole tree is compared rather than a fixed field list.
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
