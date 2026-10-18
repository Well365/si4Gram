import Foundation

/// P2 transcript hash and key derivation (v1.4 section 8). Ported from
/// `src/secutg/v2/pairing/transcript.ts` and `org.telegram.secutg.v2.pairing.Transcript`.
///
/// ```
/// T = SJ({v, chat_id, txn_id, parent_binding, initiator_user, initiator_device,
///         responder_user, responder_device, invite_hash, accept_hash})
/// th = SHA256(T)
/// z = X25519(ephemeral_sk, peer_ephemeral_pk)
/// prk = HKDF-Extract(salt=th, IKM=z)
/// master = HKDF-Expand(prk, "secuTG/v2/master", 32)
/// kc = HKDF-Expand(prk, "secuTG/v2/confirm", 32)
/// mac_A = HMAC(kc, "A" || th) ; mac_B = HMAC(kc, "B" || th) ; mac_ready = HMAC(kc, "READY" || th)
/// ```
///
/// `th` binds BOTH sides' identity, role and the two hashed messages into the key — not just the DH
/// output — so a transcript computed for one pairing exchange can never collide with one computed for
/// a different txn_id, different participants, or a different invite_hash/accept_hash pair, even if
/// by some coincidence the same ephemeral keys were reused.
public enum V2Transcript {
    public struct Input {
        public let chatId: String
        public let txnId: String
        /// nil for a fresh pairing (v1.4 section 7: "a fresh pairing is empty, a re-pairing
        /// references the old binding").
        public let parentBinding: String?
        public let initiatorUser: String
        /// base64url SHA256(device Ed25519 pk) — the same shape as an envelope's actor_device.
        public let initiatorDevice: String
        public let responderUser: String
        public let responderDevice: String
        /// base64url digests (v1.4 section 7/8).
        public let inviteHash: String
        public let acceptHash: String

        public init(
            chatId: String, txnId: String, parentBinding: String?, initiatorUser: String, initiatorDevice: String,
            responderUser: String, responderDevice: String, inviteHash: String, acceptHash: String
        ) {
            self.chatId = chatId
            self.txnId = txnId
            self.parentBinding = parentBinding
            self.initiatorUser = initiatorUser
            self.initiatorDevice = initiatorDevice
            self.responderUser = responderUser
            self.responderDevice = responderDevice
            self.inviteHash = inviteHash
            self.acceptHash = acceptHash
        }
    }

    private static func transcriptObject(_ input: Input) -> V2SJValue {
        // parent_binding participates in T as an explicit empty string when absent, rather than being
        // left out of the object — SJ has no "null vs missing" distinction a JSON reader would notice,
        // but leaving the key out entirely would make a fresh pairing's T collide with one that
        // happens to omit the same set of other fields for an unrelated reason.
        return .object([
            "v": "2",
            "chat_id": .string(input.chatId),
            "txn_id": .string(input.txnId),
            "initiator_user": .string(input.initiatorUser),
            "initiator_device": .string(input.initiatorDevice),
            "responder_user": .string(input.responderUser),
            "responder_device": .string(input.responderDevice),
            "invite_hash": .string(input.inviteHash),
            "accept_hash": .string(input.acceptHash),
            "parent_binding": .string(input.parentBinding ?? ""),
        ])
    }

    /// T, then th = SHA256(T). `nil` only if a field somehow fails SJ's own constraints.
    public static func computeTranscriptHash(_ input: Input) -> [UInt8]? {
        guard let canonical = V2SJ.serialize(transcriptObject(input)) else { return nil }
        return V2Suite.sha256(V2Suite.utf8(canonical))
    }

    // SECUTG-HOOK (fix E1): `Codable` so `V2Processor.PendingTxn.keys` (set once the transcript
    // hash lands, cleared only by completion/discard) can round-trip in the pending-transaction
    // snapshot alongside `ownEphemeral`.
    public struct DerivedKeys: Codable {
        public let master: [UInt8]
        public let kc: [UInt8]
    }

    /// salt is th (always 32 bytes, a SHA-256 digest) — the one HKDF call site this project has that
    /// needs no extra length check.
    public static func deriveKeys(transcriptHash: [UInt8], sharedSecret: [UInt8]) -> DerivedKeys {
        let prk = V2Suite.hkdfExtract(salt32: transcriptHash, ikm: sharedSecret)
        return DerivedKeys(
            master: V2Suite.hkdfExpand(prk: prk, info: V2Suite.utf8("secuTG/v2/master"), length: 32),
            kc: V2Suite.hkdfExpand(prk: prk, info: V2Suite.utf8("secuTG/v2/confirm"), length: 32)
        )
    }

    private static func confirmMac(kc: [UInt8], role: String, transcriptHash: [UInt8]) -> [UInt8] {
        return V2Suite.hmac(key32: kc, data: V2Suite.concatBytes(V2Suite.utf8(role), transcriptHash))
    }

    public static func computeMacA(kc: [UInt8], transcriptHash: [UInt8]) -> [UInt8] {
        return confirmMac(kc: kc, role: "A", transcriptHash: transcriptHash)
    }

    public static func computeMacB(kc: [UInt8], transcriptHash: [UInt8]) -> [UInt8] {
        return confirmMac(kc: kc, role: "B", transcriptHash: transcriptHash)
    }

    public static func computeMacReady(kc: [UInt8], transcriptHash: [UInt8]) -> [UInt8] {
        return confirmMac(kc: kc, role: "READY", transcriptHash: transcriptHash)
    }

    /// SHA256(UTF8("secuTG/v2/verify") || T) — v1.4 section 8's full safety-code fingerprint, shown
    /// as a QR / hex grid.
    public static func computeFullFingerprint(_ input: Input) -> [UInt8]? {
        guard let canonical = V2SJ.serialize(transcriptObject(input)) else { return nil }
        let t = V2Suite.utf8(canonical)
        return V2Suite.sha256(V2Suite.concatBytes(V2Suite.utf8("secuTG/v2/verify"), t))
    }

    /// v1.4 section 8: the human short code is the fingerprint's first 8 bytes read as an unsigned
    /// big-endian integer, mod 10^12, shown as three groups of four digits — "an approximately 40-bit
    /// convenience comparison value, no zero-collision guarantee; high-assurance scenarios check the
    /// full fingerprint". Returned zero-padded to exactly 12 digits. Unlike the Java port (which needs
    /// BigInteger for this), 8 bytes fits exactly into a native UInt64, so no arbitrary-precision type
    /// is needed here.
    public static func computeShortCode(_ fingerprint: [UInt8]) -> String {
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(fingerprint[i]) }
        let modulus: UInt64 = 1_000_000_000_000
        let digits = String(value % modulus)
        return String(repeating: "0", count: max(0, 12 - digits.count)) + digits
    }
}
