import Foundation
@testable import SecutgCore

/// Message encryption and decryption across clients (PLAN.md 3.2).
///
/// Three things here are not obvious and are the reason the suite exists:
///
/// - **The tampering set is four, not one.** Only a flipped ciphertext byte was covered anywhere before.
///   A flipped nonce, a truncated ciphertext and a wrong-but-valid session key all have to come back as
///   "cannot decrypt" *without throwing* — a client that throws on hostile input has a crash, not a
///   failure.
/// - **The foreign key_id case proves the AAD is bound.** The wire's key_id is swapped for another
///   key_id the consumer *also* holds a real session key for. If key_id were only a lookup hint and not
///   authenticated data, that decrypt would succeed — silently, across sessions.
/// - **The entity offsets are UTF-16 units.** The canary case puts a Bold entity immediately after an
///   astral emoji: a client counting code points formats the wrong characters and never errors.
struct XCheckE1Suite: XCheckSuite {
    let name = "e1"

    func produce(_ env: XCheckEnv) throws -> [[String: Any]] {
        var cases = [[String: Any]]()
        let e1 = try env.section("e1")
        let label = try env.label("current")
        let master = try env.masterKey("alpha")
        let masterId = try KeyDerivation.computeMasterId(master)
        let keyId = KeyDerivation.buildKeyId(masterId: masterId, label: label)
        let sessionKey = try KeyDerivation.deriveSessionKey(masterKey: master, label: label)

        var tamperSource = ""
        for spec in try e1.objects("texts") {
            let text = try spec.string("text")
            let rawEntities = spec["entities"] as? [[String: Any]]
            let entities = try rawEntities?.map { try XCheckE1Suite.entity($0) }
            let wire = try E1Codec.encrypt(text: text, entities: entities, keyId: keyId, sessionKey: sessionKey)
            if try spec.string("name") == "ascii" { tamperSource = wire }

            var one: [String: Any] = [
                "id": "e1.text." + (try spec.string("name")),
                "keyId": keyId,
                "text": text,
                "textUtf8Hex": Hex.encode(Array(text.utf8)[...]),
                "wire": wire,
                "expect": "plaintext",
            ]
            if let rawEntities = rawEntities { one["entities"] = rawEntities }
            cases.append(one)
        }

        for which in ["previous", "current", "next", "beyondTolerance"] {
            let value = try env.label(which)
            let key = try KeyDerivation.deriveSessionKey(masterKey: master, label: value)
            let labelKeyId = KeyDerivation.buildKeyId(masterId: masterId, label: value)
            let text = "epoch " + value
            // Decryption never consults the calendar; the keyring's lookup does, and that is the one
            // place five date libraries in five time zones get to disagree in public. A label past the
            // tolerance resolves to no key at all, so the wire is undecryptable even though it is intact.
            let acceptable = KeyDerivation.isLabelAcceptable(value, nowMs: try env.nowMs(),
                                                             epochTolerance: try env.epochTolerance())
            var one: [String: Any] = [
                "id": "e1.label." + which,
                "label": value,
                "keyId": labelKeyId,
                "text": text,
                "wire": try E1Codec.encrypt(text: text, entities: nil, keyId: labelKeyId, sessionKey: key),
                "acceptable": acceptable,
                "expect": acceptable ? "plaintext" : "undecryptable",
            ]
            if !acceptable { one["why"] = "an epoch label past the tolerance resolves to no key" }
            cases.append(one)
        }

        let limit = try e1.object("limit")
        let fill = try limit.string("fillChar")
        let atMaxText = String(repeating: fill, count: try limit.int("atMaxLength"))
        cases.append([
            "id": "e1.limit.atMax",
            "keyId": keyId,
            "text": atMaxText,
            "wire": try E1Codec.encrypt(text: atMaxText, entities: nil, keyId: keyId, sessionKey: sessionKey),
            "expect": "plaintext",
        ])
        let overLength = try limit.int("overMaxLength")
        cases.append([
            "id": "e1.limit.overMax",
            "textLength": overLength,
            "senderRefused": XCheckE1Suite.refuses(String(repeating: fill, count: overLength),
                                                   keyId: keyId, sessionKey: sessionKey),
            "expect": "refusedBySender",
        ])

        let foreignKeyId = KeyDerivation.buildKeyId(
            masterId: try KeyDerivation.computeMasterId(try env.masterKey("beta")), label: label)
        cases.append(tamper("e1.tamper.flippedCiphertext", XCheckE1Suite.flip(tamperSource, part: 3),
                            "one ciphertext byte flipped"))
        cases.append(tamper("e1.tamper.flippedNonce", XCheckE1Suite.flip(tamperSource, part: 2),
                            "one nonce byte flipped"))
        cases.append(tamper("e1.tamper.truncatedCiphertext", XCheckE1Suite.truncate(tamperSource),
                            "the ciphertext cut short"))
        cases.append(tamper("e1.tamper.foreignKeyId", XCheckE1Suite.swapKeyId(tamperSource, keyId: foreignKeyId),
                            "key_id swapped for another key the consumer also holds"))
        return cases
    }

