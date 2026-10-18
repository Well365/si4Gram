import Foundation
@testable import SecutgCore

/// PLAN.md 3.7 rule 13 / 3.25.6 rules 2b and 7 — the one suite that checks a **state machine** rather than an
/// encoding (see `xcheck/README.md`, "The race suite").
///
/// The situation: the peer holds one invite open and two devices of *our* account answer it before either has
/// seen the other. The peer keeps whichever `P1` reached the chat first and calls the other a duplicate, and
/// never tells our devices which one it kept. So each of our devices has to reach that verdict alone, from the
/// messages alone, and reach the *same* one. If they disagree, both encrypt with different masters and the peer
/// can read only one of them. None of that is visible in `E1` / `P1` / `R1` / `G1`, which is why every other
/// suite here can be green and say nothing at all about it: no vector had ever run `RekeyProcessor`.
///
/// A vector is therefore **a list of events fed to the processor, and the pairing record it is left holding**.
/// Two verbs, and array order is delivery order, so any interleaving is expressible — which is the whole point,
/// because the parking rule's entire content is "the sibling's `P1` arrived before our own echo".
///
/// No clock is read anywhere in here. `messageDate` is the server date, the only clock two devices of one
/// account share and therefore the only one rule 13 may use; the local wall clock is read by exactly one rule
/// (3.25.6 rule 7, which predicts whether a takeover would be swallowed) and it too comes from the vector. The
/// same vector gives the same answer on any machine at any moment.
struct XCheckRaceSuite: XCheckSuite {
    let name = "race"

    /// What this client has ported of the optional behaviour `inputs.json`'s cases can ask for. A case whose
    /// `requires` names something missing here still runs and still counts — its failures are prefixed with the
    /// capability instead, so the row says why it is red without anyone having to remember. There is no skip in
    /// this harness: a skip is a green that is not one.
    static let capabilities: Set<String> = ["ownEchoParking"]

    /// The eleven fields of a terminal state, in the order a failure should read them. Named here rather than
    /// derived from whatever the producer happened to write, so a producer that omits one is a difference.
    static let stateFields = ["state", "holdsPairing", "ownDeviceId", "peerDeviceId", "startedAt", "pairedAt",
                              "verified", "encrypting", "masterId", "peerSeenDeviceIds", "trail"]

    // MARK: the fixture

    /// One of the three `P1` senders the cases draw on: two devices of our own account and the peer. No new key
    /// material — `alice` / `bob` / `carol` are the identities `inputs.json` already had, which is the only
    /// reason `device_id` ordering is a known quantity on all five clients and the tie-break case has a defined
    /// answer.
    private struct Sender {
        let key: String
        let identity: KeyRing.Identity
        let userId: String
        /// Spelled out in `inputs.json` so a client deriving it differently fails here, with the ordering named,
        /// instead of failing somewhere downstream with a state mismatch
        let deviceId: String
    }

    private struct Fixture {
        let chatId: String
        let ownUserId: String
        let senders: [String: Sender]
        let cases: [[String: Any]]
    }

    private func fixture(_ env: XCheckEnv) throws -> Fixture {
        let race = try env.section("race")
        var senders = [String: Sender]()
        for (key, value) in try race.object("senders") {
            guard let spec = value as? [String: Any] else {
                throw XCheckError.message("race.senders.\(key) is not an object")
            }
            let named = try env.identity(try spec.string("identity"))
            senders[key] = Sender(
                key: key,
                identity: KeyRing.Identity(
                    x25519Pk: try env.bytes(named, "x25519PkHex"), x25519Sk: try env.bytes(named, "x25519SkHex"),
                    ed25519Pk: try env.bytes(named, "ed25519PkHex"), ed25519Sk: try env.bytes(named, "ed25519SkHex")),
                userId: try spec.string("userId"), deviceId: try spec.string("deviceId"))
        }
        return Fixture(chatId: try race.string("chatId"), ownUserId: try race.string("ownUserId"),
                       senders: senders, cases: try race.objects("cases"))
    }

    private func sender(_ fixture: Fixture, _ key: String) throws -> Sender {
        guard let value = fixture.senders[key] else { throw XCheckError.message("no race sender named \(key)") }
        return value
    }

    /// Every sender a case touches: each device's own (the `P1` its `start` announces) and every one delivered.
    private func senderKeys(_ fixture: Fixture, _ spec: [String: Any]) throws -> [String] {
        var keys = Set<String>()
        for device in try spec.objects("devices") {
            keys.insert(try device.string("sender"))
            for event in try device.objects("events") where (event["do"] as? String) == "deliver" {
                keys.insert(try event.string("from"))
            }
        }
        return keys.sorted()
    }

    // MARK: running one device

