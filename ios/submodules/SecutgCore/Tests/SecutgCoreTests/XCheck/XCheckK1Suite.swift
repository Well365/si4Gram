import Foundation
@testable import SecutgCore

/// Keyring transfer between the user's own devices (PLAN.md 3.14) — the part of the protocol that had no
/// cross-client vectors at all until now, and the part a user reaches for exactly when a device is lost.
///
/// Four groups of cases, each answering a question nothing else in the project asks:
///
/// - **Container.** Open another client's `K1:` with the shared code and get the same snapshot and the
///   same import manifest. The manifest is what the user is shown before saying yes, so a disagreement
///   there means the five clients ask the user different questions.
/// - **Scope exclusivity.** A single-chat export must carry that chat and *nothing else*. The assertion
///   is an exclusion — "no other chat's member keys, admin secret or pairing appears" — and nobody
///   writes an exclusion by accident, which is exactly why it has to be written down (PLAN.md 3.23).
/// - **Merge.** The rules live in PLAN prose and each client read them alone. The expected outcome is
///   hand-derived from that prose and lives in `inputs.json`: a consumer checks its own merge against
///   the producer's *and* against the hand-written expectation, so five clients agreeing on a shared
///   misreading still fails.
/// - **Negatives.** Six ways a container arrives broken. All six open to nothing; none of them throw.
///   A wrong transfer code and a flipped byte have to be equally boring.
struct XCheckK1Suite: XCheckSuite {
    let name = "k1"

    func produce(_ env: XCheckEnv) throws -> [[String: Any]] {
        var cases = [[String: Any]]()
        let k1 = try env.section("k1")
        let code = try k1.string("transferCode")
        let device = try k1.string("device")
        let createdAt = try k1.int64("createdAt")
        let now = try env.nowSeconds()

        guard let codeBytes = TransferCode.parse(code) else {
            throw XCheckError.message("inputs.k1.transferCode does not parse")
        }
        cases.append([
            "id": "k1.kdf.transferKey",
            "codeBytesHex": Hex.encode(codeBytes[...]),
            "transferKeyHex": Hex.encode(try TransferCode.deriveKey(codeBytes)[...]),
        ])

        let ring = try XCheckFixtures.ring(env, try XCheckFixtures.rich(env))
        let all = ring.exportSnapshot()
        var bundleAll: String?

        for spec in try k1.objects("scopes") {
            let isAll = try spec.string("scope") == TransferScope.all.rawValue
            let chatIds: [String]? = isAll ? nil : [try spec.string("chatKey")]
            let slice = isAll ? all
                : ring.exportChatsSnapshot(chatIds: chatIds ?? [], withIdentity: try spec.bool("withIdentity"))
            let payload = TransferPayload(scope: isAll ? .all : .chat, chatIds: chatIds,
                                          createdAt: createdAt, device: device, snapshot: slice)
            let bundle = try TransferBundle.build(payload, code: code)
            if isAll { bundleAll = bundle }

            var one: [String: Any] = [
                "id": try spec.string("id"),
                "code": "transferCode",
                "expect": "opens",
                "bundle": bundle,
                "snapshot": XCheckSnapshotWire.forVector(TransferSnapshotCodec.encode(slice)),
                "summary": XCheckK1Suite.summary(payload, now: now),
            ]
            if let chatKey = spec["chatKey"] as? String { one["chatKey"] = chatKey }
            if let withIdentity = (spec["withIdentity"] as? NSNumber)?.boolValue { one["withIdentity"] = withIdentity }
            if let foreign = spec["foreignChatKeys"] as? [String] { one["foreignChatKeys"] = foreign }
            cases.append(one)
        }
        guard let bundleAll = bundleAll else { throw XCheckError.message("inputs.k1.scopes has no 'all' scope") }

        for spec in try k1.objects("containerNegatives") {
            let how = try spec.string("mutate")
            cases.append([
                "id": try spec.string("id"),
                "bundle": XCheckK1Suite.mutate(bundleAll, how),
                "code": how == "wrongCode" ? "wrongCode" : "transferCode",
                "why": try spec.string("why"),
                "expect": "closed",
            ])
        }

        for spec in try k1.objects("codeCases") {
            let text = try spec.string("text")
            let parsed = TransferCode.parse(text)
            var one: [String: Any] = ["id": try spec.string("id"), "text": text, "valid": parsed != nil]
            if let parsed = parsed {
                one["codeBytesHex"] = Hex.encode(parsed[...])
                one["transferKeyHex"] = Hex.encode(try TransferCode.deriveKey(parsed)[...])
            }
            cases.append(one)
        }

        for spec in try k1.objects("staleCases") {
            let at = try spec.int64("createdAt")
            let payload = TransferPayload(scope: .all, chatIds: nil, createdAt: at, device: device, snapshot: all)
            cases.append([
                "id": try spec.string("id"),
                "createdAt": NSNumber(value: at),
                "bundle": try TransferBundle.build(payload, code: code),
                "isStale": TransferBundle.summarize(payload, nowSeconds: now).isStale,
            ])
        }

        for spec in try env.list("k1Merge") {
            let outcome = try XCheckK1Suite.mergeOutcome(env, spec)
            cases.append([
                "id": try spec.string("id"),
                "replaceIdentity": try spec.bool("replaceIdentity"),
                "after": outcome["snapshot"] as Any,
                "result": outcome["result"] as Any,
            ])
        }
        return cases
    }

