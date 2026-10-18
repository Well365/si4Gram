import Clibsodium
import Foundation

/// PLAN.md 3.4 / 3.5 / 3.31.3 with the exact conventions Web A documents:
/// R1 signature covers `R1:<type>:<new_key_id>:<payload_b64url>`, P1 self-signature covers
/// `P1:<user_id>:<x_pk>:<ed_pk>`, U1 signature covers `U1:<user_id>:<at>`, N1 signature covers
/// `N1:<chat_id>:<user_id>:<at>:<mode>:<old_admin_pk>:<new_admin_pk>`; rotate payload = nonce(24) ||
/// secretbox(new_master, old_session_key); reset payload = JSON {user_id: base64url(sealed)};
/// welcome payload = sealed master.
public enum Rekey {
    public enum R1Type: String { case rotate, reset, welcome, ratchet }

    /// How this generation of a chat's key reaches members (PLAN.md 3.34.1).
    ///
    /// A property of the key, not of the device: chosen once when the key is made, carried in the QR payload
    /// and in the `N1` that announces it, so every member reads the same answer without being told separately.
    /// Anything that cannot be read as one of these is `manual` — the half that sends the user to a person,
    /// and therefore the half that cannot go wrong quietly. Guessing `auto` leaves somebody waiting for a key
    /// nobody is going to send.
    public enum KeyMode: String { case auto, manual }

    public struct ParsedR1: Equatable {
        public let type: R1Type
        public let newKeyId: String
        public let payload: [UInt8]
        public let signature: [UInt8]
        public let signedText: String
    }

    public struct ParsedP1: Equatable {
        public let userId: String
        public let x25519Pk: [UInt8]
        public let ed25519Pk: [UInt8]
        public let signature: [UInt8]
        public let signedText: String
    }

    /// PLAN.md 3.31.3: "this chat is unpaired, destroy your copy of its key too".
    ///
    /// Its own message type rather than a fifth `R1`, because `R1`'s second segment is a mandatory
    /// `master_id.label` and an unpair carries no new key. Putting a made-up key id there would be the first
    /// time `R1`'s "the payload is always a new key sealed to the old one" stopped holding, and nobody reading
    /// the code afterwards could rely on it again.
    public struct ParsedU1: Equatable {
        /// Who is revoking. Checked against the Telegram sender before anything is acted on (3.31.3 rule 2).
        public let userId: String
        /// Unix seconds, judged against the pairing's own `pairedAt` so a late replay cannot kill a fresh pairing
        public let at: Int64
        public let signature: [UInt8]
        /// Bytes the signature was made over
        public let signedText: String
    }

    /// PLAN.md 3.34.3: "this group's key is retired — here is the public key of the one replacing it".
    ///
    /// Its own message type for the same reason `U1` is: it carries no new key, so `R1`'s "the payload is always
    /// a new key sealed to the old one" would stop holding. It is also the one control message a member acts on
    /// *before* it has any reason to trust the key being announced — which is why the signature is the sender's
    /// **identity** key (the one their `P1` announced), never the new admin key. N1 is the only control message
    /// whose signer is a person rather than a chat.
    public struct ParsedN1: Equatable {
        /// Which group. Checked against the chat the message arrived in, so a notice cannot be replayed sideways
        public let chatId: String
        /// Who is retiring the key. Checked against the Telegram sender, then against the group's admin list (3.34.3)
        public let userId: String
        /// Unix seconds
        public let at: Int64
        /// How the replacement key reaches members
        public let mode: KeyMode
        /// The admin public key being retired, or nil for a group's first key.
        ///
        /// Rule 3 of 3.34.3 compares this with the key this device currently trusts and drops the notice when they
        /// differ. That is what makes a replayed notice inert: after the first one is applied the device trusts the
        /// NEW key, so the same notice no longer matches anything.
        public let oldAdminPk: [UInt8]?
        public let newAdminPk: [UInt8]
        public let signature: [UInt8]
        /// Bytes the signature was made over
        public let signedText: String
    }

