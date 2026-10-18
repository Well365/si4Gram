import Foundation

/// v1.4 section 15's E2 — the layer that actually encrypts/decrypts a chat MESSAGE using the master
/// key P2 (pairing) or N2 (group) already established. Neither of those modules stores a master
/// itself — this file is deliberately master-agnostic to match: every function here takes the master
/// (and the derivation salt) as an explicit parameter, never looks either up itself. Ported from
/// `src/secutg/v2/data/e2.ts` and `org.telegram.secutg.v2.data.E2`.
///
/// Wire: `E2:<base64url(JCS({header, nonce, ciphertext, sig}))>` — NOT built on `V2Envelope`'s
/// generic signed envelope — E2's header has none of event_id/actor_user/created_ms/expires_ms (this
/// is a business message, not a protocol control event), so this file signs its own, leaner object
/// directly, the same way `V2Transcript` computes its own hashes outside `V2Envelope` for the same
/// reason.
///
/// v1.4 section 15: key = HKDF-SHA256(master, salt=state_or_binding_hash, info="secuTG/v2/data/" ||
/// sender_device_bytes, L=32). The salt is NOT the same value as the header's own genesis_or_binding
/// field for a GROUP message — resolving which salt applies is the caller's job (`V2DataProcessor`).
public enum V2E2 {
    public static let prefix = "E2"
    public static let domain = "secuTG/v2/E2"
    private static let dataKeyDomain = "secuTG/v2/data/"

    /// v1.4 section 15's header table: {v, chat_id, genesis_or_binding, epoch, sender_device,
    /// permit_hash, msg_id, seq}. permitHash is present ONLY for a group message.
    public struct Header {
        public let chatId: String
        public let genesisOrBinding: String
        /// Decimal string, per SJ's no-numbers rule.
        public let epoch: String
        public let senderDevice: String
        /// nil for a private-chat message.
        public let permitHash: String?
        public let msgId: String
        /// Decimal string — a per-device-per-generation monotonically increasing unsigned 64-bit
        /// decimal string; kept as a string throughout since a real 64-bit value can exceed a safe
        /// numeric range. Ordering/monotonicity is V2DataProcessor's job, not this file's.
        public let seq: String

        public init(chatId: String, genesisOrBinding: String, epoch: String, senderDevice: String, permitHash: String?, msgId: String, seq: String) {
            self.chatId = chatId
            self.genesisOrBinding = genesisOrBinding
            self.epoch = epoch
            self.senderDevice = senderDevice
            self.permitHash = permitHash
            self.msgId = msgId
            self.seq = seq
        }
    }

    /// HKDF-Extract(salt, master) then HKDF-Expand(prk, "secuTG/v2/data/" || sender_device_bytes, 32)
    /// — v1.4 section 15's own formula, verbatim.
    public static func deriveDataKey(master: [UInt8], saltStateOrBindingHash: [UInt8], senderDeviceBytes: [UInt8]) -> [UInt8] {
        let prk = V2Suite.hkdfExtract(salt32: saltStateOrBindingHash, ikm: master)
        return V2Suite.hkdfExpand(prk: prk, info: V2Suite.concatBytes(V2Suite.utf8(dataKeyDomain), senderDeviceBytes), length: 32)
    }

    public struct Parsed {
        public let header: Header
        public let nonce: [UInt8]
        public let ciphertext: [UInt8]
        public let sig: [UInt8]
    }

    private static func headerToSJObject(_ header: Header) -> V2SJValue {
        var obj: [String: V2SJValue] = [
            "v": "2", "chat_id": .string(header.chatId), "genesis_or_binding": .string(header.genesisOrBinding),
            "epoch": .string(header.epoch), "sender_device": .string(header.senderDevice), "msg_id": .string(header.msgId), "seq": .string(header.seq),
        ]
        if let permitHash = header.permitHash { obj["permit_hash"] = .string(permitHash) }
        return .object(obj)
    }

