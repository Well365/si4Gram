import Foundation

/// v1.4 section 17/18's K2 backup file — encrypts a set of already-readable key records (history
/// decryption material a device already holds, via `V2KeyStore.BindingKeyStore` or
/// `V2GroupKeyStore`) under a 32-byte random carry secret (`V2Crockford`'s human-typeable form of
/// it), so they can be moved to another device or archived. Ported from
/// `src/secutg/v2/backup/k2.ts` and `org.telegram.secutg.v2.backup.K2`.
///
/// Deliberately scoped to v1.4's DEFAULT export only — this file never touches an Identity's secret
/// keys at all, only KeyRecord-shaped master material already exported by the caller. The full
/// disaster backup is a different, larger feature — see `V2Disaster`.
///
/// Unlike every P2/N2/E2/W2 wire, the outer envelope and inner payload here are plain JSON (via
/// `Codable` + `JSONEncoder`/`JSONDecoder`, with `.sortedKeys` output for determinism), not SJ — this
/// is a local FILE, not a signed wire message needing byte-for-byte canonical determinism for a
/// signature to cover. Field names match the TS/Java ports' own camelCase JSON keys directly (no
/// snake_case conversion, since `JSON.stringify`/`org.json` on the other two ports don't do one
/// either).
public enum V2K2 {
    public static let kdfLabel = "HKDF-SHA256"
    private static let backupKeyDomain = "secuTG/v2/backup"
    public static let saltBytes = 32

    /// One already-decrypted generation's key, in either family.
    public struct KeyRecord: Codable, Equatable {
        public let scopeKind: String // "private" | "group"
        public let chatId: String
        public let bindingOrGenesisId: String
        public let epoch: Int
        /// GroupKeyStore's own per-generation lookup key — REQUIRED for scopeKind=group, nil for
        /// scopeKind=private.
        public let stateHash: String?
        /// base64url — only ever a current/historical (readable) record.
        public let master: String

        public init(scopeKind: String, chatId: String, bindingOrGenesisId: String, epoch: Int, stateHash: String?, master: String) {
            self.scopeKind = scopeKind
            self.chatId = chatId
            self.bindingOrGenesisId = bindingOrGenesisId
            self.epoch = epoch
            self.stateHash = stateHash
            self.master = master
        }
    }

    public struct Payload: Codable {
        public let exportId: String
        public let sourceDisplayName: String
        public let createdMs: String
        public let scope: String // always "history_only"
        public let keyRecords: [KeyRecord]
        /// v1.4 section 17: "an explicit permission list" — what importing this file does NOT
        /// grant, stated rather than implied.
        public let permissions: [String]

        public init(exportId: String, sourceDisplayName: String, createdMs: String, scope: String, keyRecords: [KeyRecord], permissions: [String]) {
            self.exportId = exportId
            self.sourceDisplayName = sourceDisplayName
            self.createdMs = createdMs
            self.scope = scope
            self.keyRecords = keyRecords
            self.permissions = permissions
        }
    }

    private static let historyOnlyPermissions = ["read_history"]

    private static func keyRecordId(_ record: KeyRecord) -> String {
        return "\(record.scopeKind)\0\(record.bindingOrGenesisId)\0\(record.epoch)"
    }

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static func deriveBackupKey(secret: [UInt8], salt: [UInt8]) -> [UInt8] {
        let prk = V2Suite.hkdfExtract(salt32: salt, ikm: secret)
        return V2Suite.hkdfExpand(prk: prk, info: V2Suite.utf8(backupKeyDomain), length: 32)
    }

    public static func envelopeAad(salt: [UInt8], nonce: [UInt8]) -> [UInt8]? {
        let obj: V2SJValue = .object(["v": "2", "kdf": .string(kdfLabel), "salt": .string(Base64Url.encode(salt)), "nonce": .string(Base64Url.encode(nonce))])
        guard let canonical = V2SJ.serialize(obj) else { return nil }
        return V2Suite.utf8(canonical)
    }

    /// v1.4 section 17: {v:2, kdf:"HKDF-SHA256", salt, nonce, ciphertext}, key = HKDF(secret, salt,
    /// "secuTG/v2/backup", 32), AEAD = XChaCha20Poly1305 with AAD = JCS({v,kdf,salt,nonce}). A fresh
    /// exportId/createdMs are the caller's own responsibility.
    public static func buildK2File(secret: [UInt8], payload: Payload) -> String? {
        let salt = V2Suite.randomBytes(saltBytes)
        let nonce = V2Suite.randomBytes(V2Suite.xchacha20NonceBytes)
        let key = deriveBackupKey(secret: secret, salt: salt)
        guard let aad = envelopeAad(salt: salt, nonce: nonce) else { return nil }
        guard let plaintextData = try? jsonEncoder.encode(payload) else { return nil }
        let ciphertext = V2Suite.aeadEncrypt(key: key, nonce: nonce, plaintext: [UInt8](plaintextData), aad: aad)
        let envelope: [String: Any] = ["v": 2, "kdf": kdfLabel, "salt": Base64Url.encode(salt), "nonce": Base64Url.encode(nonce), "ciphertext": Base64Url.encode(ciphertext)]
        guard let envelopeData = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else { return nil }
        return String(data: envelopeData, encoding: .utf8)
    }