    public struct SealingIdentity {
        public let x25519Pk: [UInt8]
        public let x25519Sk: [UInt8]
        public init(x25519Pk: [UInt8], x25519Sk: [UInt8]) { self.x25519Pk = x25519Pk; self.x25519Sk = x25519Sk }
    }

    public enum OpenFailure: String, Error, Equatable {
        case noOldKey = "no_old_key", notAddressed = "not_addressed", noIdentity = "no_identity"
        case badPayload = "bad_payload", masterIdMismatch = "master_id_mismatch"
    }

    public struct SigningKeys { public let pk: [UInt8]; public let sk: [UInt8] }
    public struct Built: Equatable { public let wire: String; public let newKeyId: String }

    private static let r1Regex = try! NSRegularExpression(pattern: "^R1:(rotate|reset|welcome|ratchet):([0-9a-f]{16}\\.\\d{8}):([A-Za-z0-9_-]+):([A-Za-z0-9_-]+)$")
    private static let p1Regex = try! NSRegularExpression(pattern: "^P1:(\\d{1,20}):([A-Za-z0-9_-]+):([A-Za-z0-9_-]+):([A-Za-z0-9_-]+)$")
    private static let u1Regex = try! NSRegularExpression(pattern: "^U1:(\\d{1,20}):(\\d{1,20}):([A-Za-z0-9_-]+)$")
    /// Groups and channels are negative, so the chat id alone may carry a sign; `old_admin_pk` is empty on the
    /// first key a group ever has, so that segment alone may be blank.
    private static let n1Regex = try! NSRegularExpression(
        pattern: "^N1:(-?\\d{1,20}):(\\d{1,20}):(\\d{1,20}):(auto|manual):([A-Za-z0-9_-]+|):([A-Za-z0-9_-]+):([A-Za-z0-9_-]+)$")
    private static let maxChars = 4096
    /// `\d{1,20}` admits more than Web A's `Number` holds exactly, and every client has to agree on what is
    /// malformed or one of them acts on a notice the others discard. So `at` stops where JavaScript stops.
    private static let maxSafeAt: Int64 = 9_007_199_254_740_991
    private static let sigBytes = 64
    private static let pkBytes = 32
    private static let nonceBytes = 24
    private static let secretboxMac = Int(crypto_secretbox_macbytes())
    private static let sealBytes = Int(crypto_box_sealbytes())

    // MARK: parsing

    /// The inbound gate. `U1` has to be here or it never reaches the processor at all — it is dropped one layer
    /// earlier and shows up in the chat as a line of raw text (PLAN.md 3.31.4, which is also why every client
    /// must ship the receiving half before any client ships the sending half).
    ///
    /// `P2` (v2's whole family — INVITE/ACCEPT/SELECT/CONFIRM/READY/UNPAIR/CANCEL/ROSTER_COMMIT) is here for the
    /// same reason, plus one v1 has never had: this gate is also `prepareOutgoing`'s passthrough check, so
    /// without it a `P2` sent in a chat that still has a live v1 `E1` session gets needlessly re-encrypted as if
    /// it were ordinary text — the peer then has to unwrap `E1` before it can even see the `P2:` prefix, and this
    /// device's own local echo (`localCopy` / `applySentControlDate`, both gated the same way) shows the raw wire
    /// as a plaintext bubble instead of `handleP2`'s summary. v1 and v2 are separate protocols with their own
    /// wire types; a v1-only length/shape check must never stand in for a real v2 envelope check, so this is a
    /// plain prefix test, unbounded by `maxChars` like the rest of this function — exactly as `transformIncoming`
    /// already treats it at the one other place that recognises `P2:`.
    public static func isControlMessage(_ text: String) -> Bool {
        // Structural, not a bare prefix (review finding, 2026-09-27): text a user types starting with "P2:"
        // is still text and must still be encrypted.
        if text.hasPrefix("P2:"), V2Envelope.parse(prefix: "P2", text: text) != nil { return true }
        // `G2` (PLAN.md 3.35) is here for the same reason `U1` is: miss it and the group's key renders in the
        // chat as a line of text for everyone to read as text — which, for a message that IS the key, is the
        // one failure mode worth spelling out.
        return text.utf16.count <= maxChars
            && (r1Regex.wholeMatch(text) != nil || p1Regex.wholeMatch(text) != nil || u1Regex.wholeMatch(text) != nil
                || n1Regex.wholeMatch(text) != nil || G2.isG2(text)
                // PLAN.md 3.38.2: the group-password policy, for the same reason as `G2`.
                || GP1.isGP1(text))
    }