    /// The exact bytes sig covers: "secuTG/v2/E2\0" || JCS({header, nonce, ciphertext}) — v1.4
    /// section 15, verbatim. nil only if a field somehow fails SJ's own constraints.
    private static func signingInput(header: Header, nonce: [UInt8], ciphertext: [UInt8]) -> [UInt8]? {
        let signable: V2SJValue = .object(["header": headerToSJObject(header), "nonce": .string(Base64Url.encode(nonce)), "ciphertext": .string(Base64Url.encode(ciphertext))])
        guard let canonical = V2SJ.serialize(signable) else { return nil }
        return V2Suite.concatBytes(V2Suite.utf8(domain + "\0"), V2Suite.utf8(canonical))
    }

    public struct BuildParams {
        public let header: Header
        public let plaintext: [UInt8]
        public let master: [UInt8]
        public let saltStateOrBindingHash: [UInt8]
        public let senderIdentitySk: [UInt8]
        /// Explicit ONLY for a RETRY (v1.4 section 15) — nil, a fresh CSPRNG nonce is drawn.
        public let nonce: [UInt8]?

        public init(header: Header, plaintext: [UInt8], master: [UInt8], saltStateOrBindingHash: [UInt8], senderIdentitySk: [UInt8], nonce: [UInt8]?) {
            self.header = header
            self.plaintext = plaintext
            self.master = master
            self.saltStateOrBindingHash = saltStateOrBindingHash
            self.senderIdentitySk = senderIdentitySk
            self.nonce = nonce
        }
    }

    public static func build(_ params: BuildParams) -> String? {
        guard let senderDeviceBytes = Base64Url.decode(params.header.senderDevice) else { return nil }
        let key = deriveDataKey(master: params.master, saltStateOrBindingHash: params.saltStateOrBindingHash, senderDeviceBytes: senderDeviceBytes)
        let nonce = params.nonce ?? V2Suite.randomBytes(V2Suite.xchacha20NonceBytes)
        guard let headerCanonical = V2SJ.serialize(headerToSJObject(params.header)) else { return nil }
        let ciphertext = V2Suite.aeadEncrypt(key: key, nonce: nonce, plaintext: params.plaintext, aad: V2Suite.utf8(headerCanonical))

        guard let input = signingInput(header: params.header, nonce: nonce, ciphertext: ciphertext) else { return nil }
        let sig = V2Suite.sign(secretKey: params.senderIdentitySk, message: input)

        let full: V2SJValue = .object([
            "header": headerToSJObject(params.header), "nonce": .string(Base64Url.encode(nonce)),
            "ciphertext": .string(Base64Url.encode(ciphertext)), "sig": .string(Base64Url.encode(sig)),
        ])
        guard let fullCanonical = V2SJ.serialize(full) else { return nil }
        return prefix + ":" + Base64Url.encode(V2Suite.utf8(fullCanonical))
    }

    private static let wireRegex = try! NSRegularExpression(pattern: "^E2:[A-Za-z0-9_-]+$")

    /// PLAN.md 3.44: purely syntactic, the twin of `E1Format.isEncrypted` — the shape of an E2 wire, not its
    /// validity. This is the question PLAN.md 3.19 asks of a stored text ("is this still the envelope rather than
    /// the words?") and of a wire before a message is put away behind it; `parse` is the stricter question, and
    /// deliberately not this one, for the same reason `E1Format` keeps the two apart: a damaged wire is still a
    /// wire, to be shown as the 3.17 notice rather than as its own base64. A text that merely begins with `E2:`
    /// (a space, a quote, anything outside base64url) is words. A wire longer than Telegram's limit can never be ours.
    public static func isWire(_ text: String) -> Bool {
        return text.utf16.count <= E1Format.wireMaxChars && wireRegex.wholeMatch(text) != nil
    }

