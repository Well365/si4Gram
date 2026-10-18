import Clibsodium
import Foundation

/// XChaCha20-Poly1305 envelope `{v:1, t:text, e:entities}` with AAD = key_id.
/// Entity `offset` / `length` are validated against the plaintext in UTF-16 units, like Web A / Android.
public enum E1Codec {
    public typealias KeyLookup = (String) -> [UInt8]?

    private static let envelopeVersion = 1
    private static let forbiddenEntityKeys: Set<String> = ["__proto__", "constructor", "prototype"]
    private static let aeadTagBytes = Int(crypto_aead_xchacha20poly1305_ietf_abytes())

    public static func encrypt(text: String, entities: [E1Entity]?, keyId: String, sessionKey: [UInt8]) throws -> String {
        SecutgSodium.ensureReady()
        guard E1Format.isValidKeyId(keyId) else { throw SecutgCryptoError.invalidKeyId }
        guard sessionKey.count == E1Format.keyBytes else { throw SecutgCryptoError.invalidKey }

        var envelope: [String: Any] = ["v": envelopeVersion, "t": text]
        if let entities = entities, !entities.isEmpty {
            envelope["e"] = entities.map(entityToJSON)
        }
        guard let plaintextData = try? JSONSerialization.data(withJSONObject: envelope, options: []) else {
            throw SecutgCryptoError.sodiumFailure("cannot build envelope")
        }
        let plaintext = [UInt8](plaintextData)
        let aad = [UInt8](keyId.utf8)
        let nonce = SecutgSodium.randomBytes(E1Format.nonceBytes)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count + aeadTagBytes)
        var ctLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_encrypt(
            &ciphertext, &ctLen, plaintext, UInt64(plaintext.count), aad, UInt64(aad.count), nil, nonce, sessionKey)
        guard rc == 0 else { throw SecutgCryptoError.sodiumFailure("encryption failed") }
        ciphertext.removeSubrange(Int(ctLen)..<ciphertext.count)
        let wire = E1Format.serialize(keyId: keyId, nonce: nonce, ciphertext: ciphertext)
        if wire.utf16.count > E1Format.wireMaxChars {
            throw SecutgCryptoError.plaintextTooLong(wireChars: wire.utf16.count)
        }
        return wire
    }

    public static func decrypt(wire: String, lookup: KeyLookup) -> DecryptResult {
        SecutgSodium.ensureReady()
        guard let parsed = E1Format.parse(wire) else {
            return .failure(wire.hasPrefix("E1:") ? .malformed : .notEncrypted, keyId: nil)
        }
        guard let sessionKey = lookup(parsed.keyId) else { return .failure(.unknownKey, keyId: parsed.keyId) }
        guard sessionKey.count == E1Format.keyBytes else { return .failure(.invalidKey, keyId: parsed.keyId) }

        let aad = [UInt8](parsed.keyId.utf8)
        var plaintext = [UInt8](repeating: 0, count: parsed.ciphertext.count - aeadTagBytes)
        var ptLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_decrypt(
            &plaintext, &ptLen, nil, parsed.ciphertext, UInt64(parsed.ciphertext.count),
            aad, UInt64(aad.count), parsed.nonce, sessionKey)
        guard rc == 0 else { return .failure(.authFailed, keyId: parsed.keyId) }
        return parseEnvelope(Data(plaintext[0..<Int(ptLen)]), keyId: parsed.keyId)
    }

    private static func parseEnvelope(_ data: Data, keyId: String) -> DecryptResult {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []),
              let envelope = raw as? [String: Any],
              let version = envelope["v"] as? NSNumber, version.intValue == envelopeVersion,
              let text = envelope["t"] as? String else {
            return .failure(.badPlaintext, keyId: keyId)
        }
        guard let e = envelope["e"], !(e is NSNull) else { return .success(keyId: keyId, text: text, entities: nil) }
        guard let list = e as? [Any], let sanitized = sanitizeEntities(list, textLength: text.utf16.count) else {
            return .failure(.badPlaintext, keyId: keyId)
        }
        return .success(keyId: keyId, text: text, entities: sanitized)
    }

    /// Validates type/offset/length against the text and drops prototype-related keys.
    private static func sanitizeEntities(_ list: [Any], textLength: Int) -> [E1Entity]? {
        var out = [E1Entity]()
        for item in list {
            guard let object = item as? [String: Any],
                  let type = object["type"] as? String,
                  let offset = (object["offset"] as? NSNumber).flatMap(exactInt),
                  let length = (object["length"] as? NSNumber).flatMap(exactInt),
                  offset >= 0, length >= 0, offset + length <= textLength else { return nil }
            var extras = [String: JSONValue]()
            for (key, value) in object where !forbiddenEntityKeys.contains(key) && key != "type" && key != "offset" && key != "length" {
                guard let json = JSONValue(any: value) else { return nil }
                extras[key] = json
            }
            out.append(E1Entity(type: type, offset: offset, length: length, extras: extras))
        }
        return out
    }

    private static func exactInt(_ number: NSNumber) -> Int? {
        let d = number.doubleValue
        return d == d.rounded() ? number.intValue : nil
    }

    static func entityToJSON(_ entity: E1Entity) -> [String: Any] {
        var out: [String: Any] = ["type": entity.type, "offset": entity.offset, "length": entity.length]
        for (key, value) in entity.extras where !forbiddenEntityKeys.contains(key) { out[key] = value.any }
        return out
    }
}