    public static func isU1(_ text: String) -> Bool {
        return text.utf16.count <= maxChars && u1Regex.wholeMatch(text) != nil
    }

    /// The gate is deliberately looser than `parseN1`, which also checks key and signature lengths and that `at`
    /// round-trips. Where they disagree the gate says yes and the parser says no, so the processor sees the
    /// message and renders "ignored: malformed" — the alternative leaks raw wire text into the chat as if a
    /// person had typed it. `U1` works the same way.
    public static func isN1(_ text: String) -> Bool {
        return text.utf16.count <= maxChars && n1Regex.wholeMatch(text) != nil
    }

    public static func parseR1(_ text: String) -> ParsedR1? {
        guard text.utf16.count <= maxChars, let match = r1Regex.wholeMatch(text) else { return nil }
        let g = match.groups(in: text)
        guard g.count == 4, let type = R1Type(rawValue: g[0]), let payload = Base64Url.decode(g[2]),
              let sig = Base64Url.decode(g[3]), sig.count == sigBytes else { return nil }
        return ParsedR1(type: type, newKeyId: g[1], payload: payload, signature: sig, signedText: "R1:\(g[0]):\(g[1]):\(g[2])")
    }

    public static func parseP1(_ text: String) -> ParsedP1? {
        guard text.utf16.count <= maxChars, let match = p1Regex.wholeMatch(text) else { return nil }
        let g = match.groups(in: text)
        guard g.count == 4, let x = Base64Url.decode(g[1]), x.count == pkBytes, let ed = Base64Url.decode(g[2]), ed.count == pkBytes,
              let sig = Base64Url.decode(g[3]), sig.count == sigBytes else { return nil }
        return ParsedP1(userId: g[0], x25519Pk: x, ed25519Pk: ed, signature: sig, signedText: "P1:\(g[0]):\(g[1]):\(g[2])")
    }

    public static func parseU1(_ text: String) -> ParsedU1? {
        guard text.utf16.count <= maxChars, let match = u1Regex.wholeMatch(text) else { return nil }
        let g = match.groups(in: text)
        guard g.count == 3, let at = Int64(g[1]), at <= maxSafeAt,
              let sig = Base64Url.decode(g[2]), sig.count == sigBytes else { return nil }
        // Rebuilt from the parsed number rather than sliced off the wire, exactly as Web A does: a sender that
        // padded `at` with zeros signed the padded form, and reconstructing here makes that notice fail to
        // verify on every client instead of on some of them.
        return ParsedU1(userId: g[0], at: at, signature: sig, signedText: buildU1SignedText(userId: g[0], at: at))
    }

    public static func parseN1(_ text: String) -> ParsedN1? {
        guard text.utf16.count <= maxChars, let match = n1Regex.wholeMatch(text) else { return nil }
        let g = match.groups(in: text)
        guard g.count == 7, let at = Int64(g[2]), at <= maxSafeAt, let mode = KeyMode(rawValue: g[3]) else { return nil }
        var oldAdminPk: [UInt8]?
        if !g[4].isEmpty {
            guard let pk = Base64Url.decode(g[4]), pk.count == pkBytes else { return nil }
            oldAdminPk = pk
        }
        guard let newAdminPk = Base64Url.decode(g[5]), newAdminPk.count == pkBytes,
              let sig = Base64Url.decode(g[6]), sig.count == sigBytes else { return nil }
        // Rebuilt from the parsed number and the two encoded keys exactly as they stood on the wire, the same way
        // `parseU1` does: a sender that padded `at` with zeros signed the padded form, and reconstructing here
        // makes that notice fail to verify on every client rather than on some of them.
        return ParsedN1(chatId: g[0], userId: g[1], at: at, mode: mode, oldAdminPk: oldAdminPk,
                        newAdminPk: newAdminPk, signature: sig,
                        signedText: buildN1SignedText(chatId: g[0], userId: g[1], at: at, mode: mode,
                                                      oldAdminPkB64: g[4], newAdminPkB64: g[5]))
    }