    func consume(_ env: XCheckEnv, producer: String, vectorCase: [String: Any], results: XCheckResults) throws {
        let id = try vectorCase.string("id")
        let check = results.begin(producer: producer, suite: name, caseId: id)
        let k1 = try env.section("k1")

        if id.hasPrefix("k1.merge.") {
            let spec = try mergeSpec(env, id)
            let mine = try XCheckK1Suite.mergeOutcome(env, spec)
            check.eq("merged snapshot matches the producer", vectorCase["after"], mine["snapshot"])
            check.eq("merge result matches the producer", vectorCase["result"], mine["result"])
            let tree = XCheckCanonical.normalize(mine)
            for one in try spec.objects("expect") {
                // Hand-derived from PLAN.md, so five clients sharing one misreading still fails here.
                check.eq("PLAN rule at " + (try one.string("path")), one["equals"],
                         XCheckCanonical.get(tree, try one.string("path")),
                         unordered: one.flag("unordered"))
            }
            check.end()
            return
        }
        if id.hasPrefix("k1.code.") || id == "k1.kdf.transferKey" {
            try consumeCode(env, vectorCase: vectorCase, check: check)
            check.end()
            return
        }
        if (vectorCase["expect"] as? String) == "closed" {
            let opened = TransferBundle.open(try vectorCase.string("bundle"),
                                             code: try k1.string(try vectorCase.string("code")))
            check.isTrue("container opened when it must not (\((vectorCase["why"] as? String) ?? ""))", opened == nil)
            check.end()
            return
        }

        guard let payload = TransferBundle.open(try vectorCase.string("bundle"),
                                                code: try k1.string("transferCode")) else {
            check.isTrue("container does not open with the shared transfer code", false)
            check.end()
            return
        }
        if let snapshot = vectorCase["snapshot"] as? [String: Any] {
            check.eq("snapshot", snapshot, XCheckSnapshotWire.forVector(TransferSnapshotCodec.encode(payload.snapshot)))
            for key in (env.inputs["wireForbiddenKeys"] as? [String]) ?? [] {
                check.isFalse("local-only field \(key) travelled inside the container", snapshot[key] != nil)
            }
        }
        let mineSummary = XCheckK1Suite.summary(payload, now: try env.nowSeconds())
        if let summary = vectorCase["summary"] as? [String: Any] {
            check.eq("import manifest", summary, mineSummary)
            if let expected = try scopeExpectation(env, id) {
                // Hand-written in inputs.json: the manifest the user is shown before a key is written.
                // Five clients agreeing with each other but not with this would be five wrong questions.
                for key in ["scope", "masterCount", "chatCount", "hasIdentity", "isStale", "hasDeviceLabels",
                            "adminChatCount"] {
                    check.eq("manifest " + key, expected[key], mineSummary[key])
                }
                // Wrapped so the canonical "chatIds is a set" rule applies: the manifest lists the chats
                // in reading order, the summary in whatever order the ring iterates.
                check.eq("manifest chatIds", ["chatIds": expected["chatIds"] as Any],
                         ["chatIds": mineSummary["chatIds"] as Any])
            }
        }
        if let isStale = (vectorCase["isStale"] as? NSNumber)?.boolValue {
            check.eq("staleness at the seven-day line", isStale, mineSummary["isStale"])
        }
        if let withIdentity = (vectorCase["withIdentity"] as? NSNumber)?.boolValue {
            check.eq("identity carried", withIdentity, payload.snapshot.identityX25519Sk != nil)
        }
        if vectorCase["chatKey"] != nil { try checkExclusive(vectorCase, payload, check) }
        check.end()
    }

