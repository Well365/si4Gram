import Foundation

/// v2 generic signed envelope (v1.4 section 7, section 25): the shape every wire family (P2, N2, E2,
/// W2) shares. Ported from `src/secutg/v2/envelope.ts` and the Android port
/// (`org.telegram.secutg.v2.Envelope`); keep all three in sync.
///
/// Wire shape: `<PREFIX>:<base64url(SJ(envelope object, sig included))>` — one SJ object per message.
/// `body` is family-specific and opaque here (a `V2SJValue`); a family file reads its own shape out
/// of it.
///
/// Reuses this module's existing `Base64Url` codec (already byte-identical to libsodium's
/// URLSAFE_NO_PADDING, used by v1's own E1 wire) rather than a second hand-rolled implementation —
/// unlike the Web/Android ports, which each define their own base64url pair on `Envelope` itself,
/// this one consolidates onto the codec this module already ships.
public struct V2Envelope {
    /// 16 random bytes, base64url — v1.4 section 7's event_id/txn_id shape.
    public static let idBytes = 16

    public let type: String
    /// This message's own identity, for event_log dedup — a retry reuses it, never regenerates it.
    public let eventId: String
    /// Which exchange this message belongs to; nil only for the very first message of a new one.
    public let txnId: String?
    public let chatId: String
    public let actorUser: String
    /// SHA256(device Ed25519 public key), base64url.
    public let actorDevice: String
    /// 32-byte digest, base64url; nil for a fresh pairing/genesis, present when replacing one.
    public let parentBinding: String?
    public let createdMs: String
    public let expiresMs: String
    /// Family-specific; every security-relevant field lives inside this, and inside the signature.
    public let body: V2SJValue
    /// Only set on an envelope that came from `parse`, or is about to be handed to `build`'s output —
    /// nil on a not-yet-signed one built by a caller.
    public let sig: String?

    public init(
        type: String, eventId: String, txnId: String?, chatId: String, actorUser: String, actorDevice: String,
        parentBinding: String?, createdMs: String, expiresMs: String, body: V2SJValue, sig: String?
    ) {
        self.type = type
        self.eventId = eventId
        self.txnId = txnId
        self.chatId = chatId
        self.actorUser = actorUser
        self.actorDevice = actorDevice
        self.parentBinding = parentBinding
        self.createdMs = createdMs
        self.expiresMs = expiresMs
        self.body = body
        self.sig = sig
    }

    /// Convenience constructor for an envelope not yet built/signed (no `sig` yet).
    public static func unsigned(
        type: String, eventId: String, txnId: String?, chatId: String, actorUser: String, actorDevice: String,
        parentBinding: String?, createdMs: String, expiresMs: String, body: V2SJValue
    ) -> V2Envelope {
        return V2Envelope(
            type: type, eventId: eventId, txnId: txnId, chatId: chatId, actorUser: actorUser, actorDevice: actorDevice,
            parentBinding: parentBinding, createdMs: createdMs, expiresMs: expiresMs, body: body, sig: nil
        )
    }

    /// The domain-separated signing input (v1.4 section 25): `UTF8(domain + "\0") || SJ(envelope
    /// without sig)`. Domain separation stops a signature valid under one family from ever verifying
    /// under another.
    private static func signingInput(domain: String, envelope: V2Envelope) -> [UInt8]? {
        let withoutSig = toSJObject(envelope)
        guard let canonical = V2SJ.serialize(withoutSig) else { return nil }
        return V2Suite.concatBytes(V2Suite.utf8(domain + "\0"), V2Suite.utf8(canonical))
    }

    private static func toSJObject(_ envelope: V2Envelope) -> V2SJValue {
        var out: [String: V2SJValue] = [
            "v": "2",
            "type": .string(envelope.type),
            "event_id": .string(envelope.eventId),
            "chat_id": .string(envelope.chatId),
            "actor_user": .string(envelope.actorUser),
            "actor_device": .string(envelope.actorDevice),
            "created_ms": .string(envelope.createdMs),
            "expires_ms": .string(envelope.expiresMs),
            "body": envelope.body,
        ]
        if let txnId = envelope.txnId { out["txn_id"] = .string(txnId) }
        if let parentBinding = envelope.parentBinding { out["parent_binding"] = .string(parentBinding) }
        return .object(out)
    }