    // MARK: signatures

    public static func verify(signedText: String, signature: [UInt8], ed25519Pk: [UInt8]) -> Bool {
        guard signature.count == sigBytes, ed25519Pk.count == pkBytes else { return false }
        SecutgSodium.ensureReady()
        let message = [UInt8](signedText.utf8)
        return crypto_sign_verify_detached(signature, message, UInt64(message.count), ed25519Pk) == 0
    }

    /// Self-signature valid and the Telegram sender equals the announced user id.
    public static func verifyP1(_ p1: ParsedP1, senderId: String?) -> Bool {
        guard let senderId = senderId, senderId == p1.userId else { return false }
        return verify(signedText: p1.signedText, signature: p1.signature, ed25519Pk: p1.ed25519Pk)
    }

    /// Whether this notice really was signed by the key given — one half of PLAN.md 3.31.3 rule 4.
    public static func verifyU1Signature(_ u1: ParsedU1, ed25519Pk: [UInt8]) -> Bool {
        return verify(signedText: u1.signedText, signature: u1.signature, ed25519Pk: ed25519Pk)
    }

    /// Whether this notice really was signed by the identity key given — half of PLAN.md 3.34.3 rule 2.
    public static func verifyN1Signature(_ n1: ParsedN1, ed25519Pk: [UInt8]) -> Bool {
        return verify(signedText: n1.signedText, signature: n1.signature, ed25519Pk: ed25519Pk)
    }

    public static func sign(_ text: String, ed25519Sk: [UInt8]) throws -> [UInt8] {
        guard ed25519Sk.count == sigBytes else { throw SecutgCryptoError.invalidKey }
        SecutgSodium.ensureReady()
        let message = [UInt8](text.utf8)
        var sig = [UInt8](repeating: 0, count: sigBytes)
        guard crypto_sign_detached(&sig, nil, message, UInt64(message.count), ed25519Sk) == 0 else {
            throw SecutgCryptoError.sodiumFailure("sign failed")
        }
        return sig
    }

    // MARK: member side

    public static func openR1(_ r1: ParsedR1, candidateMasters: [[UInt8]], identity: SealingIdentity?, ownUserId: String?) -> Result<[UInt8], OpenFailure> {
        guard let keyId = KeyDerivation.parseKeyId(r1.newKeyId) else { return .failure(.badPayload) }
        let master: [UInt8]
        switch r1.type {
        case .rotate, .ratchet:
            var found: [UInt8]?
            for candidate in candidateMasters {
                guard let sessionKey = try? KeyDerivation.deriveSessionKey(masterKey: candidate, label: keyId.label) else { continue }
                if let opened = secretboxOpen(key: sessionKey, sealed: r1.payload) { found = opened; break }
            }
            guard let opened = found else { return .failure(.noOldKey) }
            master = opened
        case .reset:
            guard let identity = identity, let ownUserId = ownUserId else { return .failure(.noIdentity) }
            guard let sealedB64 = readResetEntry(r1.payload, ownUserId: ownUserId) else { return .failure(.notAddressed) }
            guard let sealed = Base64Url.decode(sealedB64), let opened = sealOpen(identity, sealed) else { return .failure(.badPayload) }
            master = opened
        case .welcome:
            guard let identity = identity else { return .failure(.noIdentity) }
            guard let opened = sealOpen(identity, r1.payload) else { return .failure(.notAddressed) }
            master = opened
        }
        guard master.count == KeyDerivation.masterKeyBytes else { return .failure(.badPayload) }
        guard (try? KeyDerivation.computeMasterId(master)) == keyId.masterId else { return .failure(.masterIdMismatch) }
        return .success(master)
    }