    /// A wall clock the vector moves, never the machine's. Boxed because `KeyRing.Clock` is an escaping closure
    /// and the events have to be able to wind it forward between two of them.
    private final class VectorClock {
        var milliseconds: Int64
        init(seconds: Int64) { milliseconds = seconds * 1000 }
    }

    /// One device's independent run: its own keyring, identity and clock, the events in order, and the eleven
    /// fields it is left holding. `p1` hands back the wire text of a sender — the producer builds its own, the
    /// consumer is given the producer's.
    private func run(_ env: XCheckEnv, fixture: Fixture, device: [String: Any],
                     p1: (String) throws -> String) throws -> [String: Any] {
        let own = try sender(fixture, try device.string("sender"))
        let clock = VectorClock(seconds: try device.int64("clockSeconds"))
        let ring = KeyRing(storage: MemoryKeyRingStorage(), clock: { clock.milliseconds },
                           epochDays: try env.epochDays(), epochTolerance: try env.epochTolerance())
        try ring.setIdentity(own.identity)
        let processor = RekeyProcessor(ring: ring, clock: { clock.milliseconds })

        var trail = [String]()
        for event in try device.objects("events") {
            if let seconds = (event["clockSeconds"] as? NSNumber)?.int64Value { clock.milliseconds = seconds * 1000 }
            switch try event.string("do") {
            case "start":
                let confirmed = (event["confirmedTakeover"] as? NSNumber)?.boolValue ?? false
                let start = try processor.startPairing(chatId: fixture.chatId, peerId: fixture.chatId,
                                                       confirmedTakeover: confirmed)
                trail.append(XCheckRaceSuite.line(start))
            case "deliver":
                let from = try sender(fixture, try event.string("from"))
                let result = processor.handle(text: try p1(from.key), chatId: fixture.chatId,
                                              senderId: from.userId, ownUserId: fixture.ownUserId,
                                              messageDate: try event.int64("messageDate"))
                trail.append(XCheckRaceSuite.line(result))
            case let verb:
                throw XCheckError.message("unknown race event verb \(verb)")
            }
        }
        return terminal(ring, chatId: fixture.chatId, trail: trail)
    }

    /// What `startPairing` told the UI
    private static func line(_ start: RekeyProcessor.PairingStart) -> String {
        switch start {
        case .invited: return "invited"
        case .paired: return "paired"
        case .refused(let why): return why.rawValue
        }
    }

    /// What one delivery told the UI: its `PairingOutcome`, `!<reason>` when the `P1` was refused, or
    /// `!unhandled` when this client did not recognise it as a control message at all.
    private static func line(_ result: RekeyProcessor.Result?) -> String {
        guard let result = result else { return "!unhandled" }
        guard result.ok, let outcome = result.pairing else { return "!" + (result.reason ?? "unhandled") }
        return outcome.rawValue
    }

    /// The eleven fields, zero values written rather than omitted — the same "absent == zero value" ruling
    /// `XCheckCanonical` already makes for `chatPairings`. `state` is `none` when this device holds no pairing
    /// record at all, which is **not** `other_device` and must not compare equal to it.
    private func terminal(_ ring: KeyRing, chatId: String, trail: [String]) -> [String: Any] {
        let pairing = ring.chatPairing(chatId)
        return [
            "state": pairing?.state.rawValue ?? "none",
            "holdsPairing": pairing != nil && pairing?.state != .otherDevice,
            "ownDeviceId": pairing?.ownDeviceId ?? "",
            "peerDeviceId": pairing?.peerDeviceId ?? "",
            "startedAt": pairing?.startedAt ?? 0,
            "pairedAt": pairing?.pairedAt ?? 0,
            "verified": pairing?.verified ?? false,
            "encrypting": ring.isChatEncrypted(chatId),
            "masterId": ring.chatMasterId(chatId) ?? "",
            "peerSeenDeviceIds": pairing?.peerSeenDeviceIds ?? [],
            "trail": trail,
        ]
    }

    // MARK: produce

    func produce(_ env: XCheckEnv) throws -> [[String: Any]] {
        let fixture = try self.fixture(env)
        return try fixture.cases.map { spec in
            var texts = [String: String]()
            for key in try senderKeys(fixture, spec) {
                let from = try sender(fixture, key)
                texts[key] = try Rekey.buildP1(userId: from.userId, x25519Pk: from.identity.x25519Pk,
                                               ed25519Pk: from.identity.ed25519Pk, ed25519Sk: from.identity.ed25519Sk)
            }
            var final = [String: Any]()
            for device in try spec.objects("devices") {
                final[try device.string("role")] = try run(env, fixture: fixture, device: device) {
                    guard let text = texts[$0] else { throw XCheckError.message("no P1 built for \($0)") }
                    return text
                }
            }
            return ["id": try spec.string("id"), "p1": texts, "final": final]
        }
    }

    // MARK: consume

