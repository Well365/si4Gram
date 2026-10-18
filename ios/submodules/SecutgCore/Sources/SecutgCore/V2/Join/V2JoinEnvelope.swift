import Foundation

/// PLAN.md 3.39.13: building and opening a V2Q clone code — the crypto half of `V2JoinText`. Mirrors Web A
/// `src/secutg/v2/join/envelope.ts`.
///
///   key   = blake2b(32, "tg-v2-join-v1" || 20-byte code)      (`TransferCode.deriveKey`, 3.14's construction)
///   AEAD  = XChaCha20-Poly1305, AAD = "secutg/v2clone/v1"
///
/// **Constant AAD (3.39.12, kept by 3.39.13).** `binding_id` is INSIDE the ciphertext and the scanning device — which
/// by definition has no binding for this chat yet — has no other way to learn it before decrypting. The payload is
/// authenticated by the tag regardless, and the key is unique per code.
///
/// Refusal reasons, in this order (Web A's; a code that fails several checks gets the FIRST):
///   1. `malformed`      — the text's syntax (`V2JoinText`)
///   2. `old_version`    — the AEAD opens only under 3.39.12's AAD, or the plaintext says `v:1` / `kind:"v2join"`
///   3. `undecryptable`  — the AEAD opens under neither AAD (wrong code, tampered)
///   4. `malformed`      — payload structure, roster order, own keys not a roster member (`V2JoinPayload.parse`)
///   5. `expired`        — `now > expires_ms + 2 min`
///   6. `wrong_chat`     — `peer_user_id` is not the chat being scanned in
///   7. `already_paired` — this chat already has a current binding on this device (`OpenContext.hasCurrentBinding`)
public enum V2Join {
    public enum OpenError: String, Error, Equatable {
        case malformed
        case undecryptable
        case wrongChat = "wrong_chat"
        case expired
        case oldVersion = "old_version"
        case alreadyPaired = "already_paired"
    }

    public struct Opened: Equatable {
        public let code: String
        public let payload: V2JoinPayload.Payload
    }

    public struct OpenContext {
        /// the chat the code is being scanned in — this device's own id for the 1v1 chat (= the peer's user id)
        public let chatId: String
        public let nowMs: Int64
        /// whether this device already has a CURRENT binding for `chatId` (`already_paired`)
        public let hasCurrentBinding: Bool

        public init(chatId: String, nowMs: Int64, hasCurrentBinding: Bool = false) {
            self.chatId = chatId
            self.nowMs = nowMs
            self.hasCurrentBinding = hasCurrentBinding
        }
    }

    /// A fresh 32-character canonical join code (160 bits, 3.14's `TransferCode.generate` without separators).
    public static func generateCode() -> String {
        return V2JoinText.canonicalCode(TransferCode.generate()) ?? ""
    }

    static func keyFor(code: String) -> [UInt8]? {
        guard let codeBytes = TransferCode.parse(code) else { return nil }
        return try? TransferCode.deriveKey(codeBytes, context: V2JoinText.kdfContext)
    }

    /// Encrypts `payload` under `code`. `nonce` exists only for the shared vectors, which need a byte-exact text;
    /// every real code draws a fresh random nonce. nil on a code that is not a canonical join code.
    public static func build(_ payload: V2JoinPayload.Payload, code: String, nonce: [UInt8]? = nil) -> String? {
        return seal(V2JoinPayload.serialize(payload), code: code, nonce: nonce)
    }

    /// The AEAD under `code` of an exact plaintext — `build`'s second half, public for the vectors (reject cases ship
    /// the plaintext they sealed).
    public static func seal(_ plaintext: String, code: String, nonce: [UInt8]? = nil, aad: String = V2JoinText.aad) -> String? {
        guard let canonical = V2JoinText.canonicalCode(code), let key = keyFor(code: canonical) else { return nil }
        if let nonce = nonce, nonce.count != V2Suite.xchacha20NonceBytes { return nil }
        let nonceBytes = nonce ?? V2Suite.randomBytes(V2Suite.xchacha20NonceBytes)
        let ciphertext = V2Suite.aeadEncrypt(key: key, nonce: nonceBytes, plaintext: V2Suite.utf8(plaintext), aad: V2Suite.utf8(aad))
        return V2JoinText.build(code: canonical, nonceB64: Base64Url.encode(nonceBytes), ciphertextB64: Base64Url.encode(ciphertext))
    }

    /// Parse, decrypt with the embedded code, validate — in the order of the type doc. Never throws.
    public static func open(_ text: String, context: OpenContext) -> Result<Opened, OpenError> {
        guard let parsed = V2JoinText.parse(text) else { return .failure(.malformed) }
        guard let key = keyFor(code: parsed.code), let nonce = Base64Url.decode(parsed.nonce), let ciphertext = Base64Url.decode(parsed.ciphertext) else {
            return .failure(.malformed)
        }
        guard let plaintext = V2Suite.aeadDecrypt(key: key, nonce: nonce, ciphertext: ciphertext, aad: V2Suite.utf8(V2JoinText.aad)) else {
            // 3.39.13: an add_device code from a device that was not updated is sealed under 3.39.12's AAD — say so,
            // rather than "wrong code".
            if V2Suite.aeadDecrypt(key: key, nonce: nonce, ciphertext: ciphertext, aad: V2Suite.utf8(V2JoinText.legacyAad)) != nil {
                return .failure(.oldVersion)
            }
            return .failure(.undecryptable)
        }
        guard let json = V2Suite.fromUtf8(plaintext) else { return .failure(.malformed) }
        let payload: V2JoinPayload.Payload
        switch V2JoinPayload.parse(json) {
        case .malformed: return .failure(.malformed)
        case .oldVersion: return .failure(.oldVersion)
        case let .ok(p): payload = p
        }
        guard context.nowMs <= payload.expiresMs + V2JoinText.expiryGraceMs else { return .failure(.expired) }
        guard payload.peerUserId == context.chatId else { return .failure(.wrongChat) }
        guard !context.hasCurrentBinding else { return .failure(.alreadyPaired) }
        return .success(Opened(code: parsed.code, payload: payload))
    }
}