    // MARK: admin side

    /// Fresh X25519 (sealing) + Ed25519 (self-signing) key pairs for this device.
    public static func generateIdentity() throws -> KeyRing.Identity {
        SecutgSodium.ensureReady()
        var xPk = [UInt8](repeating: 0, count: pkBytes), xSk = [UInt8](repeating: 0, count: pkBytes)
        var edPk = [UInt8](repeating: 0, count: pkBytes), edSk = [UInt8](repeating: 0, count: sigBytes)
        guard crypto_box_keypair(&xPk, &xSk) == 0, crypto_sign_keypair(&edPk, &edSk) == 0 else {
            throw SecutgCryptoError.sodiumFailure("keypair generation failed")
        }
        return KeyRing.Identity(x25519Pk: xPk, x25519Sk: xSk, ed25519Pk: edPk, ed25519Sk: edSk)
    }

    /// Per-chat admin signing key pair, generated together with the chat's first master.
    public static func generateSigningKeys() throws -> SigningKeys {
        SecutgSodium.ensureReady()
        var pk = [UInt8](repeating: 0, count: pkBytes), sk = [UInt8](repeating: 0, count: sigBytes)
        guard crypto_sign_keypair(&pk, &sk) == 0 else { throw SecutgCryptoError.sodiumFailure("keypair generation failed") }
        return SigningKeys(pk: pk, sk: sk)
    }

    /// `P1:<user_id>:<x_pk>:<ed_pk>:<self_sig>`
    public static func buildP1(userId: String, x25519Pk: [UInt8], ed25519Pk: [UInt8], ed25519Sk: [UInt8]) throws -> String {
        let signed = "P1:\(userId):\(Base64Url.encode(x25519Pk)):\(Base64Url.encode(ed25519Pk))"
        return signed + ":" + Base64Url.encode(try sign(signed, ed25519Sk: ed25519Sk))
    }

    /// The bytes a `U1` signature covers: the wire up to, not including, the signature segment.
    ///
    /// This is a cross-client contract. A port that signs any other string — the whole wire, a trimmed
    /// variant, the same fields in another order — produces notices no other client can verify, and the
    /// failure looks exactly like a forgery rather than like a bug.
    public static func buildU1SignedText(userId: String, at: Int64) -> String {
        return "U1:\(userId):\(at)"
    }

    /// `U1:<user_id>:<at>:<sig_b64url>`
    public static func serializeU1(userId: String, at: Int64, signature: [UInt8]) -> String {
        return buildU1SignedText(userId: userId, at: at) + ":" + Base64Url.encode(signature)
    }

    /// PLAN.md 3.31.3: "this chat is unpaired — destroy your copy of its key too".
    ///
    /// Signed with this device's ed25519 identity key, the one its `P1` announced and the one the peer already
    /// has registered for this chat. Nothing else will do: a notice the receiver cannot tie to the chat's own
    /// peer is a button anybody could press to destroy somebody else's keys and history.
    ///
    /// `at` is unix seconds and is part of the signed text, not decoration. The receiver compares it with the
    /// pairing's own `pairedAt` so that a notice which arrives after the two have paired again — a delayed
    /// delivery, an edit, a replay — cannot take down the pairing that replaced the one it was written about.
    ///
    /// PLAN.md 3.31.4's gate is met — every client recognises a `U1` before any of them sends one, because a
    /// client that does not know `U1` renders it in the chat as a line of raw text — so this is called for real:
    /// `SecutgAccountRuntime.unpair` builds the notice while the pairing record still exists and sends it after
    /// the local destruction, best-effort and never retried.
    public static func buildU1(userId: String, at: Int64, ed25519Sk: [UInt8]) throws -> String {
        let signed = buildU1SignedText(userId: userId, at: at)
        return serializeU1(userId: userId, at: at, signature: try sign(signed, ed25519Sk: ed25519Sk))
    }