    /// Signs and wire-encodes an envelope. `eventId` is the caller's responsibility to generate ONCE
    /// per message and reuse on every retry (v1.4 section 7: never regenerate on retry) — this method
    /// does not generate it.
    public static func build(prefix: String, domain: String, envelope: V2Envelope, secretKey: [UInt8]) -> String? {
        guard let input = signingInput(domain: domain, envelope: envelope) else { return nil }
        let sig = V2Suite.sign(secretKey: secretKey, message: input)
        guard case .object(var fullMap) = toSJObject(envelope) else { return nil }
        fullMap["sig"] = .string(Base64Url.encode(sig))
        guard let canonical = V2SJ.serialize(.object(fullMap)) else { return nil }
        return prefix + ":" + Base64Url.encode(V2Suite.utf8(canonical))
    }

    /// Structural parse only — does NOT check the signature. A caller often needs to read
    /// `actorUser`/`chatId` to know WHOSE key to verify against before it can call `verify` at all.
    public static func parse(prefix: String, text: String) -> V2Envelope? {
        guard text.hasPrefix(prefix + ":") else { return nil }
        let b64 = String(text.dropFirst(prefix.count + 1))
        guard let bytes = Base64Url.decode(b64) else { return nil }
        guard let json = V2Suite.fromUtf8(bytes) else { return nil }
        guard let value = V2SJ.parse(json), case .object(let obj) = value else { return nil }

        guard case .string("2")? = obj["v"],
              case .string(let type)? = obj["type"],
              case .string(let eventId)? = obj["event_id"],
              case .string(let chatId)? = obj["chat_id"],
              case .string(let actorUser)? = obj["actor_user"],
              case .string(let actorDevice)? = obj["actor_device"],
              case .string(let createdMs)? = obj["created_ms"],
              case .string(let expiresMs)? = obj["expires_ms"],
              case .string(let sig)? = obj["sig"],
              let body = obj["body"],
              isDigestB64(actorDevice), isIdB64(eventId),
              isAllDigits(createdMs), isAllDigits(expiresMs)
        else { return nil }

        var txnId: String? = nil
        if let txnIdValue = obj["txn_id"] {
            guard case .string(let txnIdText) = txnIdValue, isIdB64(txnIdText) else { return nil }
            txnId = txnIdText
        }
        var parentBinding: String? = nil
        if let parentBindingValue = obj["parent_binding"] {
            guard case .string(let parentBindingText) = parentBindingValue, isDigestB64(parentBindingText) else { return nil }
            parentBinding = parentBindingText
        }
        guard let sigBytes = Base64Url.decode(sig), sigBytes.count == V2Suite.signatureBytes else { return nil }

        return V2Envelope(
            type: type, eventId: eventId, txnId: txnId, chatId: chatId, actorUser: actorUser, actorDevice: actorDevice,
            parentBinding: parentBinding, createdMs: createdMs, expiresMs: expiresMs, body: body, sig: sig
        )
    }

    public static func verify(domain: String, envelope: V2Envelope, actorPublicKey: [UInt8]) -> Bool {
        guard actorPublicKey.count == V2Suite.ed25519PkBytes else { return false }
        guard Base64Url.encode(V2Suite.sha256(actorPublicKey)) == envelope.actorDevice else { return false }
        guard let input = signingInput(domain: domain, envelope: envelope) else { return false }
        guard let sig = envelope.sig, let sigBytes = Base64Url.decode(sig) else { return false }
        return V2Suite.verify(publicKey: actorPublicKey, message: input, signature: sigBytes)
    }

    private static func isDigestB64(_ text: String) -> Bool {
        guard let bytes = Base64Url.decode(text) else { return false }
        return bytes.count == V2Suite.digestBytes
    }

    private static func isIdB64(_ text: String) -> Bool {
        guard let bytes = Base64Url.decode(text) else { return false }
        return bytes.count == idBytes
    }

    private static func isAllDigits(_ text: String) -> Bool {
        return !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 16 random bytes, base64url — a fresh event_id/txn_id (v1.4 section 7). Generate once, reuse
    /// on retry.
    public static func randomId() -> String {
        return Base64Url.encode(V2Suite.randomBytes(idBytes))
    }
}
