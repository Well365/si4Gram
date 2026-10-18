import Foundation

/// v1.4 section 17's "full disaster backup" — the explicit migration option `V2K2`'s own module doc
/// named as a different, larger feature: unlike the default history-only export, this one DOES carry
/// an Identity's secret keys (signing + encapsulation), so a new device can genuinely become the same
/// identity rather than merely reading old history under it. Ported from
/// `src/secutg/v2/backup/disaster.ts` and `org.telegram.secutg.v2.backup.Disaster`.
///
/// v1.4: "a full disaster backup is a separate option" — a SEPARATE scope (full_disaster), never a
/// flag on the ordinary history-only payload; "importing must not automatically restore admin write
/// rights or verified status" — `ImportResult` structurally has no field a caller could wire into
/// BindingStore.markVerified or a group admin_acl in bulk.
///
/// Reuses `V2K2`'s exact envelope crypto (deriveBackupKey/envelopeAad/kdfLabel/saltBytes) — same
/// wrapping, different payload shape.
public enum V2Disaster {
    public struct Payload: Codable {
        public let exportId: String
        public let sourceDisplayName: String
        public let createdMs: String
        public let scope: String // always "full_disaster"
        /// base64url, Ed25519 secret key — the SAME identity, not a freshly generated one.
        public let identitySk: String
        /// base64url, X25519 secret key.
        public let encapsulationSk: String
        public let keyRecords: [V2K2.KeyRecord]
        public let permissions: [String]

        public init(exportId: String, sourceDisplayName: String, createdMs: String, scope: String, identitySk: String, encapsulationSk: String, keyRecords: [V2K2.KeyRecord], permissions: [String]) {
            self.exportId = exportId
            self.sourceDisplayName = sourceDisplayName
            self.createdMs = createdMs
            self.scope = scope
            self.identitySk = identitySk
            self.encapsulationSk = encapsulationSk
            self.keyRecords = keyRecords
            self.permissions = permissions
        }
    }

    /// v1.4: explicit permission list, distinct from history-only's — this scope grants identity
    /// restoration, never admin/verified.
    private static let fullDisasterPermissions = ["read_history", "restore_identity"]

    public static func buildDisasterPayload(exportId: String, sourceDisplayName: String, createdMs: String, identitySk: [UInt8], encapsulationSk: [UInt8], keyRecords: [V2K2.KeyRecord]) -> Payload {
        return Payload(
            exportId: exportId, sourceDisplayName: sourceDisplayName, createdMs: createdMs, scope: "full_disaster",
            identitySk: Base64Url.encode(identitySk), encapsulationSk: Base64Url.encode(encapsulationSk), keyRecords: keyRecords, permissions: fullDisasterPermissions
        )
    }

    public static func buildDisasterFile(secret: [UInt8], payload: Payload) -> String? {
        let salt = V2Suite.randomBytes(V2K2.saltBytes)
        let nonce = V2Suite.randomBytes(V2Suite.xchacha20NonceBytes)
        let key = V2K2.deriveBackupKey(secret: secret, salt: salt)
        guard let aad = V2K2.envelopeAad(salt: salt, nonce: nonce) else { return nil }
        guard let plaintextData = try? V2K2.jsonEncoder.encode(payload) else { return nil }
        let ciphertext = V2Suite.aeadEncrypt(key: key, nonce: nonce, plaintext: [UInt8](plaintextData), aad: aad)
        let envelope: [String: Any] = ["v": 2, "kdf": V2K2.kdfLabel, "salt": Base64Url.encode(salt), "nonce": Base64Url.encode(nonce), "ciphertext": Base64Url.encode(ciphertext)]
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

        /// v1.4 section 18 step 2's uniform failure, same as history-only's.
        static func invalid() -> DecryptOutcome {
            return DecryptOutcome(ok: false, payload: nil, reason: "invalid")
        }
    }

    public static func decryptDisasterFile(_ fileContent: String, secret: [UInt8]) -> DecryptOutcome {
        guard let data = fileContent.data(using: .utf8) else { return .invalid() }
        guard let raw = try? JSONSerialization.jsonObject(with: data), let envelope = raw as? [String: Any] else { return .invalid() }
        guard (envelope["v"] as? Int) == 2, (envelope["kdf"] as? String) == V2K2.kdfLabel else { return .invalid() }
        guard let saltB64 = envelope["salt"] as? String, let nonceB64 = envelope["nonce"] as? String, let ciphertextB64 = envelope["ciphertext"] as? String else {
            return .invalid()
        }
        guard let salt = Base64Url.decode(saltB64), salt.count == V2K2.saltBytes else { return .invalid() }
        guard let nonce = Base64Url.decode(nonceB64), nonce.count == V2Suite.xchacha20NonceBytes else { return .invalid() }
        guard let ciphertext = Base64Url.decode(ciphertextB64) else { return .invalid() }

        guard let aad = V2K2.envelopeAad(salt: salt, nonce: nonce) else { return .invalid() }
        let key = V2K2.deriveBackupKey(secret: secret, salt: salt)
        guard let plaintext = V2Suite.aeadDecrypt(key: key, nonce: nonce, ciphertext: ciphertext, aad: aad) else { return .invalid() }

        guard let payload = parseDisasterPayload(Data(plaintext)) else { return .invalid() }
        return .ok(payload)
    }

    private static func parseDisasterPayload(_ data: Data) -> Payload? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        guard payload.scope == "full_disaster" else { return nil }
        guard let identitySkBytes = Base64Url.decode(payload.identitySk), identitySkBytes.count == V2Suite.ed25519SkBytes else { return nil }
        guard let encapsulationSkBytes = Base64Url.decode(payload.encapsulationSk), encapsulationSkBytes.count == V2Suite.x25519SkBytes else { return nil }
        return payload
    }

    public struct ImportResult {
        public let identitySk: [UInt8]
        public let encapsulationSk: [UInt8]
        public let keyRecords: [V2K2.KeyRecord]
        // Deliberately NO field for "restored verified bindings" or "restored admin memberships" —
        // v1.4: "importing must not automatically restore admin write rights or verified status".
    }

    /// Decodes the two secret keys out of an already-decrypted payload — everything past decryption
    /// is this file's whole remaining job.
    public static func importDisasterPayload(_ payload: Payload) -> ImportResult? {
        guard let identitySk = Base64Url.decode(payload.identitySk), let encapsulationSk = Base64Url.decode(payload.encapsulationSk) else { return nil }
        return ImportResult(identitySk: identitySk, encapsulationSk: encapsulationSk, keyRecords: payload.keyRecords)
    }
}