    /// The bytes an `N1` signature covers: the wire up to, not including, the signature segment.
    ///
    /// Takes the two keys already base64url-encoded so that what is signed is byte for byte what is sent. A port
    /// that re-encodes them here — padding differently, or using `+/` instead of `-_` — would produce a signature
    /// that fails everywhere rather than a message that quietly means something else.
    public static func buildN1SignedText(chatId: String, userId: String, at: Int64, mode: KeyMode,
                                         oldAdminPkB64: String, newAdminPkB64: String) -> String {
        return "N1:\(chatId):\(userId):\(at):\(mode.rawValue):\(oldAdminPkB64):\(newAdminPkB64)"
    }

    /// `N1:<chat_id>:<user_id>:<at>:<mode>:<old_admin_pk_b64url|empty>:<new_admin_pk_b64url>:<sig_b64url>`
    public static func serializeN1(chatId: String, userId: String, at: Int64, mode: KeyMode,
                                   oldAdminPkB64: String, newAdminPkB64: String, signature: [UInt8]) -> String {
        return buildN1SignedText(chatId: chatId, userId: userId, at: at, mode: mode,
                                 oldAdminPkB64: oldAdminPkB64, newAdminPkB64: newAdminPkB64)
            + ":" + Base64Url.encode(signature)
    }

    /// PLAN.md 3.34.3: "this group's key is retired — here is the public key of the one replacing it".
    ///
    /// Signed with the sender's **identity** key, the one their `P1` announced and every member of the group
    /// already has. It cannot be signed with the new admin key: the whole point of the notice is to tell members
    /// to start trusting that key, so at the moment they read it they have no reason to.
    ///
    /// A notice alone proves nothing about authority — anybody can sign their own. Authority comes from the
    /// receiving side's first check, that the sender is a Telegram admin of this group, which the protocol layer
    /// cannot answer and the UI layer supplies (3.34.3 rule 1).
    ///
    /// `oldAdminPk` is nil for a group's first key, and the segment is left empty on the wire. The receiving
    /// side's replay check reads that as "applies only where nothing is trusted yet".
    public static func buildN1(chatId: String, userId: String, at: Int64, mode: KeyMode,
                               oldAdminPk: [UInt8]?, newAdminPk: [UInt8], ed25519Sk: [UInt8]) throws -> String {
        let oldB64 = oldAdminPk.map(Base64Url.encode) ?? ""
        let newB64 = Base64Url.encode(newAdminPk)
        let signed = buildN1SignedText(chatId: chatId, userId: userId, at: at, mode: mode,
                                       oldAdminPkB64: oldB64, newAdminPkB64: newB64)
        return serializeN1(chatId: chatId, userId: userId, at: at, mode: mode, oldAdminPkB64: oldB64,
                           newAdminPkB64: newB64, signature: try sign(signed, ed25519Sk: ed25519Sk))
    }

    public static func buildRotate(newMaster: [UInt8], oldMaster: [UInt8], adminSk: [UInt8], nowMs: Int64, epochDays: Int) throws -> Built {
        let label = KeyDerivation.toEpochLabel(nowMs: nowMs, epochDays: epochDays)
        let sessionKey = try KeyDerivation.deriveSessionKey(masterKey: oldMaster, label: label)
        return try finish(.rotate, master: newMaster, label: label, payload: try secretboxSeal(key: sessionKey, bytes: newMaster), adminSk: adminSk)
    }

    /// ratchet (PLAN.md 3.8): same payload as rotate; switches the auto-paired chat into daily rotation from this master
    public static func buildRatchet(baseMaster: [UInt8], oldMaster: [UInt8], identityEdSk: [UInt8], nowMs: Int64, epochDays: Int) throws -> Built {
        let label = KeyDerivation.toEpochLabel(nowMs: nowMs, epochDays: epochDays)
        let sessionKey = try KeyDerivation.deriveSessionKey(masterKey: oldMaster, label: label)
        return try finish(.ratchet, master: baseMaster, label: label, payload: try secretboxSeal(key: sessionKey, bytes: baseMaster), adminSk: identityEdSk)
    }

