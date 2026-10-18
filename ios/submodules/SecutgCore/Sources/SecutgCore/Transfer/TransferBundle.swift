import Clibsodium
import Foundation

/// Which slice of the keyring a transfer file carries (PLAN.md 3.14).
public enum TransferScope: String, Equatable {
    case all
    case chat
}

/// Plain text of a `K1` container before it is encrypted.
public struct TransferPayload: Equatable {
    public let v: Int
    public let scope: TransferScope
    /// `chat` scope: which chats the snapshot covers
    public let chatIds: [String]?
    /// unix seconds
    public let createdAt: Int64
    /// free text, shown in the import dialog so the user recognises the source device
    public let device: String
    public let snapshot: KeyRing.Snapshot

    public init(v: Int = TransferBundle.version, scope: TransferScope, chatIds: [String]? = nil,
                createdAt: Int64, device: String, snapshot: KeyRing.Snapshot) {
        self.v = v
        self.scope = scope
        self.chatIds = chatIds
        self.createdAt = createdAt
        self.device = device
        self.snapshot = snapshot
    }
}

/// What the import dialog shows before anything is written to this device's keyring.
public struct TransferSummary: Equatable {
    public let scope: TransferScope
    public let chatIds: [String]
    public let createdAt: Int64
    public let device: String
    public let masterCount: Int
    public let chatCount: Int
    public let hasIdentity: Bool
    public let isStale: Bool
    /// PLAN.md 3.14 import step 1 / 3.25.4 rule 2: whether this file carries device labels at all — the
    /// import dialog's manifest line ("含你写的设备备注" / "不含设备备注").
    public let hasDeviceLabels: Bool
    /// PLAN.md 3.30 item 8: how many groups' admin signing keys ride along. This is not the same question
    /// as `masterCount` — a master lets the holder *read* a group, an admin secret lets them rekey it and
    /// remove members from it. A whole-keyring export has always carried these; until this field existed
    /// neither the export nor the import manifest said so, which meant handing over a file was handing
    /// over powers the manifest never named.
    public let adminChatCount: Int
}

/// Keyring transfer container (PLAN.md 3.14): `K1:1:<nonce>:<ciphertext>`, XChaCha20-Poly1305 under a key
/// derived from the transfer code, AAD `K1:1`. Plain text, so it travels as a file, as a clipboard paste or
/// as a QR code without further encoding. The JSON inside is the cross-client shape (camelCase keys, byte
/// arrays as `{"$b": "<base64url>"}`), so a file written by Web A / Android opens here and vice versa.
public enum TransferBundle {
    public static let version = 1
    public static let prefix = "K1:"
    /// Older than this, the import dialog asks the user to confirm the file is still trustworthy
    public static let staleSeconds: Int64 = 7 * 24 * 3600

    private static let aad = Array("K1:1".utf8)
    private static let nonceBytes = 24
    private static let tagBytes = Int(crypto_aead_xchacha20poly1305_ietf_abytes())

    public static func isTransferBundle(_ text: String) -> Bool {
        return text.drop(while: { $0.isWhitespace }).hasPrefix(prefix)
    }

    public static func build(_ payload: TransferPayload, code: String) throws -> String {
        guard let codeBytes = TransferCode.parse(code) else { throw SecutgCryptoError.invalidKey }
        SecutgSodium.ensureReady()
        let key = try TransferCode.deriveKey(codeBytes)
        guard let json = try? JSONSerialization.data(withJSONObject: TransferSnapshotCodec.encodePayload(payload), options: [.sortedKeys]) else {
            throw SecutgCryptoError.sodiumFailure("cannot build transfer payload")
        }
        let plaintext = [UInt8](json)
        let nonce = SecutgSodium.randomBytes(nonceBytes)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count + tagBytes)
        var ctLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_encrypt(
            &ciphertext, &ctLen, plaintext, UInt64(plaintext.count), aad, UInt64(aad.count), nil, nonce, key)
        guard rc == 0 else { throw SecutgCryptoError.sodiumFailure("transfer encryption failed") }
        ciphertext.removeSubrange(Int(ctLen)..<ciphertext.count)
        return "K1:\(version):\(Base64Url.encode(nonce)):\(Base64Url.encode(ciphertext))"
    }

    /// nil for a malformed container, a wrong code or a tampered file — never throws.
    public static func open(_ text: String, code: String) -> TransferPayload? {
        guard let codeBytes = TransferCode.parse(code), let key = try? TransferCode.deriveKey(codeBytes) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ":")
        guard parts.count == 4, parts[0] == "K1", parts[1] == String(version),
              let nonce = Base64Url.decode(parts[2]), nonce.count == nonceBytes,
              let ciphertext = Base64Url.decode(parts[3]), ciphertext.count > tagBytes else { return nil }
        SecutgSodium.ensureReady()
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count - tagBytes)
        var ptLen: UInt64 = 0
        let rc = crypto_aead_xchacha20poly1305_ietf_decrypt(
            &plaintext, &ptLen, nil, ciphertext, UInt64(ciphertext.count), aad, UInt64(aad.count), nonce, key)
        guard rc == 0 else { return nil }
        let data = Data(plaintext[0..<Int(ptLen)])
        guard let raw = try? JSONSerialization.jsonObject(with: data), let object = raw as? [String: Any] else { return nil }
        return TransferSnapshotCodec.decodePayload(object)
    }

    public static func summarize(_ payload: TransferPayload, nowSeconds: Int64) -> TransferSummary {
        let snapshot = payload.snapshot
        return TransferSummary(
            scope: payload.scope,
            chatIds: payload.chatIds ?? Array(snapshot.chatMasters.keys),
            createdAt: payload.createdAt,
            device: payload.device,
            masterCount: snapshot.masters.count,
            chatCount: snapshot.chatMasters.count,
            hasIdentity: snapshot.identityEd25519Sk != nil,
            isStale: nowSeconds - payload.createdAt > staleSeconds,
            hasDeviceLabels: !snapshot.deviceLabels.isEmpty,
            adminChatCount: snapshot.chatAdminSks.count)
    }
}