    public struct DecryptOutcome {
        public let ok: Bool
        public let payload: Payload?
        public let reason: String?

        static func ok(_ payload: Payload) -> DecryptOutcome {
            return DecryptOutcome(ok: true, payload: payload, reason: nil)
        }

        /// v1.4 section 18 step 2: "an authenticated-decryption failure always returns the same...
        /// never exposes a partial manifest" — ONE reason, for a malformed file, an unparseable
        /// envelope, a wrong carry secret, AND a corrupted ciphertext alike.
        static func invalid() -> DecryptOutcome {
            return DecryptOutcome(ok: false, payload: nil, reason: "invalid")
        }
    }

    public static func decryptK2File(_ fileContent: String, secret: [UInt8]) -> DecryptOutcome {
        guard let data = fileContent.data(using: .utf8) else { return .invalid() }
        guard let raw = try? JSONSerialization.jsonObject(with: data), let envelope = raw as? [String: Any] else { return .invalid() }
        guard (envelope["v"] as? Int) == 2, (envelope["kdf"] as? String) == kdfLabel else { return .invalid() }
        guard let saltB64 = envelope["salt"] as? String, let nonceB64 = envelope["nonce"] as? String, let ciphertextB64 = envelope["ciphertext"] as? String else {
            return .invalid()
        }
        guard let salt = Base64Url.decode(saltB64), salt.count == saltBytes else { return .invalid() }
        guard let nonce = Base64Url.decode(nonceB64), nonce.count == V2Suite.xchacha20NonceBytes else { return .invalid() }
        guard let ciphertext = Base64Url.decode(ciphertextB64) else { return .invalid() }

        guard let aad = envelopeAad(salt: salt, nonce: nonce) else { return .invalid() }
        let key = deriveBackupKey(secret: secret, salt: salt)
        guard let plaintext = V2Suite.aeadDecrypt(key: key, nonce: nonce, ciphertext: ciphertext, aad: aad) else { return .invalid() }

        guard let payload = parsePayload(Data(plaintext)) else { return .invalid() }
        return .ok(payload)
    }

    private static func parsePayload(_ data: Data) -> Payload? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        guard payload.scope == "history_only" else { return nil }
        for record in payload.keyRecords {
            guard record.scopeKind == "private" || record.scopeKind == "group" else { return nil }
            guard record.epoch >= 0 else { return nil }
            if record.scopeKind == "group", record.stateHash == nil { return nil }
            if record.scopeKind == "private", record.stateHash != nil { return nil }
            guard let masterBytes = Base64Url.decode(record.master), masterBytes.count == 32 else { return nil }
        }
        return payload
    }

    public static func buildHistoryOnlyPayload(exportId: String, sourceDisplayName: String, createdMs: String, keyRecords: [KeyRecord]) -> Payload {
        return Payload(exportId: exportId, sourceDisplayName: sourceDisplayName, createdMs: createdMs, scope: "history_only", keyRecords: keyRecords, permissions: historyOnlyPermissions)
    }

    /// v1.4 section 18 step 3/4: a previewToken bound to the decrypted content AND the caller's
    /// current revision marker. Recomputed and compared at import time in validateForImport; never
    /// persisted.
    public static func computePreviewToken(_ payload: Payload, revision: String) -> String {
        let payloadData = (try? jsonEncoder.encode(payload)) ?? Data()
        let payloadHash = V2Suite.sha256([UInt8](payloadData))
        return Base64Url.encode(V2Suite.sha256(V2Suite.concatBytes(payloadHash, V2Suite.utf8(revision))))
    }

    public struct ValidateOutcome {
        public let ok: Bool
        public let records: [KeyRecord]?
        public let reason: String?

        static func ok(_ records: [KeyRecord]) -> ValidateOutcome {
            return ValidateOutcome(ok: true, records: records, reason: nil)
        }

        static func fail(_ reason: String) -> ValidateOutcome {
            return ValidateOutcome(ok: false, records: nil, reason: reason)
        }
    }

    /// v1.4 section 18 steps 4/5: refuses a STALE preview (the recomputed token no longer matching)
    /// and a payload where the SAME (scopeKind, bindingOrGenesisId, epoch) appears twice with
    /// DIFFERENT master material. Does NOT itself merge anything into a store — see `V2Merge`.
    public static func validateForImport(_ payload: Payload, previewToken: String, revision: String) -> ValidateOutcome {
        guard computePreviewToken(payload, revision: revision) == previewToken else { return .fail("stale_preview") }

        var seen: [String: String] = [:]
        for record in payload.keyRecords {
            let id = keyRecordId(record)
            if let existingMaster = seen[id], existingMaster != record.master {
                return .fail("conflicting_key_material")
            }
            seen[id] = record.master
        }
        return .ok(payload.keyRecords)
    }
}
