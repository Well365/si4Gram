import Foundation

/// Quick share of one chat's keys to another device of the same user by a single QR code (PLAN.md 3.14.1).
///
/// Text form: `K1Q:<transfer code, 32 Crockford base32 characters, no separators>:<K1 container verbatim>`.
/// The container is exactly what 3.14 builds for `scope = "chat"` — only Saved Messages and groups come this way,
/// so it never carries the identity key pair — encrypted under the key derived from that same code. Nothing new is
/// invented here: the code simply rides inside the same QR, which is why the QR *is* the key and the UI says so.
///
/// Pure rules only (no UI, no runtime): the wire shape, and how much of a chat's history still fits into one QR.
/// Mirrors Web A `src/secutg/transfer/quickShare.ts` and is pinned by the shared `vectors-k1q.json`.
public enum QuickShare {
    public static let prefix = "K1Q:"
    /// QR version 40, error correction M, byte mode — the most one QR code can hold.
    public static let maxQrBytes = 2331

    private static let codeChars = 32
    private static let codeAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let base64UrlAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    /// 24-byte nonce = 32 base64url characters; the ciphertext is at least the 16-byte tag = 22 characters.
    private static let nonceChars = 32
    private static let minCiphertextChars = 22

    public struct Parsed: Equatable {
        /// 32 characters, canonical, no separators; `TransferBundle.open` accepts it as is
        public let code: String
        /// `K1:1:<nonce>:<ct>`, verbatim
        public let bundle: String
    }

    /// Why a scanned text is refused. The UI shows one message for all three (`SecutgQuickShareBadQr`).
    public enum OpenError: String, Error, Equatable {
        /// syntax: not `K1Q:` + canonical code + well-formed `K1:1` container
        case malformed
        /// wrong code or tampered ciphertext
        case undecryptable
        /// it opened, but it is a whole-keyring (`scope = "all"`) file — never a quick share
        case wrongScope
    }

    /// One earlier master of the chat that may ride along when there is room.
    public struct HistoryMaster: Equatable {
        public let masterId: String
        public let key: [UInt8]
        /// ms, as `KeyRing.Snapshot.masterCreatedAt`
        public let createdAt: Int64?

        public init(masterId: String, key: [UInt8], createdAt: Int64?) {
            self.masterId = masterId
            self.key = key
            self.createdAt = createdAt
        }
    }

    /// What the export side ends up with.
    public enum Outcome: Equatable {
        /// Everything fits: the base slice and every history master this device holds for the chat.
        case full(text: String, masterCount: Int)
        /// Only the base slice plus the newest history masters fit; `masterCount` is how many masters the QR holds
        /// in total — the `{n}` of `SecutgQuickSharePartial`.
        case partial(text: String, masterCount: Int, dropped: Int)
        /// Not even the base slice alone fits: `SecutgQuickShareTooLarge`, use the 3.14 file transfer.
        case tooLarge
        /// The chat has no current master: `SecutgQuickShareNoKey`.
        case noKey
    }

    public static func isQuickShare(_ text: String) -> Bool {
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
    }

    /// The code as it goes into the QR: separators and whitespace dropped, upper case; nil unless exactly 32
    /// canonical characters remain (no I/L/O/U leniency here — that is for humans typing, not for QR codes).
    public static func canonicalCode(_ code: String) -> String? {
        let plain = String(code.filter { $0 != "-" && !$0.isWhitespace }).uppercased()
        return isCanonicalCode(plain) ? plain : nil
    }

    /// `K1Q:<code>:<bundle>`; nil when the code is not a valid transfer code or the bundle is not a well-formed
    /// `K1:1` container.
    public static func compose(code: String, bundle: String) -> String? {
        guard let canonical = canonicalCode(code), isWellFormedContainer(bundle) else { return nil }
        return prefix + canonical + ":" + bundle
    }