    /// Structural parse only — does NOT verify the signature or decrypt.
    public static func parse(_ wire: String) -> Parsed? {
        guard wire.hasPrefix(prefix + ":") else { return nil }
        let b64 = String(wire.dropFirst(prefix.count + 1))
        guard let bytes = Base64Url.decode(b64) else { return nil }
        guard let json = V2Suite.fromUtf8(bytes) else { return nil }
        guard let value = V2SJ.parse(json), case .object(let obj) = value else { return nil }

        guard let header = parseHeader(obj["header"]) else { return nil }
        guard case .string(let nonceB64)? = obj["nonce"], let nonce = Base64Url.decode(nonceB64), nonce.count == V2Suite.xchacha20NonceBytes else { return nil }
        guard case .string(let ciphertextB64)? = obj["ciphertext"], !ciphertextB64.isEmpty, let ciphertext = Base64Url.decode(ciphertextB64) else { return nil }
        guard case .string(let sigB64)? = obj["sig"], let sig = Base64Url.decode(sigB64), sig.count == V2Suite.signatureBytes else { return nil }

        return Parsed(header: header, nonce: nonce, ciphertext: ciphertext, sig: sig)
    }

    /// v1.4 section 15: "a shared group key does not prove which member sent it, so the outer device
    /// signature must always be verified, and the signing public key must match this generation's
    /// permit" — this function only checks the SIGNATURE against a caller-supplied key; matching that
    /// key to the CURRENT generation's registered sender is the caller's job.
    public static func verifySignature(_ parsed: Parsed, senderIdentityPk: [UInt8]) -> Bool {
        guard let input = signingInput(header: parsed.header, nonce: parsed.nonce, ciphertext: parsed.ciphertext) else { return false }
        return V2Suite.verify(publicKey: senderIdentityPk, message: input, signature: parsed.sig)
    }

    /// Fails closed (nil) on a wrong key, wrong salt, or tampered header/ciphertext/AAD — never throws.
    public static func decrypt(_ parsed: Parsed, master: [UInt8], saltStateOrBindingHash: [UInt8]) -> [UInt8]? {
        guard let senderDeviceBytes = Base64Url.decode(parsed.header.senderDevice) else { return nil }
        let key = deriveDataKey(master: master, saltStateOrBindingHash: saltStateOrBindingHash, senderDeviceBytes: senderDeviceBytes)
        guard let headerCanonical = V2SJ.serialize(headerToSJObject(parsed.header)) else { return nil }
        return V2Suite.aeadDecrypt(key: key, nonce: parsed.nonce, ciphertext: parsed.ciphertext, aad: V2Suite.utf8(headerCanonical))
    }

    /// SHA256(identity_pk), base64url — the same actor_device/device_id shape every other v2 family
    /// uses.
    public static func deviceIdOf(_ identityPk: [UInt8]) -> String {
        return Base64Url.encode(V2Suite.sha256(identityPk))
    }

    private static func isDigestB64(_ text: String) -> Bool {
        guard let bytes = Base64Url.decode(text) else { return false }
        return bytes.count == V2Suite.digestBytes
    }

    private static func isIdB64(_ text: String) -> Bool {
        guard let bytes = Base64Url.decode(text) else { return false }
        return bytes.count == V2Envelope.idBytes
    }

    private static func parseHeader(_ raw: V2SJValue?) -> Header? {
        guard case .object(let obj)? = raw else { return nil }
        guard case .string("2")? = obj["v"] else { return nil }
        guard case .string(let chatId)? = obj["chat_id"], !chatId.isEmpty else { return nil }
        guard case .string(let genesisOrBinding)? = obj["genesis_or_binding"], isDigestB64(genesisOrBinding) else { return nil }
        guard case .string(let epoch)? = obj["epoch"], epoch.range(of: "^[0-9]+$", options: .regularExpression) != nil else { return nil }
        guard case .string(let senderDevice)? = obj["sender_device"], isDigestB64(senderDevice) else { return nil }
        var permitHash: String? = nil
        if let permitHashValue = obj["permit_hash"] {
            guard case .string(let p) = permitHashValue, isDigestB64(p) else { return nil }
            permitHash = p
        }
        guard case .string(let msgId)? = obj["msg_id"], isIdB64(msgId) else { return nil }
        guard case .string(let seq)? = obj["seq"], seq.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil else { return nil }
        return Header(chatId: chatId, genesisOrBinding: genesisOrBinding, epoch: epoch, senderDevice: senderDevice, permitHash: permitHash, msgId: msgId, seq: seq)
    }
}