    func consume(_ env: XCheckEnv, producer: String, vectorCase: [String: Any], results: XCheckResults) throws {
        let check = results.begin(producer: producer, suite: name, caseId: try vectorCase.string("id"))
        let expect = (vectorCase["expect"] as? String) ?? "plaintext"
        // The app's own lookup, not a hand-rolled derivation: it is the lookup that applies the epoch
        // tolerance, so `e1.label.beyondTolerance` is refused here for the reason it is refused in the
        // app — an unacceptable label, not a bad key. A test that derived the key itself would decrypt
        // it happily and certify a rule the app does not actually follow.
        let ring = try XCheckFixtures.ring(env, try XCheckE1Suite.everyMaster(env))
        let lookup: E1Codec.KeyLookup = { ring.lookupSessionKey($0) }

        if expect == "refusedBySender" {
            let limit = try env.section("e1").object("limit")
            let master = try env.masterKey("alpha")
            let label = try env.label("current")
            let keyId = KeyDerivation.buildKeyId(masterId: try KeyDerivation.computeMasterId(master), label: label)
            let sessionKey = try KeyDerivation.deriveSessionKey(masterKey: master, label: label)
            let text = String(repeating: try limit.string("fillChar"), count: try vectorCase.int("textLength"))
            check.eq("sender refuses past the wire limit", try vectorCase.bool("senderRefused"),
                     XCheckE1Suite.refuses(text, keyId: keyId, sessionKey: sessionKey))
            check.eq("wire limit constant", try env.section("limits").int("e1WireMaxChars"), E1Format.wireMaxChars)
            check.end()
            return
        }

        if expect == "undecryptable" {
            rejects(check, (vectorCase["why"] as? String) ?? "tampered wire", try vectorCase.string("wire"), lookup)
            check.end()
            return
        }

        let keyId = try vectorCase.string("keyId")
        check.isTrue("no master in inputs.json resolves key_id \(keyId)", ring.lookupSessionKey(keyId) != nil)

        let decrypted = E1Codec.decrypt(wire: try vectorCase.string("wire"), lookup: lookup)
        check.isTrue("wire does not decrypt: \(decrypted.reason?.rawValue ?? "?")", decrypted.ok)
        if decrypted.ok {
            check.eq("plaintext", try vectorCase.string("text"), decrypted.text)
            check.eq("entities", vectorCase["entities"], decrypted.entities.map { $0.map(E1Codec.entityToJSON) })
            if let expectedHex = vectorCase["textUtf8Hex"] as? String, let text = decrypted.text {
                // UTF-8 bytes, not the string: two clients can agree on a String and still have
                // normalised it differently on the way in.
                check.eq("plaintext bytes", expectedHex, Hex.encode(Array(text.utf8)[...]))
            }
        }
        if let acceptable = (vectorCase["acceptable"] as? NSNumber)?.boolValue {
            check.eq("label acceptability", acceptable,
                     KeyDerivation.isLabelAcceptable(try vectorCase.string("label"), nowMs: try env.nowMs(),
                                                     epochTolerance: try env.epochTolerance()))
        }
        // A valid but wrong session key has to fail the same quiet way a tampered wire does.
        let wrong = try KeyDerivation.deriveSessionKey(masterKey: try env.masterKey("delta"), label: "20260911")
        rejects(check, "wrong session key", try vectorCase.string("wire"), { _ in wrong })
        check.end()
    }

    /// A ring holding every master in `inputs.json` and nothing else.
    static func everyMaster(_ env: XCheckEnv) throws -> KeyRing.Snapshot {
        var s = KeyRing.Snapshot()
        for record in try env.list("masters") {
            let master = try env.masterKey(try record.string("name"))
            s.masters[try KeyDerivation.computeMasterId(master)] = master
        }
        return s
    }

    private func rejects(_ check: XCheckCase, _ what: String, _ wire: String, _ lookup: E1Codec.KeyLookup) {
        let result = E1Codec.decrypt(wire: wire, lookup: lookup)
        check.isTrue("\(what) decrypted instead of failing", !result.ok)
    }

    private func tamper(_ id: String, _ wire: String, _ why: String) -> [String: Any] {
        return ["id": id, "wire": wire, "why": why, "expect": "undecryptable"]
    }

    static func refuses(_ text: String, keyId: String, sessionKey: [UInt8]) -> Bool {
        return (try? E1Codec.encrypt(text: text, entities: nil, keyId: keyId, sessionKey: sessionKey)) == nil
    }

    // MARK: wire surgery

    static func flip(_ wire: String, part: Int) -> String {
        var parts = wire.components(separatedBy: ":")
        guard parts.count == 4, var bytes = Base64Url.decode(parts[part]), !bytes.isEmpty else { return wire }
        bytes[0] ^= 0x01
        parts[part] = Base64Url.encode(bytes)
        return parts.joined(separator: ":")
    }

    static func truncate(_ wire: String) -> String {
        var parts = wire.components(separatedBy: ":")
        guard parts.count == 4, let bytes = Base64Url.decode(parts[3]), bytes.count > 1 else { return wire }
        parts[3] = Base64Url.encode([UInt8](bytes.dropLast()))
        return parts.joined(separator: ":")
    }

    static func swapKeyId(_ wire: String, keyId: String) -> String {
        var parts = wire.components(separatedBy: ":")
        guard parts.count == 4 else { return wire }
        parts[1] = keyId
        return parts.joined(separator: ":")
    }

    static func entity(_ object: [String: Any]) throws -> E1Entity {
        guard let type = object["type"] as? String,
              let offset = (object["offset"] as? NSNumber)?.intValue,
              let length = (object["length"] as? NSNumber)?.intValue else {
            throw XCheckError.message("malformed entity in inputs.json")
        }
        var extras = [String: JSONValue]()
        for (key, value) in object where key != "type" && key != "offset" && key != "length" {
            guard let json = JSONValue(any: value) else { throw XCheckError.message("unsupported entity extra \(key)") }
            extras[key] = json
        }
        return E1Entity(type: type, offset: offset, length: length, extras: extras)
    }
}