    /// Syntax only, strict: a QR is machine-written, so anything but `K1Q:` + exactly 32 canonical code characters
    /// + `:` + a well-formed `K1:1` container is not ours, or damaged. Surrounding whitespace is ignored.
    public static func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let rest = Array(trimmed.dropFirst(prefix.count))
        guard rest.count > codeChars, rest[codeChars] == ":" else { return nil }
        let code = String(rest[0..<codeChars])
        let bundle = String(rest[(codeChars + 1)...])
        guard isCanonicalCode(code), isWellFormedContainer(bundle) else { return nil }
        return Parsed(code: code, bundle: bundle)
    }

    /// Parse, decrypt with the embedded code, and insist on `scope = "chat"`. Never throws.
    public static func open(_ text: String) -> Result<(parsed: Parsed, payload: TransferPayload), OpenError> {
        guard let parsed = parse(text) else { return .failure(.malformed) }
        guard let payload = TransferBundle.open(parsed.bundle, code: parsed.code) else { return .failure(.undecryptable) }
        guard payload.scope == .chat else { return .failure(.wrongScope) }
        return .success((parsed, payload))
    }

    /// Byte length of the QR text (the QR is filled in byte mode, so UTF-8 bytes are what counts).
    public static func byteCount(_ text: String) -> Int {
        return text.utf8.count
    }

    // MARK: export

    /// The chat's earlier masters this device still holds (its `chatMasterHistory`, which the 3.14 chat slice does
    /// not carry), newest first, leaving out any already in `base`.
    public static func history(full: KeyRing.Snapshot, chatId: String, base: KeyRing.Snapshot) -> [HistoryMaster] {
        let skip = Set(base.masters.keys)
        return (full.chatMasterHistory[chatId] ?? []).reversed().compactMap { masterId in
            guard !skip.contains(masterId), let key = full.masters[masterId] else { return nil }
            return HistoryMaster(masterId: masterId, key: key, createdAt: full.masterCreatedAt[masterId])
        }
    }

    /// `base` plus the first `kept` history masters.
    public static func adding(_ kept: ArraySlice<HistoryMaster>, to base: KeyRing.Snapshot) -> KeyRing.Snapshot {
        var out = base
        for master in kept {
            out.masters[master.masterId] = master.key
            if let createdAt = master.createdAt { out.masterCreatedAt[master.masterId] = createdAt }
        }
        return out
    }

    /// The capacity rule of 3.14.1: everything if it fits; otherwise `base` (the 3.14 chat slice, never cut) plus
    /// as many of the newest history masters as fit, dropping the oldest first; `tooLarge` if `base` alone does not.
    ///
    /// `render` builds the complete `K1Q` text for a snapshot. Its length depends only on the plaintext (the nonce
    /// is fixed-size), and grows with every master added, so a binary search finds the same count as trying them
    /// one by one.
    public static func fit(
        chatId: String, base: KeyRing.Snapshot, historyNewestFirst: [HistoryMaster], maxBytes: Int = maxQrBytes,
        render: (KeyRing.Snapshot) throws -> String
    ) rethrows -> Outcome {
        guard base.chatMasters[chatId] != nil else { return .noKey }
        func attempt(_ kept: Int) throws -> String? {
            let text = try render(adding(historyNewestFirst.prefix(kept), to: base))
            return byteCount(text) <= maxBytes ? text : nil
        }
        let total = historyNewestFirst.count
        if let text = try attempt(total) { return .full(text: text, masterCount: base.masters.count + total) }
        guard var best = try attempt(0) else { return .tooLarge }
        var bestKept = 0
        var low = 1
        var high = total - 1
        while low <= high {
            let mid = (low + high) / 2
            if let text = try attempt(mid) {
                best = text
                bestKept = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return .partial(text: best, masterCount: base.masters.count + bestKept, dropped: total - bestKept)
    }

    /// Builds the QR text for one chat under `code`. `base` is `KeyRing.exportChatsSnapshot(chatIds: [chatId],
    /// withIdentity: false, includeDeviceLabels: false)` — device labels are the optional part of 3.14 and every
    /// byte counts in a QR — and `historyNewestFirst` comes from `history(full:chatId:base:)`.
    public static func build(
        chatId: String, base: KeyRing.Snapshot, historyNewestFirst: [HistoryMaster], createdAt: Int64, device: String,
        code: String, maxBytes: Int = maxQrBytes
    ) throws -> Outcome {
        guard let canonical = canonicalCode(code) else { throw SecutgCryptoError.invalidKey }
        return try fit(chatId: chatId, base: base, historyNewestFirst: historyNewestFirst, maxBytes: maxBytes, render: { snapshot in
            let payload = TransferPayload(scope: .chat, chatIds: [chatId], createdAt: createdAt, device: device, snapshot: snapshot)
            let bundle = try TransferBundle.build(payload, code: canonical)
            guard let text = compose(code: canonical, bundle: bundle) else { throw SecutgCryptoError.invalidKey }
            return text
        })
    }

    // MARK: syntax helpers

    private static func isCanonicalCode(_ code: String) -> Bool {
        return code.count == codeChars && code.allSatisfy { codeAlphabet.contains($0) }
    }

    /// `K1:1:<32 base64url>:<22+ base64url>` — the shape of a 3.14 container, checked without decrypting.
    private static func isWellFormedContainer(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "K1", parts[1] == String(TransferBundle.version) else { return false }
        let nonce = parts[2]
        let ciphertext = parts[3]
        return nonce.count == nonceChars && nonce.allSatisfy { base64UrlAlphabet.contains($0) }
            && ciphertext.count >= minCiphertextChars && ciphertext.allSatisfy { base64UrlAlphabet.contains($0) }
    }
}