    /// The exclusion that keeps a single-chat transfer from telling the other device which other people
    /// and devices this one knows (PLAN.md 3.23). Every per-chat table is walked, not only the obvious one.
    private func checkExclusive(_ vectorCase: [String: Any], _ payload: TransferPayload, _ check: XCheckCase) throws {
        let wanted = try vectorCase.string("chatKey")
        let s = payload.snapshot
        let tables: [(String, [String])] = [
            ("chatMasters", Array(s.chatMasters.keys)),
            ("chatKeyLabels", Array(s.chatKeyLabels.keys)),
            ("chatEncryption", Array(s.chatEncryption.keys)),
            ("chatAdminPks", Array(s.chatAdminPks.keys)),
            ("chatAdminSks", Array(s.chatAdminSks.keys)),
            ("memberPks", Array(s.memberPks.keys)),
            ("memberEdPks", Array(s.memberEdPks.keys)),
            ("chatPairings", Array(s.chatPairings.keys)),
            ("chatRatchets", Array(s.chatRatchets.keys)),
            ("chatKeySources", Array(s.chatKeySources.keys)),
            ("chatKeyModes", Array(s.chatKeyModes.keys)),
            ("chatNoticeAts", Array(s.chatNoticeAts.keys)),
            ("groupOnlineInvites", Array(s.groupOnlineInvites.keys)),
        ]
        for (table, keys) in tables {
            for key in keys where key != wanted {
                check.isTrue("\(table) carries \(key), which is outside the exported chat", false)
            }
        }
        for other in (vectorCase["foreignChatKeys"] as? [String]) ?? [] {
            check.isFalse("member keys of \(other) leaked into a single-chat export", s.memberPks[other] != nil)
            check.isFalse("admin secret of \(other) leaked into a single-chat export", s.chatAdminSks[other] != nil)
            check.isFalse("pairing of \(other) leaked into a single-chat export", s.chatPairings[other] != nil)
        }
    }

    private func consumeCode(_ env: XCheckEnv, vectorCase: [String: Any], check: XCheckCase) throws {
        if try vectorCase.string("id") == "k1.kdf.transferKey" {
            guard let bytes = Hex.decode(try vectorCase.string("codeBytesHex")) else {
                check.isTrue("codeBytesHex is not hex", false)
                return
            }
            check.eq("transfer key derivation", try vectorCase.string("transferKeyHex"),
                     Hex.encode(try TransferCode.deriveKey(bytes)[...]))
            return
        }
        let parsed = TransferCode.parse(try vectorCase.string("text"))
        check.eq("code accepted", try vectorCase.bool("valid"), parsed != nil)
        guard let parsed = parsed else { return }
        if let expected = vectorCase["codeBytesHex"] as? String {
            check.eq("code bytes", expected, Hex.encode(parsed[...]))
        }
        if let expected = vectorCase["transferKeyHex"] as? String {
            check.eq("transfer key", expected, Hex.encode(try TransferCode.deriveKey(parsed)[...]))
        }
        // Every lenient spelling has to land on the one canonical code, not merely on some code.
        let canonical = TransferCode.parse(try env.section("k1").string("transferCode")) ?? []
        check.eq("lenient spelling resolves to the canonical code", Hex.encode(canonical[...]), Hex.encode(parsed[...]))
    }