    public static func buildReset(newMaster: [UInt8], recipients: [String: [UInt8]], adminSk: [UInt8], nowMs: Int64, epochDays: Int) throws -> Built {
        guard !recipients.isEmpty else { throw SecutgCryptoError.sodiumFailure("reset needs at least one member") }
        let label = KeyDerivation.toEpochLabel(nowMs: nowMs, epochDays: epochDays)
        var table = [String: String]()
        for (userId, pk) in recipients { table[userId] = Base64Url.encode(try sealFor(recipientPk: pk, bytes: newMaster)) }
        let payload = try JSONSerialization.data(withJSONObject: table, options: [.sortedKeys])
        return try finish(.reset, master: newMaster, label: label, payload: [UInt8](payload), adminSk: adminSk)
    }

    public static func buildWelcome(currentMaster: [UInt8], newcomerX25519Pk: [UInt8], adminSk: [UInt8], nowMs: Int64, epochDays: Int) throws -> Built {
        let label = KeyDerivation.toEpochLabel(nowMs: nowMs, epochDays: epochDays)
        return try finish(.welcome, master: currentMaster, label: label, payload: try sealFor(recipientPk: newcomerX25519Pk, bytes: currentMaster), adminSk: adminSk)
    }

    private static func finish(_ type: R1Type, master: [UInt8], label: String, payload: [UInt8], adminSk: [UInt8]) throws -> Built {
        let newKeyId = KeyDerivation.buildKeyId(masterId: try KeyDerivation.computeMasterId(master), label: label)
        let signedText = "R1:\(type.rawValue):\(newKeyId):\(Base64Url.encode(payload))"
        return Built(wire: signedText + ":" + Base64Url.encode(try sign(signedText, ed25519Sk: adminSk)), newKeyId: newKeyId)
    }

    // MARK: primitives

    private static func sealFor(recipientPk: [UInt8], bytes: [UInt8]) throws -> [UInt8] {
        guard recipientPk.count == pkBytes else { throw SecutgCryptoError.invalidKey }
        var out = [UInt8](repeating: 0, count: bytes.count + sealBytes)
        guard crypto_box_seal(&out, bytes, UInt64(bytes.count), recipientPk) == 0 else { throw SecutgCryptoError.sodiumFailure("seal failed") }
        return out
    }

    private static func secretboxSeal(key: [UInt8], bytes: [UInt8]) throws -> [UInt8] {
        let nonce = SecutgSodium.randomBytes(nonceBytes)
        var box = [UInt8](repeating: 0, count: bytes.count + secretboxMac)
        guard crypto_secretbox_easy(&box, bytes, UInt64(bytes.count), nonce, key) == 0 else { throw SecutgCryptoError.sodiumFailure("secretbox failed") }
        return nonce + box
    }

    private static func secretboxOpen(key: [UInt8], sealed: [UInt8]) -> [UInt8]? {
        guard sealed.count > nonceBytes + secretboxMac else { return nil }
        let nonce = Array(sealed[0..<nonceBytes])
        let box = Array(sealed[nonceBytes...])
        var out = [UInt8](repeating: 0, count: box.count - secretboxMac)
        return crypto_secretbox_open_easy(&out, box, UInt64(box.count), nonce, key) == 0 ? out : nil
    }

    private static func sealOpen(_ identity: SealingIdentity, _ sealed: [UInt8]) -> [UInt8]? {
        guard sealed.count > sealBytes, identity.x25519Pk.count == pkBytes, identity.x25519Sk.count == pkBytes else { return nil }
        var out = [UInt8](repeating: 0, count: sealed.count - sealBytes)
        return crypto_box_seal_open(&out, sealed, UInt64(sealed.count), identity.x25519Pk, identity.x25519Sk) == 0 ? out : nil
    }

    private static func readResetEntry(_ payload: [UInt8], ownUserId: String) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(payload)), let table = raw as? [String: Any] else { return nil }
        return table[ownUserId] as? String
    }
}