    /// The file as a whole: every case `inputs.json` defines has to be in it. A producer that quietly drops the
    /// two hardest cases would otherwise score full marks on the twelve it kept.
    func consumeFile(_ env: XCheckEnv, producer: String, cases: [[String: Any]], results: XCheckResults) throws {
        let produced = Set(cases.compactMap { $0["id"] as? String })
        for spec in try fixture(env).cases {
            let id = try spec.string("id")
            guard !produced.contains(id) else { continue }
            results.error(producer: producer, suite: name, caseId: id,
                          detail: prefix(spec) + "\(producer) produced no vector for this case")
        }
    }

    func consume(_ env: XCheckEnv, producer: String, vectorCase: [String: Any], results: XCheckResults) throws {
        let fixture = try self.fixture(env)
        let id = try vectorCase.string("id")
        let check = results.begin(producer: producer, suite: name, caseId: id)
        guard let spec = fixture.cases.first(where: { ($0["id"] as? String) == id }) else {
            check.isTrue("\(id) is not a case in inputs.json's race block", false)
            check.end()
            return
        }
        let mark = prefix(spec)

        // The `device_id`s are in the fixture so that a client deriving them differently says so here, with the
        // ordering named, rather than failing downstream with a state mismatch nobody can read.
        for key in try senderKeys(fixture, spec) {
            let from = try sender(fixture, key)
            let derived = (try? DeviceIdentity.derive(x25519Pk: from.identity.x25519Pk).deviceId) ?? ""
            check.eq(mark + "device_id of \(key)", from.deviceId, derived)
        }

        // The producer's own `P1` texts, never rebuilt here: a client that cannot parse another's `P1` would
        // otherwise quietly agree with itself and pass.
        let texts = (vectorCase["p1"] as? [String: String]) ?? [:]
        var mine = [String: Any]()
        for device in try spec.objects("devices") {
            mine[try device.string("role")] = try run(env, fixture: fixture, device: device) {
                guard let text = texts[$0] else { throw XCheckError.message("producer sent no P1 for \($0)") }
                return text
            }
        }
        let theirs = (vectorCase["final"] as? [String: Any]) ?? [:]

        // Where the two clients first diverge, which is the one line worth reading on a red row
        if let difference = firstDifference(mine: mine, theirs: theirs) {
            check.isTrue(mark + "terminal state differs at " + difference, false)
        }

        // The invariant the whole rule exists for, checked structurally: in a two-device case exactly one role
        // holds the pairing. Two is the fork rule 13 prevents; zero is the other half of the same failure, where
        // nobody encrypts while the peer believes it is paired.
        if mine.count > 1 {
            check.eq(mark + "exactly one of my devices holds the pairing", 1, holders(mine))
            check.eq(mark + "exactly one of \(producer)'s devices holds the pairing", 1, holders(theirs))
        }

        // Both sides against PLAN.md, never only against each other: five clients sharing one misreading would
        // otherwise agree in all twenty-five cells.
        try expectations(check, mark + "mine", spec, mine)
        try expectations(check, mark + "\(producer)'s", spec, theirs)
        check.end()
    }

    /// `[needs ownEchoParking] ` when this case leans on something this client has not ported, otherwise empty.
    private func prefix(_ spec: [String: Any]) -> String {
        let missing = ((spec["requires"] as? [String]) ?? []).filter { !XCheckRaceSuite.capabilities.contains($0) }
        return missing.isEmpty ? "" : "[needs \(missing.sorted().joined(separator: ", "))] "
    }

    private func holders(_ final: [String: Any]) -> Int {
        return final.values.filter {
            XCheckCanonical.canonical(($0 as? [String: Any])?["holdsPairing"]) == "true"
        }.count
    }

    /// The first field, in role then `stateFields` order, where two terminal states disagree.
    private func firstDifference(mine: [String: Any], theirs: [String: Any]) -> String? {
        for role in Set(mine.keys).union(theirs.keys).sorted() {
            guard let a = mine[role] as? [String: Any] else { return "/\(role) (I produced no such role)" }
            guard let b = theirs[role] as? [String: Any] else { return "/\(role) (missing from their vector)" }
            for field in XCheckRaceSuite.stateFields {
                let left = XCheckCanonical.canonical(a[field])
                let right = XCheckCanonical.canonical(b[field])
                if left != right { return "/\(role)/\(field): mine \(left), theirs \(right)" }
            }
        }
        return nil
    }

    /// `expect`'s JSON pointers over `{"<role>": <terminal state>}`, the same checker `k1` and `keyring` use.
    private func expectations(_ check: XCheckCase, _ label: String, _ spec: [String: Any], _ final: [String: Any]) throws {
        let tree = XCheckCanonical.normalize(final)
        for one in try spec.objects("expect") {
            let path = try one.string("path")
            check.eq("\(label) \(path)", one["equals"], XCheckCanonical.get(tree, path),
                     unordered: one.flag("unordered"))
        }
    }
}