    /// Exactly what the import dialog shows the user before a single key is written.
    static func summary(_ payload: TransferPayload, now: Int64) -> [String: Any] {
        let s = TransferBundle.summarize(payload, nowSeconds: now)
        return [
            "scope": s.scope.rawValue,
            "chatIds": s.chatIds.sorted(),
            "createdAt": NSNumber(value: s.createdAt),
            "device": s.device,
            "masterCount": s.masterCount,
            "chatCount": s.chatCount,
            "hasIdentity": s.hasIdentity,
            "isStale": s.isStale,
            // PLAN.md 3.25.4 rule 2: TransferBundle.Summary has carried this since 3.25 landed; this
            // hand-written dict just never picked it up, so it was invisible to every cross-client
            // manifest check even though the field itself was computed correctly.
            "hasDeviceLabels": s.hasDeviceLabels,
            // PLAN.md 3.30 item 8: how many groups' admin secrets the file hands over. A cross-client
            // difference here is a difference in what power the five clients admit to transferring, so
            // it belongs in the manifest the consumers compare, not only in each client's own UI.
            "adminChatCount": s.adminChatCount,
        ]
    }

    static func mergeOutcome(_ env: XCheckEnv, _ spec: [String: Any]) throws -> [String: Any] {
        let before = TransferSnapshotCodec.decode(XCheckSnapshotWire.forDecoder(try spec.object("before")))
        let incoming = TransferSnapshotCodec.decode(XCheckSnapshotWire.forDecoder(try spec.object("incoming")))
        let ring = try XCheckFixtures.ring(env, before)
        let merged = ring.mergeSnapshot(incoming, replaceIdentity: try spec.bool("replaceIdentity"))
        return [
            "snapshot": XCheckSnapshotWire.forVector(TransferSnapshotCodec.encode(ring.exportSnapshot())),
            "result": [
                "addedMasters": merged.addedMasters,
                "boundChats": merged.boundChats.sorted(),
                "skippedChats": merged.skippedChats.sorted(),
                "identityReplaced": merged.identityReplaced,
            ],
        ]
    }

    /// The hand-written manifest for a scope case, or nil for a case that has none.
    private func scopeExpectation(_ env: XCheckEnv, _ id: String) throws -> [String: Any]? {
        for spec in try env.section("k1").objects("scopes") where (spec["id"] as? String) == id {
            return try spec.object("summary")
        }
        return nil
    }

    private func mergeSpec(_ env: XCheckEnv, _ id: String) throws -> [String: Any] {
        for spec in try env.list("k1Merge") where (spec["id"] as? String) == id { return spec }
        throw XCheckError.message("no merge case named \(id) in inputs.json")
    }

    /// The six ways a container arrives broken, named by `inputs.k1.containerNegatives`.
    static func mutate(_ bundle: String, _ how: String) -> String {
        switch how {
        case "wrongCode": return bundle
        case "flipCiphertext": return XCheckE1Suite.flip(bundle, part: 3)
        case "flipNonce": return XCheckE1Suite.flip(bundle, part: 2)
        case "truncateCiphertext": return XCheckE1Suite.truncate(bundle)
        case "versionTwo": return bumpVersion(bundle)
        default: return "this is not a transfer file at all"
        }
    }

    /// `K1:2:…` — same key, same bytes, a version this client has never defined. Must not open.
    private static func bumpVersion(_ bundle: String) -> String {
        var parts = bundle.components(separatedBy: ":")
        guard parts.count == 4 else { return bundle }
        parts[1] = "2"
        return parts.joined(separator: ":")
    }
}
